// /api/push — delivers notifications to phones and computers (Web Push, RFC 8291 + VAPID RFC 8292).
// The database calls this with a batch: { secret, api:{url,key}, vapid:{public,private,subject}, items:[{endpoint,p256dh,auth,payload}] }.
// Each payload is encrypted for its device and sent to that device's push service. Devices that no longer
// exist (HTTP 404/410) are reported back to the database (push_gone), which removes them.
// Uses only the built-in Web Crypto API, so it runs as a Cloudflare Pages Function without extra packages.

const enc = new TextEncoder();
const b64uToBytes = s => {
  s = String(s || "").replace(/-/g, "+").replace(/_/g, "/");
  while (s.length % 4) s += "=";
  const bin = atob(s), out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
};
const bytesToB64u = b => {
  let s = ""; const u = new Uint8Array(b);
  for (let i = 0; i < u.length; i++) s += String.fromCharCode(u[i]);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
};
const concat = (...parts) => {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0)); let o = 0;
  for (const p of parts) { out.set(p, o); o += p.length; }
  return out;
};
const hkdf = async (salt, ikm, info, bytes) => {
  const key = await crypto.subtle.importKey("raw", ikm, "HKDF", false, ["deriveBits"]);
  return new Uint8Array(await crypto.subtle.deriveBits({ name: "HKDF", hash: "SHA-256", salt, info }, key, bytes * 8));
};

// aes128gcm content encoding for one push message
export async function encryptPayload(plaintext, p256dh, authSecret) {
  const uaPublic = b64uToBytes(p256dh), auth = b64uToBytes(authSecret);
  const uaKey = await crypto.subtle.importKey("raw", uaPublic, { name: "ECDH", namedCurve: "P-256" }, false, []);
  const as = await crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, true, ["deriveBits"]);
  const asPublic = new Uint8Array(await crypto.subtle.exportKey("raw", as.publicKey));
  const shared = new Uint8Array(await crypto.subtle.deriveBits({ name: "ECDH", public: uaKey }, as.privateKey, 256));
  const ikm = await hkdf(auth, shared, concat(enc.encode("WebPush: info\0"), uaPublic, asPublic), 32);
  const salt = crypto.getRandomValues(new Uint8Array(16));
  const cek = await hkdf(salt, ikm, enc.encode("Content-Encoding: aes128gcm\0"), 16);
  const nonce = await hkdf(salt, ikm, enc.encode("Content-Encoding: nonce\0"), 12);
  const aes = await crypto.subtle.importKey("raw", cek, "AES-GCM", false, ["encrypt"]);
  const data = concat(typeof plaintext === "string" ? enc.encode(plaintext) : plaintext, new Uint8Array([2]));
  const cipher = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv: nonce }, aes, data));
  const header = new Uint8Array(16 + 4 + 1 + asPublic.length);
  header.set(salt, 0); new DataView(header.buffer).setUint32(16, 4096); header[20] = asPublic.length; header.set(asPublic, 21);
  return concat(header, cipher);
}

// VAPID: a short signed token per push service ("audience")
export async function vapidHeader(endpoint, vapid, cache = {}) {
  const aud = new URL(endpoint).origin;
  if (cache[aud]) return cache[aud];
  const pub = b64uToBytes(vapid.public);
  if (!cache.__key) {
    cache.__key = await crypto.subtle.importKey("jwk", {
      kty: "EC", crv: "P-256", d: vapid.private, x: bytesToB64u(pub.slice(1, 33)), y: bytesToB64u(pub.slice(33, 65)), ext: true
    }, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  }
  const head = bytesToB64u(enc.encode(JSON.stringify({ typ: "JWT", alg: "ES256" })));
  const body = bytesToB64u(enc.encode(JSON.stringify({ aud, exp: Math.floor(Date.now() / 1000) + 12 * 3600, sub: vapid.subject || "mailto:admin@example.com" })));
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, cache.__key, enc.encode(head + "." + body));
  return (cache[aud] = `vapid t=${head}.${body}.${bytesToB64u(sig)}, k=${vapid.public}`);
}

export async function sendOne(item, vapid, cache, fetchImpl = fetch) {
  const body = await encryptPayload(JSON.stringify(item.payload || {}), item.p256dh, item.auth);
  const r = await fetchImpl(item.endpoint, {
    method: "POST",
    headers: { Authorization: await vapidHeader(item.endpoint, vapid, cache), "Content-Encoding": "aes128gcm",
               "Content-Type": "application/octet-stream", TTL: "86400", Urgency: "high" },
    body
  });
  return r.status;
}

const json = (o, status = 200) => new Response(JSON.stringify(o), { status, headers: { "Content-Type": "application/json", "Cache-Control": "no-store" } });

export async function onRequestPost({ request }) {
  let msg;
  try { msg = await request.json(); } catch (e) { return json({ error: "bad request" }, 400); }
  if (msg && msg.ping) return json({ ok: true, push: "ready" });
  const items = Array.isArray(msg?.items) ? msg.items.slice(0, 50) : [];
  const vapid = msg?.vapid || {};
  if (!items.length || !vapid.public || !vapid.private) return json({ error: "nothing to send" }, 400);
  const cache = {}, gone = [];
  let sent = 0, failed = 0;
  await Promise.all(items.map(async it => {
    try {
      if (!/^https:\/\//.test(it.endpoint || "")) { failed++; return; }
      const st = await sendOne(it, vapid, cache);
      if (st >= 200 && st < 300) sent++;
      else { failed++; if (st === 404 || st === 410) gone.push(it.endpoint); }
    } catch (e) { failed++; }
  }));
  if (gone.length && msg.api?.url && msg.api?.key) {
    try {
      await fetch(msg.api.url.replace(/\/$/, "") + "/rest/v1/rpc/push_gone", {
        method: "POST", headers: { apikey: msg.api.key, "Content-Type": "application/json" },
        body: JSON.stringify({ p_secret: msg.secret, p_endpoints: gone })
      });
    } catch (e) {}
  }
  return json({ sent, failed, gone: gone.length });
}

export const onRequestGet = () => json({ ok: true, push: "ready" });
