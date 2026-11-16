// Service worker: shows notifications pushed by the server and opens the right page when one is tapped.
// It does not cache pages, so the app always loads fresh.
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", e => e.waitUntil(self.clients.claim()));
self.addEventListener("push", e => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch (x) { d = { title: e.data ? e.data.text() : "" }; }
  e.waitUntil(self.registration.showNotification(d.title || "CoachMohsen", {
    body: d.body || "", icon: "/favicon-192.png", badge: "/favicon-192.png",
    tag: d.tag || undefined, data: { link: d.link || "", id: d.id || null }
  }));
});
self.addEventListener("notificationclick", e => {
  e.notification.close();
  const { link, id } = e.notification.data || {};
  e.waitUntil((async () => {
    const all = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
    for (const c of all) {
      if (new URL(c.url).origin === self.location.origin) { c.postMessage({ type: "ntopen", link, id }); return c.focus(); }
    }
    return self.clients.openWindow("/" + (link ? "#" + link : ""));
  })());
});
