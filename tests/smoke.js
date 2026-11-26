// Smoke test: node tests/smoke.js  (needs playwright; serves public/ locally with a stubbed backend)
const { chromium } = require('playwright'); const http = require('http'); const fs = require('fs'); const path = require('path');
const root = path.join(__dirname, '..', 'public');
const srv = http.createServer((q, s) => { let p = q.url.split('?')[0]; if (p === '/') p = '/index.html';
  if (p.startsWith('/vendor/')) { s.setHeader('content-type','text/javascript'); return s.end(fs.readFileSync(path.join(__dirname,'stub-supabase.js'))); }
  if (p === '/config.js') { s.setHeader('content-type','text/javascript'); return s.end('window.PADEL_CONFIG={supabaseUrl:"https://stub.supabase.co",supabaseAnonKey:"stub"}'); }
  const f = path.join(root, p); if (!fs.existsSync(f)) { s.statusCode = 404; return s.end(); }
  s.setHeader('content-type', p.endsWith('.html') ? 'text/html' : p.endsWith('.svg') ? 'image/svg+xml' : p.endsWith('.js') ? 'text/javascript' : p.endsWith('.webmanifest') ? 'application/manifest+json' : 'text/plain'); s.end(fs.readFileSync(f)); });
const seed = JSON.parse(fs.readFileSync(path.join(__dirname, 'seed.json'), 'utf8'));

// People (all synthetic)
const OWNER = { id: '11111111-1111-4111-8111-111111111111', email: 'owner@example.com', name: 'Owner' };
const COACH_A = { id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', email: 'coach.a@example.com', name: 'Coach A' };
const COACH_B = { id: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', email: 'coach.b@example.com', name: 'Coach B' };
const ADMIN = { id: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc', email: 'admin@academy.example', name: 'Club Admin' };
const PLAYER = { id: '22222222-2222-4222-8222-222222222222', email: 'player@example.com', name: 'Sample Player' };

// The v1 seed, moved into the multi-club shape the same way migration 0005 moves real data.
function world({ user, role = 'player', members = [], linked = false, extra = [] }) {
  const docs = [];
  for (const d of JSON.parse(JSON.stringify(seed))) {
    if (d.collection === 'clubs') docs.push({ collection: 'venues', id: d.id, data: { ...d.data, clubId: 'freelance', courts: [1, 2, 3, 4].map(i => ({ id: d.id + '-c' + i, name: 'Court ' + i, name_ar: 'ملعب ' + i })) } });
    else if (d.collection === 'skills') docs.push({ ...d, data: { ...d.data, clubId: 'freelance' } });
    else if (d.collection === 'trainees') { const { fixedSlots, showFeedback, inviteCode, ...sh } = d.data; if (linked) sh.linkedUserId = PLAYER.id;
      docs.push({ collection: 'trainees', id: d.id, data: sh });
      docs.push({ collection: 'coachplayer', id: d.id + '@' + COACH_A.id, data: { id: d.id + '@' + COACH_A.id, playerId: d.id, coachId: COACH_A.id, clubId: 'freelance', fixedSlots: fixedSlots || [], showFeedback: false } }); }
    else docs.push({ ...d, data: { ...d.data, clubId: 'freelance', coachId: COACH_A.id } });
  }
  docs.push(...extra);
  return { user, role, docs, profiles: [OWNER, COACH_A, COACH_B, ADMIN, PLAYER].map(u => ({ id: u.id, email: u.email, full_name: u.name })), users: [OWNER, COACH_A, COACH_B, ADMIN, PLAYER].map(u => ({ ...u, role: u === OWNER ? 'sysadmin' : 'player', created_at: '2026-10-29T08:00:00Z' })),
    orgs: [{ id: 'freelance', name: 'Freelance coaches', is_freelance: true }, { id: 'academy', name: 'Academy', is_freelance: false }],
    members, players: [{ org_id: 'freelance', player_id: 't1' }], enroll: [{ org_id: 'freelance', player_id: 't1', coach_id: COACH_A.id }] };
}
const asCoachA = (o = {}) => world({ user: COACH_A, members: [{ org_id: 'freelance', user_id: COACH_A.id, role: 'coach' }], ...o });
const asOwner = (o = {}) => world({ user: OWNER, role: 'sysadmin', members: [{ org_id: 'freelance', user_id: OWNER.id, role: 'club_admin' }, { org_id: 'freelance', user_id: COACH_A.id, role: 'coach' }], ...o });
// Two coaches share player t1; coach B has his own session x2 with a private remark.
const shared = () => {
  const w = asCoachA({ extra: [
    { collection: 'sessions', id: 'x2', data: { id: 'x2', date: '2026-10-29', time: '19:00', duration: 60, status: 'done', location: 'Padel Pro', traineeIds: ['t1'], clubId: 'freelance', coachId: COACH_B.id,
      activities: [{ id: 'a2', skillId: 'bandeja', title: 'Bandeja drill', minutes: 30 }], feedback: { t1: { skills: { bandeja: { rating: 3, comment: 'B comment' } }, general: 'B general', overall: 3 } } } },
    { collection: 'sessremarks', id: 'x2', data: { id: 'x2', sessionId: 'x2', coachId: COACH_B.id, clubId: 'freelance', byTrainee: { t1: { remarks: 'SECRET-B' } } } },
    { collection: 'sessremarks', id: 'x1', data: { id: 'x1', sessionId: 'x1', coachId: COACH_A.id, clubId: 'freelance', byTrainee: { t1: { remarks: 'SECRET-A' } } } },
    { collection: 'coachplayer', id: 't1@' + COACH_B.id, data: { id: 't1@' + COACH_B.id, playerId: 't1', coachId: COACH_B.id, clubId: 'freelance', showFeedback: true, coachRemarks: 'B private profile note' } }] });
  w.members.push({ org_id: 'freelance', user_id: COACH_B.id, role: 'coach' }); w.enroll.push({ org_id: 'freelance', player_id: 't1', coach_id: COACH_B.id }); return w; };

(async () => {
  await new Promise(r => srv.listen(8765, r)); const b = await chromium.launch(); const errs = []; let ok = true;
  const run = async (name, stub, fn, hash = '') => { const pg = await b.newPage({ viewport: { width: 1280, height: 900 } });
    pg.on('pageerror', e => errs.push(name + ': ' + e.message)); pg.on('console', m => { if (m.type() === 'error' && !/fonts\.g/.test(m.text()) && !/ERR_(NAME|INTERNET|CONNECTION|TUNNEL|PROXY)/.test(m.text())) errs.push(name + ' console: ' + m.text()); });
    let navs = 0; pg.on('domcontentloaded', () => { navs++; }); // full page loads only (address tidy-ups are not reloads)
    await pg.addInitScript(st => { window.__STUB__ = st; }, stub); await pg.goto('http://localhost:8765/' + hash); await pg.waitForTimeout(1200);
    if (navs > 1) { ok = false; console.log('FAIL', name, 'page reloaded itself', navs - 1, 'time(s)'); }
    try { await fn(pg); console.log('PASS', name); } catch (e) { ok = false; console.log('FAIL', name, e.message); }
    await pg.screenshot({ path: path.join(process.env.SHOTS || '/tmp', name + '.png'), fullPage: false }); await pg.close(); };
  const text = pg => pg.evaluate(() => document.body.innerText + ' ' + document.body.textContent);
  const tabs = pg => pg.$$eval('nav.tabs a', a => a.map(x => x.getAttribute('href')));

  await run('sso-buttons', { user: null, docs: [], providers: { google: true, apple: true, email: true } }, async pg => {
    await pg.waitForSelector('[data-sso="google"]'); await pg.waitForSelector('[data-sso="apple"]'); });
  await run('theme-on-signin', { user: null, docs: [], settings: [{ key: 'theme', value: 'royale' }] }, async pg => {
    await pg.waitForSelector('#authForm'); const b = await pg.evaluate(() => document.documentElement.dataset.brand); if (b !== 'royale') throw new Error('brand ' + b); });
  await run('signed-out', { user: null, docs: [] }, async pg => { await pg.waitForSelector('#authForm'); });

  // Coach
  await run('coach-calendar', asCoachA(), async pg => {
    await pg.waitForSelector('.pc-grid'); const t = await tabs(pg); if (t.join() !== '#week,#trainees,#skills,#clubs') throw new Error('tabs ' + t);
    if (!(await text(pg)).includes('Venues')) throw new Error('no Venues tab label');
    if (!(await pg.locator('#clubSwitch').isHidden())) throw new Error('club switch shown for one club'); });
  await run('header-user-coach', asCoachA(), async pg => {
    const c = await pg.innerText('#userChip'); if (!c.includes('Coach A') || !c.includes('Coach · Freelance coaches')) throw new Error('chip ' + c); });
  await run('header-user-sysadmin', asOwner(), async pg => {
    const c = await pg.innerText('#userChip'); if (!c.includes('Owner') || !c.includes('Sys admin') || (await pg.inputValue('#clubSwitch')) !== 'freelance') throw new Error('chip ' + c); });
  await run('coach-trainees', asCoachA(), async pg => {
    await pg.click('nav.tabs a[href="#trainees"]'); await pg.waitForTimeout(300); const c = await pg.locator('#trList a.card').count(); if (c !== 1) throw new Error('trainees ' + c);
    await pg.locator('#trList a.card').first().click(); await pg.waitForTimeout(300); await pg.waitForSelector('[data-trtab="log"]');
    if (!(await text(pg)).includes('Every')) throw new Error('fixed slot (coach field) missing'); });
  await run('coach-add-note', asCoachA(), async pg => {
    await pg.click('[data-trtab="log"]'); const ta = pg.locator('textarea[data-clnew]'); await ta.fill('Smoke test note'); await pg.click('[data-act="addNote"]'); await pg.waitForTimeout(400);
    if (!(await text(pg)).includes('Smoke test note')) throw new Error('note not shown');
    const n = await pg.evaluate(() => window.__STUB__.docs.find(d => d.collection === 'coachnotes'));
    if (!n || n.data.clubId !== 'freelance' || n.data.coachId !== 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa') throw new Error('note not stamped ' + JSON.stringify(n)); }, '#trainee-t1');
  await run('coach-new-player', asCoachA(), async pg => {
    await pg.click('[data-act="newTrainee"]'); await pg.fill('#tr-name', 'New Kid'); await pg.fill('#tr-goals', 'Volley'); await pg.click('.sheet button[type="submit"]'); await pg.waitForTimeout(600);
    if (!(await text(pg)).toLowerCase().includes('new kid')) throw new Error('not opened');
    const st = await pg.evaluate(() => { const T = window.__STUB__; const tr = T.docs.find(d => d.collection === 'trainees' && d.data.name === 'New Kid'); return { tr, cp: T.docs.find(d => d.collection === 'coachplayer' && d.data.playerId === tr.id), en: T.enroll.filter(e => e.player_id === tr.id).length }; });
    if (st.tr.data.goals) throw new Error('coach field leaked into shared profile'); if (!st.cp || st.cp.data.goals !== 'Volley') throw new Error('coach goals not saved'); if (st.en !== 1) throw new Error('not enrolled'); }, '#trainees');
  await run('coach-remarks-private', asCoachA(), async pg => {
    await pg.fill('#rm-x1-t1', 'Only for me'); await pg.click('[data-act="saveFb"]'); await pg.waitForTimeout(500);
    const st = await pg.evaluate(() => { const T = window.__STUB__; return { s: T.docs.find(d => d.collection === 'sessions' && d.id === 'x1').data, r: T.docs.find(d => d.collection === 'sessremarks' && d.id === 'x1') }; });
    if (JSON.stringify(st.s).includes('Only for me')) throw new Error('remark stored on the session'); if (!st.r || st.r.data.byTrainee.t1.remarks !== 'Only for me') throw new Error('remark not saved apart'); }, '#session-x1');
  await run('coach-isolation', shared(), async pg => {
    const t = await text(pg); if (t.includes('B general') || t.includes('SECRET-B') || t.includes('B private profile note')) throw new Error('sees coach B data');
    if (!t.includes('Solid session')) throw new Error('own history missing'); }, '#trainee-t1');
  await run('coach-b-isolation', { ...shared(), user: COACH_B }, async pg => {
    const t = await text(pg); if (t.includes('Solid session') || t.includes('SECRET-A') || t.includes('Good depth')) throw new Error('sees coach A data');
    if (!t.includes('B general') || (await pg.inputValue('#trm-t1')) !== 'B private profile note') throw new Error('own data missing'); }, '#trainee-t1');
  await run('coach-no-users-tab', asCoachA(), async pg => {
    await pg.waitForSelector('.pc-grid'); const t = await tabs(pg); if (t.includes('#users') || t.includes('#appearance') || t.includes('#team') || t.includes('#orgs')) throw new Error('coach sees admin tabs ' + t); });
  await run('no-club', world({ user: COACH_B, members: [] }), async pg => {
    await pg.waitForSelector('#my-id'); });

  // Club admin
  const academy = () => { const w = shared(); w.user = ADMIN; w.members.push({ org_id: 'academy', user_id: ADMIN.id, role: 'club_admin' }, { org_id: 'freelance', user_id: ADMIN.id, role: 'club_admin' }); return w; };
  await run('club-admin-sees-club', academy(), async pg => {
    await pg.waitForSelector('#clubSwitch:not([hidden])'); await pg.selectOption('#clubSwitch', 'freelance'); await pg.waitForTimeout(300);
    const t = await tabs(pg); if (!t.includes('#team') || t.includes('#orgs') || t.includes('#users')) throw new Error('tabs ' + t);
    await pg.goto('http://localhost:8765/#trainee-t1'); await pg.waitForTimeout(600); const tx = await text(pg);
    if (!tx.includes('Solid session') || !tx.includes('B general')) throw new Error('admin misses club sessions');
    if (tx.includes('SECRET') || tx.includes('B private profile note')) throw new Error('admin sees private remarks');
    if (!(await pg.locator('[data-pcoach]').count())) throw new Error('no coach assignment'); });
  await run('club-admin-team', academy(), async pg => {
    await pg.selectOption('#clubSwitch', 'freelance'); await pg.waitForTimeout(300); await pg.click('nav.tabs a[href="#team"]'); await pg.waitForTimeout(400);
    const tx = await text(pg); if (!tx.includes('Coach A') || !tx.includes('Coach B')) throw new Error('team list');
    await pg.click('[data-act="addMember"][data-role="coach"]'); await pg.fill('#mem-email', 'owner@example.com'); await pg.click('.sheet button[type="submit"]'); await pg.waitForTimeout(500);
    if (!(await pg.evaluate(() => window.__STUB__.members.some(m => m.user_id === '11111111-1111-4111-8111-111111111111' && m.role === 'coach')))) throw new Error('coach not added');
    if (await pg.locator('[data-act="addMember"][data-role="club_admin"]').count()) throw new Error('club admin can add admins'); });
  await run('club-admin-assign-coach', academy(), async pg => {
    await pg.selectOption('#clubSwitch', 'freelance'); await pg.waitForTimeout(300); await pg.goto('http://localhost:8765/#trainee-t1'); await pg.waitForTimeout(600);
    await pg.uncheck(`[data-pcoach="t1"][value="${COACH_B.id}"]`); await pg.waitForTimeout(400);
    const n = await pg.evaluate(id => window.__STUB__.enroll.filter(e => e.player_id === 't1' && e.coach_id === id).length, COACH_B.id); if (n) throw new Error('still enrolled'); });
  await run('club-admin-coach-filter', academy(), async pg => {
    await pg.selectOption('#clubSwitch', 'freelance'); await pg.waitForTimeout(300); await pg.waitForSelector('#coachf'); await pg.selectOption('#coachf', COACH_B.id); await pg.waitForTimeout(300);
    const n = await pg.evaluate(() => document.querySelectorAll('[data-coachf]').length); if (!n) throw new Error('no filter'); });

  // Sys admin
  await run('sysadmin-users', asOwner(), async pg => {
    const t = await tabs(pg); if (t.join() !== '#week,#trainees,#skills,#clubs,#team,#clubsettings,#orgs,#users,#notiflog,#deletedlog,#syssettings,#appearance') throw new Error('tabs ' + t);
    await pg.click('nav.tabs a[href="#users"]'); await pg.waitForSelector('.utable');
    const opts = await pg.$$eval(`select[data-setrole="${COACH_B.id}"] option`, o => o.map(x => x.value)); if (opts.join() !== 'player,sysadmin') throw new Error('roles ' + opts);
    await pg.selectOption(`select[data-setrole="${COACH_B.id}"]`, 'sysadmin'); await pg.waitForTimeout(400);
    if (await pg.inputValue(`select[data-setrole="${COACH_B.id}"]`) !== 'sysadmin') throw new Error('role not saved'); });
  await run('sysadmin-clubs', asOwner(), async pg => {
    await pg.click('nav.tabs a[href="#orgs"]'); await pg.waitForTimeout(300); await pg.click('[data-act="editOrg"]:not([data-id])'); await pg.fill('#org-name', 'Smash Club'); await pg.click('.sheet button[type="submit"]'); await pg.waitForTimeout(500);
    if (!(await text(pg)).includes('Smash Club')) throw new Error('club not listed');
    const opts = await pg.$$eval('#clubSwitch option', o => o.map(x => x.textContent)); if (!opts.includes('Smash Club')) throw new Error('not in switcher ' + opts);
    const sk = await pg.evaluate(() => window.__STUB__.docs.filter(d => d.collection === 'skills' && d.data.clubId !== 'freelance').length); if (sk !== 2) throw new Error('skills not copied ' + sk); });
  await run('sysadmin-hand-over', (() => { const w = asOwner(); w.members.push({ org_id: 'freelance', user_id: COACH_B.id, role: 'coach' }); return w; })(), async pg => {
    await pg.click('nav.tabs a[href="#team"]'); await pg.waitForSelector('#ho-from'); await pg.selectOption('#ho-from', COACH_A.id); await pg.selectOption('#ho-to', COACH_B.id);
    await pg.click('[data-act="handOver"]'); await pg.click('[data-act="handOver"]'); await pg.waitForTimeout(500);
    const s = await pg.evaluate(() => window.__STUB__.docs.find(d => d.id === 'x1').data.coachId); if (s !== 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb') throw new Error('not handed over'); });
  await run('sysadmin-theme', asOwner(), async pg => {
    await pg.click('nav.tabs a[href="#appearance"]'); await pg.waitForSelector('[data-settheme="glass"]'); await pg.click('[data-settheme="glass"]'); await pg.waitForTimeout(300);
    const b = await pg.evaluate(() => document.documentElement.dataset.brand); if (b !== 'glass') throw new Error('brand ' + b); });
  await run('theme-coach-mohsen', asOwner(), async pg => {
    await pg.click('nav.tabs a[href="#appearance"]'); await pg.waitForSelector('[data-settheme="mohsen"]'); await pg.click('[data-settheme="mohsen"]'); await pg.waitForTimeout(400);
    if (await pg.evaluate(() => document.documentElement.dataset.brand) !== 'mohsen') throw new Error('brand not applied');
    if (!(await pg.locator('.brand .logo-photo').isVisible()) || await pg.locator('.brand svg.logo').isVisible()) throw new Error('coach photo not shown');
    if ((await pg.innerText('#brandTag')).toLowerCase() !== 'be the best version of yourself') throw new Error('tagline');
    if (await pg.evaluate(() => window.__STUB__.settings.find(x => x.key === 'theme').value) !== 'mohsen') throw new Error('not saved');
    await pg.click('#langBtn'); await pg.waitForTimeout(200); if (await pg.innerText('#brandTag') !== 'كن أفضل نسخة من نفسك') throw new Error('arabic tagline'); });
  await run('admin-coach-this-player', asOwner(), async pg => {
    await pg.waitForSelector('[data-act="coachThis"]'); if (await pg.locator('[data-act="addSlot"]').count()) throw new Error('slots shown before coaching');
    await pg.click('[data-act="coachThis"]'); await pg.waitForSelector('[data-act="addSlot"]', { timeout: 5000 });
    const st = await pg.evaluate(id => ({ m: window.__STUB__.members.some(m => m.user_id === id && m.role === 'coach'), e: window.__STUB__.enroll.some(e => e.player_id === 't1' && e.coach_id === id) }), OWNER.id);
    if (!st.m || !st.e) throw new Error('not made coach ' + JSON.stringify(st)); }, '#trainee-t1');
  await run('skill-name-suggest', asOwner(), async pg => {
    await pg.click('nav.tabs a[href="#skills"]'); await pg.waitForTimeout(300); await pg.click('[data-act="newSkill"]'); await pg.waitForSelector('#sk-ar');
    await pg.fill('#sk-ar', 'الفولي الخلفي'); await pg.waitForTimeout(100);
    if (await pg.inputValue('#sk-en') !== 'Backhand volley') throw new Error('en from ar: ' + await pg.inputValue('#sk-en'));
    if (await pg.inputValue('#sk-cat') !== 'net') throw new Error('category not suggested');
    await pg.fill('#sk-ar', ''); await pg.fill('#sk-en', ''); await pg.fill('#sk-en', 'víbora'); await pg.waitForTimeout(100);
    if (await pg.inputValue('#sk-ar') !== 'الفيبورا') throw new Error('ar from en: ' + await pg.inputValue('#sk-ar'));
    await pg.fill('#sk-en', 'Smash'); await pg.waitForTimeout(100); if (await pg.inputValue('#sk-ar') !== 'السماش') throw new Error('auto value not updated');
    await pg.fill('#sk-ar', 'سماش قوي يدوي'); await pg.fill('#sk-en', 'Smas'); await pg.waitForTimeout(100);
    if (await pg.inputValue('#sk-ar') !== 'سماش قوي يدوي') throw new Error('overwrote a typed name');
    if (!(await pg.locator('#sug-ar [data-sug]').count())) throw new Error('no suggestions shown');
    await pg.locator('#sug-ar [data-sug]').first().click(); if (!(await pg.inputValue('#sk-ar')).includes('سماش')) throw new Error('suggestion not used'); });
  await run('users-add-player', asOwner(), async pg => {
    await pg.click('nav.tabs a[href="#users"]'); await pg.waitForSelector('[data-act="quickPlayer"]'); await pg.click('[data-act="quickPlayer"]');
    await pg.waitForSelector('#qp-name'); await pg.fill('#qp-name', 'Fresh Player'); await pg.fill('#qp-email', 'Fresh@Example.com'); await pg.fill('#qp-phone', '0551234567');
    await pg.waitForSelector(`#qp-c-${COACH_A.id}`); await pg.check(`#qp-c-${COACH_A.id}`); await pg.click('.sheet button[type="submit"]'); await pg.waitForTimeout(700);
    const st = await pg.evaluate(id => { const T = window.__STUB__; const tr = T.docs.find(d => d.collection === 'trainees' && d.data.name === 'Fresh Player'); const u = T.users.find(x => x.email === 'fresh@example.com');
      return { tr: !!tr, linked: tr && u && tr.data.linkedUserId === u.id, coach: tr && T.enroll.some(e => e.player_id === tr.id && e.coach_id === id) }; }, COACH_A.id);
    if (!st.tr || !st.linked || !st.coach) throw new Error('not created ' + JSON.stringify(st));
    const tx = await text(pg); if (!tx.includes('fresh@example.com') || !tx.includes('Open profile')) throw new Error('no confirmation / not listed');
    await pg.click('[data-act="quickPlayer"]'); await pg.click('.sheet button[type="submit"]'); await pg.waitForTimeout(200);
    if (!(await text(pg)).includes('Add a name first.')) throw new Error('saved without a name'); });
  await run('invite-link-coach', asCoachA(), async pg => {
    await pg.click('[data-act="inviteLink"]'); await pg.waitForSelector('#inv-url'); const u = await pg.inputValue('#inv-url');
    if (!/\/\?join=c[0-9a-f]{9}$/.test(u)) throw new Error('link ' + u);
    const c = await pg.evaluate(() => window.__STUB__.codes[0]); if (c.coach !== 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa') throw new Error('not a coach link');
    await pg.click('[data-invrenew]'); await pg.click('[data-invrenew]'); await pg.waitForTimeout(400);
    if ((await pg.inputValue('#inv-url')) === u) throw new Error('not renewed'); }, '#trainees');
  const JOIN = { codes: [{ code: 'cabc123def', org: 'freelance', coach: COACH_A.id }] };
  await run('invite-signed-out', { ...asCoachA(), ...JOIN, user: null }, async pg => {
    await pg.waitForSelector('#authForm'); const tx = await text(pg);
    if (!tx.includes('Coach A invited you to train at Freelance coaches')) throw new Error('no invite banner');
    if (await pg.evaluate(() => location.search)) throw new Error('code left in the address'); }, '?join=CABC123DEF');
  await run('invite-joins-new-player', { ...asCoachA(), ...JOIN, user: { id: '44444444-4444-4444-8444-444444444444', email: 'layla@example.com', user_metadata: { full_name: 'Layla Hassan' } } }, async pg => {
    await pg.waitForSelector('.ptabs'); const st = await pg.evaluate(() => { const T = window.__STUB__; const tr = T.docs.find(d => d.collection === 'trainees' && d.data.linkedUserId === '44444444-4444-4444-8444-444444444444');
      return { name: tr && tr.data.name, coach: tr && T.enroll.some(e => e.player_id === tr.id && e.coach_id === 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'), left: localStorage.getItem('padelcoach.join') }; });
    if (st.name !== 'Layla Hassan' || !st.coach || st.left) throw new Error('join ' + JSON.stringify(st)); }, '?join=cabc123def');
  await run('users-register-player', asOwner(), async pg => {
    await pg.click('nav.tabs a[href="#users"]'); await pg.waitForSelector(`[data-act="regPlayer"][data-id="${COACH_B.id}"]`);
    if (await pg.locator(`[data-act="regPlayer"][data-id="${PLAYER.id}"]`).count() === 0 && false) throw new Error('x');
    await pg.click(`[data-act="regPlayer"][data-id="${COACH_B.id}"]`); await pg.waitForTimeout(600);
    if (await pg.locator(`[data-act="regPlayer"][data-id="${COACH_B.id}"]`).count()) throw new Error('button still shown');
    const tr = await pg.evaluate(id => window.__STUB__.docs.find(d => d.collection === 'trainees' && d.data.linkedUserId === id), COACH_B.id);
    if (!tr || tr.data.name !== 'Coach B') throw new Error('not registered ' + JSON.stringify(tr));
    if (!(await pg.locator(`a[href="#trainee-${tr.id}"]`).count())) throw new Error('no link to the profile');
    await pg.setViewportSize({ width: 390, height: 844 }); await pg.waitForTimeout(200);
    const r = await pg.locator(`[data-act="regPlayer"][data-id="${ADMIN.id}"]`).boundingBox(); if (!r || r.x + r.width > 390) throw new Error('button off screen on a phone'); });
  await run('footer-and-last-sign-in', (() => { const w = asOwner({ linked: true }); w.users.find(u => u.id === PLAYER.id).last_sign_in_at = '2026-11-12T18:40:00Z'; return w; })(), async pg => {
    const f = await pg.innerText('footer.sitefoot'); if (!f.includes('Developed by: Mohamed Break | 0548495149 | eng.mib@outlook.com')) throw new Error('footer ' + f);
    await pg.click('nav.tabs a[href="#users"]'); await pg.waitForTimeout(600); let tx = await text(pg);
    if (!tx.includes('Last active') || !tx.includes('12 Nov 2026') || !tx.includes('Never signed in')) throw new Error('users last sign-in');
    if (await pg.locator('.utable .av').count() < 3) throw new Error('no photos on Users');
    await pg.click('nav.tabs a[href="#trainees"]'); await pg.waitForTimeout(600); tx = await text(pg);
    if (!tx.includes('Last active: 12 Nov 2026')) throw new Error('players last sign-in');
    if (!(await pg.locator('#trList a.card .av').count())) throw new Error('no photos on Players');
    await pg.click('#langBtn'); await pg.waitForTimeout(200); if (!(await pg.innerText('footer.sitefoot')).includes('التطوير بواسطة: محمد بريك')) throw new Error('arabic footer'); });
  await run('coach-cannot-manage-venues-skills', asCoachA(), async pg => {
    await pg.click('nav.tabs a[href="#clubs"]'); await pg.waitForTimeout(300);
    if (await pg.locator('[data-act="newClub"],[data-act="editClub"]').count()) throw new Error('coach can edit venues');
    if (!(await text(pg)).includes('Venues and courts are managed by the club admins.')) throw new Error('no hint');
    await pg.click('nav.tabs a[href="#skills"]'); await pg.waitForTimeout(300);
    if (await pg.locator('[data-act="newSkill"],[data-act="editSkill"]').count()) throw new Error('coach can edit skills'); });
  await run('clubs-tab-venues', asOwner(), async pg => {
    await pg.click('nav.tabs a[href="#clubs"]'); await pg.waitForTimeout(300);
    if (!(await pg.innerText('h2')).toLowerCase().includes('freelance coaches')) throw new Error('club not in heading');
    await pg.click('nav.tabs a[href="#orgs"]'); await pg.waitForTimeout(300);
    if (!(await text(pg)).includes('4 courts')) throw new Error('venues not listed under the club');
    await pg.click('[data-act="orgAddVenue"][data-id="academy"]'); await pg.waitForSelector('#cl-name');
    if ((await pg.inputValue('#cl-org')) !== 'academy') throw new Error('club not preset');
    await pg.fill('#cl-name', 'Academy Court'); await pg.click('.sheet button[type="submit"]'); await pg.waitForTimeout(500);
    const v = await pg.evaluate(() => window.__STUB__.docs.find(d => d.collection === 'venues' && d.data.name === 'Academy Court'));
    if (!v || v.data.clubId !== 'academy') throw new Error('venue not in academy ' + JSON.stringify(v));
    await pg.click(`[data-act="orgVenue"][data-id="${v.id}"]`); await pg.waitForSelector('#cl-org'); await pg.selectOption('#cl-org', 'freelance');
    await pg.click('.sheet button[type="submit"]'); await pg.waitForTimeout(500);
    if (await pg.evaluate(id => window.__STUB__.docs.find(d => d.id === id).data.clubId, v.id) !== 'freelance') throw new Error('venue not moved'); });
  await run('link-by-email', asOwner(), async pg => {
    await pg.fill('#link-id-t1', 'Player@Example.com '); await pg.click('[data-act="linkId"][data-id="t1"]'); await pg.waitForTimeout(500);
    if (!(await pg.locator('[data-act="unlink"]').count())) throw new Error('not linked'); }, '#trainee-t1');
  await run('add-player-by-email', asCoachA(), async pg => {
    await pg.click('[data-act="addByEmail"]'); await pg.fill('#abe-email', 'coach.b@example.com'); await pg.click('.sheet button[type="submit"]'); await pg.waitForTimeout(700);
    if (!(await text(pg)).toLowerCase().includes('coach.b') || !/#trainee-p/.test(await pg.evaluate(() => location.hash))) throw new Error('profile not opened'); }, '#trainees');
  await run('delete-user-unlinks', asOwner({ linked: true }), async pg => {
    await pg.click('nav.tabs a[href="#users"]'); await pg.waitForSelector(`[data-act="delUser"][data-id="${PLAYER.id}"]`); await pg.click(`[data-act="delUser"][data-id="${PLAYER.id}"]`);
    await pg.waitForSelector('.sheet'); await pg.click('.sheet button[type="submit"]'); await pg.waitForTimeout(600);
    if (await pg.locator(`[data-act="delUser"][data-id="${PLAYER.id}"]`).count()) throw new Error('user still listed');
    await pg.goto('http://localhost:8765/#trainee-t1'); await pg.waitForTimeout(600); if (await pg.locator('[data-act="unlink"]').count()) throw new Error('still linked'); });

  // Player: one 360 view across coaches
  await run('player-360', { ...shared(), user: PLAYER, docs: (() => { const w = shared(); w.docs.find(d => d.id === 't1' && d.collection === 'trainees').data.linkedUserId = PLAYER.id; return w.docs; })() }, async pg => {
    await pg.waitForSelector('.ptabs'); if (await pg.locator('nav.tabs').isVisible()) throw new Error('admin tabs visible');
    const chip = await pg.innerText('#userChip'); if (!chip.includes('Sample Player') || !chip.includes('Player · Freelance coaches')) throw new Error('chip ' + chip);
    await pg.click('[data-ptab="progress"]'); await pg.waitForTimeout(300); const t = await text(pg);
    if (!t.includes('Forehand') || !t.includes('Bandeja')) throw new Error('missing a coach\'s ratings');
    if (!t.includes('B general')) throw new Error('coach B allowed detailed feedback');
    if (t.includes('Solid session')) throw new Error('coach A hid detailed feedback, but it shows');
    if (t.includes('SECRET')) throw new Error('private remarks shown'); });
  await run('player-cancel-request', { ...shared(), user: PLAYER, docs: (() => { const w = shared(); w.docs.find(d => d.id === 't1' && d.collection === 'trainees').data.linkedUserId = PLAYER.id;
      w.docs.push({ collection: 'sessions', id: 'x9', data: { id: 'x9', date: '2027-01-12', time: '18:00', duration: 60, status: 'planned', traineeIds: ['t1'], clubId: 'freelance', coachId: COACH_A.id, activities: [], feedback: {} } }); return w.docs; })() }, async pg => {
    await pg.waitForSelector('[data-act="reqCancel"][data-sid="x9"]'); await pg.click('[data-act="reqCancel"][data-sid="x9"]'); await pg.fill('#rq-reason', 'Travel'); await pg.click('.sheet button[type="submit"]'); await pg.waitForTimeout(500);
    const r = await pg.evaluate(() => window.__STUB__.docs.find(d => d.collection === 'requests')); if (!r || r.id !== 'x9:22222222-2222-4222-8222-222222222222' || r.data.coachId !== 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa') throw new Error('request ' + JSON.stringify(r)); });
  await run('player-withdraw-resend', { ...shared(), user: PLAYER, docs: (() => { const w = shared(); w.docs.find(d => d.id === 't1' && d.collection === 'trainees').data.linkedUserId = PLAYER.id;
      w.docs.push({ collection: 'sessions', id: 'x9', data: { id: 'x9', date: '2027-01-12', time: '18:00', duration: 60, status: 'planned', traineeIds: ['t1'], clubId: 'freelance', coachId: COACH_A.id, activities: [], feedback: {} } });
      w.docs.push({ collection: 'requests', id: 'x9:' + PLAYER.id, data: { sessionId: 'x9', playerUid: PLAYER.id, playerId: 't1', coachId: COACH_A.id, clubId: 'freelance', status: 'pending', reason: 'Travel', date: '2027-01-12', time: '18:00', seen: true } });
      return w.docs; })() }, async pg => {
    await pg.waitForSelector('[data-act="reqWithdraw"][data-sid="x9"]');
    await pg.click('[data-act="reqCancel"][data-sid="x9"][data-resend]'); await pg.waitForSelector('#rq-reason');
    if (await pg.inputValue('#rq-reason') !== 'Travel') throw new Error('resend not prefilled'); await pg.fill('#rq-reason', 'Travel, still');
    await pg.click('.sheet button[type="submit"]'); await pg.waitForTimeout(500);
    if (await pg.evaluate(() => window.__STUB__.docs.find(d => d.collection === 'requests').data.reason) !== 'Travel, still') throw new Error('not resent');
    await pg.click('[data-act="reqWithdraw"][data-sid="x9"]'); await pg.click('[data-act="reqWithdraw"][data-sid="x9"]'); await pg.waitForTimeout(500);
    if (await pg.evaluate(() => window.__STUB__.docs.some(d => d.collection === 'requests'))) throw new Error('not withdrawn');
    await pg.waitForSelector('[data-act="reqCancel"][data-sid="x9"]:not([data-resend])', { timeout: 3000 }); });
  await run('coach-sees-request', asCoachA({ linked: true, extra: [{ collection: 'requests', id: 'x1:' + PLAYER.id, data: { sessionId: 'x1', playerUid: PLAYER.id, playerId: 't1', coachId: COACH_A.id, clubId: 'freelance', status: 'pending', reason: 'Sick', date: '2026-10-28', time: '18:00' } }] }), async pg => {
    await pg.click('nav.tabs a[href="#trainees"]'); await pg.waitForSelector('[data-act="declineCancel"]'); await pg.click('[data-act="declineCancel"]'); await pg.waitForTimeout(400);
    const r = await pg.evaluate(() => window.__STUB__.docs.find(d => d.collection === 'requests').data); if (r.status !== 'declined' || r.seen !== false) throw new Error('not declined ' + JSON.stringify(r)); });
  await run('coach-as-player', (() => { const w = asCoachA(); w.docs.find(d => d.collection === 'trainees').data.linkedUserId = COACH_A.id; return w; })(), async pg => {
    await pg.waitForSelector('#viewSwitch:not([hidden])'); await pg.click('[data-viewas="player"]'); await pg.waitForSelector('.ptabs');
    await pg.click('[data-viewas="coach"]'); await pg.waitForSelector('nav.tabs a'); });
  // Courts
  const OTHER = (date, time, court) => ({ collection: 'sessions', id: 'other', data: { id: 'other', date, time, duration: 60, status: 'planned', location: 'Padel Pro', courtId: court, courtName: 'Court 1', traineeIds: [], clubId: 'freelance', coachId: COACH_B.id } });
  await run('court-required', asCoachA(), async pg => {
    await pg.locator('[data-act="newSessionOn"]').first().click(); await pg.waitForSelector('#se-court'); await pg.selectOption('#se-court', '');
    await pg.click('.sheet button[type="submit"]'); await pg.waitForTimeout(200);
    if (!(await text(pg)).includes('Choose a court.')) throw new Error('saved without a court');
    await pg.selectOption('#se-court', 'padel-pro-c2'); await pg.click('.sheet button[type="submit"]'); await pg.waitForTimeout(500);
    const s = await pg.evaluate(() => window.__STUB__.docs.filter(d => d.collection === 'sessions' && d.data.courtId === 'padel-pro-c2'));
    if (s.length !== 1 || s[0].data.courtName !== 'Court 2') throw new Error('not booked ' + JSON.stringify(s));
    if (!(await text(pg)).includes('Padel Pro · Court 2')) throw new Error('court not shown on the session'); });
  await run('court-busy-shown', asCoachA({ extra: [OTHER('2027-03-02', '18:00', 'padel-pro-c1')] }), async pg => {
    await pg.locator('[data-act="newSessionOn"]').first().click(); await pg.waitForSelector('#se-court'); await pg.fill('#se-date', '2027-03-02'); await pg.dispatchEvent('#se-date', 'change');
    await pg.fill('#se-time', '18:30'); await pg.dispatchEvent('#se-time', 'change'); await pg.waitForTimeout(400);
    const dis = await pg.$eval('#se-court option[value="padel-pro-c1"]', o => ({ d: o.disabled, t: o.textContent }));
    if (!dis.d || !dis.t.includes('booked 18:00–19:00')) throw new Error('busy court not marked ' + JSON.stringify(dis));
    if (await pg.$eval('#se-court option[value="padel-pro-c2"]', o => o.disabled)) throw new Error('free court disabled');
    if ((await text(pg)).includes('Coach B')) throw new Error('shows who booked it'); });
  await run('court-optional-without-courts', (() => { const w = asCoachA(); w.docs.filter(d => d.collection === 'venues').forEach(d => { d.data.courts = []; }); return w; })(), async pg => {
    await pg.locator('[data-act="newSessionOn"]').first().click(); await pg.waitForSelector('#se-time');
    if (await pg.locator('#se-court-wrap').isVisible()) throw new Error('court field shown for a venue without courts');
    await pg.click('.sheet button[type="submit"]'); await pg.waitForTimeout(500);
    if (await pg.locator('.sheet').count()) throw new Error('could not save without a court'); });
  await run('court-busy-on-save', asCoachA({ extra: [OTHER('2027-03-02', '18:00', 'padel-pro-c1')] }), async pg => {
    // the database rejects a clash even if the screen did not know about it
    await pg.evaluate(() => { window.__STUB__.hideBusy = true; });
    await pg.locator('[data-act="newSessionOn"]').first().click(); await pg.waitForSelector('#se-court'); await pg.fill('#se-date', '2027-03-02'); await pg.fill('#se-time', '18:30');
    await pg.selectOption('#se-court', 'padel-pro-c1'); await pg.click('.sheet button[type="submit"]'); await pg.waitForTimeout(500);
    if (!(await text(pg)).includes('That court is already booked at this time (18:00–19:00)')) throw new Error('no clash message');
    if (await pg.evaluate(() => window.__STUB__.docs.filter(d => d.collection === 'sessions' && d.data.courtId === 'padel-pro-c1').length) !== 1) throw new Error('clash saved'); });
  await run('venue-courts', asOwner(), async pg => {
    await pg.click('nav.tabs a[href="#clubs"]'); await pg.waitForTimeout(300); const tx = await text(pg);
    if (!tx.includes('Court 4')) throw new Error('courts not listed');
    await pg.click('[data-act="editClub"]'); await pg.click('[data-addcourt]'); await pg.fill('#ct-en-4', 'Center Court'); await pg.click('.sheet button[type="submit"]'); await pg.waitForTimeout(500);
    const v = await pg.evaluate(() => window.__STUB__.docs.find(d => d.collection === 'venues').data.courts); if (v.length !== 5 || v[4].name !== 'Center Court' || v[0].id !== 'padel-pro-c1') throw new Error('courts ' + JSON.stringify(v)); });

  // Cancelling: choose whether the players are told
  await run('cancel-notify-choice', (() => { const w = asCoachA({ extra: [{ collection: 'sessions', id: 'cn1', data: { id: 'cn1', date: '2030-05-01', time: '18:00', duration: 60, status: 'planned', location: 'Padel Pro', traineeIds: ['t1'], clubId: 'freelance', coachId: COACH_A.id } }, { collection: 'sessions', id: 'cn2', data: { id: 'cn2', date: '2030-05-02', time: '18:00', duration: 60, status: 'planned', location: 'Padel Pro', traineeIds: ['t1'], clubId: 'freelance', coachId: COACH_A.id } }, { collection: 'sessions', id: 'cn3', data: { id: 'cn3', date: '2030-05-03', time: '18:00', duration: 60, status: 'planned', location: 'Padel Pro', traineeIds: ['t1'], clubId: 'freelance', coachId: COACH_A.id } }] }); w.docs.find(d => d.id === 't1' && d.collection === 'trainees').data.linkedUserId = PLAYER.id; return w; })(), async pg => {
    const reqs = () => pg.evaluate(() => window.__STUB__.docs.filter(d => d.collection === 'requests' && d.data.status === 'coachCancelled').map(d => d.data.sessionId));
    const sess = id => pg.evaluate(id => window.__STUB__.docs.find(d => d.collection === 'sessions' && d.id === id).data, id);
    await pg.evaluate(() => { location.hash = 'trainee-t1'; }); await pg.waitForSelector('#trSessions [data-act="cancelSession"][data-id="cn1"]');
    await pg.click('#trSessions [data-act="cancelSession"][data-id="cn1"]'); await pg.waitForSelector('#cs-notify');
    if (!(await pg.isChecked('#cs-notify'))) throw new Error('notify not ticked by default');
    await pg.uncheck('#cs-notify'); await pg.click('.sheet button[type="submit"]'); await pg.waitForTimeout(400);
    let d = await sess('cn1'); if (d.status !== 'cancelled' || d.notifyPlayers !== false) throw new Error('quiet cancel not saved ' + JSON.stringify(d));
    if ((await reqs()).includes('cn1')) throw new Error('player notice created for a quiet cancel');
    await pg.click('#trSessions [data-act="cancelSession"][data-id="cn2"]'); await pg.waitForSelector('#cs-notify');
    await pg.click('.sheet button[type="submit"]'); await pg.waitForTimeout(400);
    d = await sess('cn2'); if (d.notifyPlayers !== true) throw new Error('notify flag not saved');
    if (!(await reqs()).includes('cn2')) throw new Error('player not told');
    await pg.click('#trSessions [data-act="editSession"][data-id="cn3"]'); await pg.waitForSelector('#se-status');
    if (!(await pg.$eval('#se-notify-wrap', e => e.hidden))) throw new Error('choice shown before choosing Cancelled');
    await pg.selectOption('#se-status', 'cancelled'); if (await pg.$eval('#se-notify-wrap', e => e.hidden)) throw new Error('choice not shown for Cancelled');
    await pg.uncheck('#se-notify'); await pg.click('.sheet button[type="submit"]'); await pg.waitForTimeout(500);
    d = await sess('cn3'); if (d.status !== 'cancelled' || d.notifyPlayers !== false) throw new Error('edit-form quiet cancel not saved ' + JSON.stringify(d));
    if ((await reqs()).includes('cn3')) throw new Error('player notice created for a quiet cancel (edit form)');
  });

  // Bulk edit from the player page
  await run('bulk-edit', asCoachA({ extra: [{ collection: 'sessions', id: 'bk1', data: { id: 'bk1', date: '2030-07-01', time: '18:00', duration: 60, status: 'planned', location: 'Padel Pro', traineeIds: ['t1'], clubId: 'freelance', coachId: COACH_A.id } }, { collection: 'sessions', id: 'bk2', data: { id: 'bk2', date: '2030-07-08', time: '18:00', duration: 60, status: 'planned', location: 'Padel Pro', traineeIds: ['t1'], clubId: 'freelance', coachId: COACH_A.id } }, { collection: 'sessions', id: 'bk3', data: { id: 'bk3', date: '2030-07-15', time: '18:00', duration: 60, status: 'planned', location: 'Padel Pro', traineeIds: ['t1'], clubId: 'freelance', coachId: COACH_A.id } }] }), async pg => {
    await pg.evaluate(() => { location.hash = 'trainee-t1'; }); await pg.waitForSelector('[data-act="trSelOn"]');
    await pg.click('[data-act="trSelOn"]'); await pg.waitForSelector('[data-trpick="bk1"]');
    await pg.check('[data-trpickall]'); await pg.waitForTimeout(150);
    if (!(await pg.textContent('.bulkbar')).includes('3 selected')) throw new Error('select all: ' + await pg.textContent('.bulkbar'));
    await pg.uncheck('[data-trpickall]'); await pg.waitForTimeout(150);
    await pg.check('[data-trpick="bk1"]'); await pg.check('[data-trpick="bk2"]');
    if (!(await pg.textContent('.bulkbar')).includes('2 selected')) throw new Error('count not shown');
    await pg.click('[data-act="trBulkEdit"]'); await pg.waitForSelector('#bk-time');
    await pg.click('.sheet button[type="submit"]'); await pg.waitForTimeout(200);
    if (!/at least one change/i.test(await pg.textContent('.sheet'))) throw new Error('empty bulk edit accepted');
    await pg.screenshot({ path: '/tmp/claude-0/-home-claude/b67e96e7-5324-5d1c-8f05-8bec10272ab4/scratchpad/shots/bulk-sheet.png' });
    await pg.fill('#bk-time', '19:30'); await pg.fill('#bk-dur', '90'); await pg.selectOption('#bk-status', 'cancelled'); await pg.uncheck('#bk-notify');
    await pg.click('.sheet button[type="submit"]'); await pg.waitForTimeout(600);
    const got = await pg.evaluate(() => ['bk1', 'bk2', 'bk3'].map(id => window.__STUB__.docs.find(d => d.collection === 'sessions' && d.id === id).data));
    for (const d of got.slice(0, 2)) if (d.time !== '19:30' || d.duration !== 90 || d.status !== 'cancelled' || d.notifyPlayers !== false || !d.bulkEdit) throw new Error('not applied ' + JSON.stringify(d));
    if (got[2].time !== '18:00' || got[2].status !== 'planned') throw new Error('unselected session changed');
    if (got[0].location !== 'Padel Pro') throw new Error('venue changed although kept');
    if (!(await text(pg)).includes('2 of 2 sessions updated')) throw new Error('no result summary');
    if (await pg.evaluate(() => window.__STUB__.docs.some(d => d.collection === 'requests' && d.data.status === 'coachCancelled'))) throw new Error('players told although unticked');
  });

  // Skills: the missing name is predicted (exact terms, close matches, and when opening a skill with one name)
  await run('skill-predict', (() => { const w = asOwner(); w.docs.push({ collection: 'skills', id: 'skx', data: { id: 'skx', name_en: 'Bandeja', name_ar: '', category: 'overhead', clubId: 'freelance' } }); return w; })(), async pg => {
    await pg.click('nav.tabs a[href="#skills"]'); await pg.waitForSelector('[data-act="editSkill"][data-id="skx"]');
    await pg.click('[data-act="editSkill"][data-id="skx"]'); await pg.waitForSelector('#sk-ar'); await pg.waitForTimeout(150);
    if ((await pg.inputValue('#sk-ar')) !== 'البانديخا') throw new Error('missing Arabic not predicted on open: ' + await pg.inputValue('#sk-ar'));
    await pg.keyboard.press('Escape'); await pg.waitForTimeout(200);
    await pg.click('[data-act="newSkill"]'); await pg.waitForSelector('#sk-en');
    await pg.fill('#sk-en', 'forehand drive'); await pg.waitForTimeout(100);
    const ar = await pg.inputValue('#sk-ar'); if (!ar) throw new Error('close match not filled');
    if (await pg.$eval('#pred-ar', e => e.hidden)) throw new Error('no "check it" note for a guess');
    await pg.fill('#sk-en', ''); await pg.fill('#sk-ar', 'فولي أمامية'); await pg.waitForTimeout(100);
    if ((await pg.inputValue('#sk-en')) !== 'Forehand volley') throw new Error('Arabic to English not predicted: ' + await pg.inputValue('#sk-en'));
    await pg.fill('#sk-ar', ''); await pg.fill('#sk-en', 'power smash drill'); await pg.waitForTimeout(100);
    if (!(await pg.inputValue('#sk-ar'))) throw new Error('word-by-word guess not filled');
    await pg.fill('#sk-en', 'My own name'); await pg.fill('#sk-ar', 'سماش'); await pg.waitForTimeout(100);
    if ((await pg.inputValue('#sk-en')) !== 'My own name') throw new Error('typed name overwritten');
  });

  // Players page: one per row, search, drag to order, move to top/bottom
  await run('players-order', (() => { const w = asCoachA(); ['Zed', 'Amy', 'Bob'].forEach((n, i) => { w.docs.push({ collection: 'trainees', id: 'po' + i, data: { id: 'po' + i, name: n } });
      (w.players = w.players || []).push({ org_id: 'freelance', player_id: 'po' + i }); (w.enroll = w.enroll || []).push({ org_id: 'freelance', player_id: 'po' + i, coach_id: COACH_A.id }); }); return w; })(), async pg => {
    await pg.click('nav.tabs a[href="#trainees"]'); await pg.waitForSelector('#trList .trrow');
    const order = () => pg.$$eval('#trList .trrow', r => r.map(x => x.dataset.id));
    const ids = await order(); if (ids.length < 3) throw new Error('rows ' + ids.length);
    const tops = await pg.$$eval('#trList .trrow', r => r.map(x => Math.round(x.getBoundingClientRect().left)));
    if (new Set(tops).size !== 1) throw new Error('not one player per row');
    // drag the last row to the top
    const last = (await pg.$$('#trList .draghandle')).pop(), first = (await pg.$$('#trList .draghandle'))[0];
    const a = await last.boundingBox(), b = await first.boundingBox();
    await pg.mouse.move(a.x + a.width / 2, a.y + a.height / 2); await pg.mouse.down();
    await pg.mouse.move(b.x + b.width / 2, b.y + 40, { steps: 8 }); await pg.waitForTimeout(120); await pg.screenshot({ path: '/tmp/claude-0/-home-claude/b67e96e7-5324-5d1c-8f05-8bec10272ab4/scratchpad/shots/drag-mid.png' }); await pg.mouse.move(b.x + b.width / 2, b.y + 2, { steps: 4 }); await pg.mouse.up(); await pg.waitForTimeout(300);
    const after = await order(); if (after[0] !== ids[ids.length - 1]) throw new Error('drag did not move to top: ' + after.join());
    const saved = await pg.evaluate(() => (window.__STUB__.playerOrder || {}).freelance || []); if (saved.join() !== after.join()) throw new Error('order not saved');
    // move to bottom / top buttons
    await pg.click('#trList .trrow:first-child [data-move="bottom"]'); await pg.waitForTimeout(200);
    if ((await order()).pop() !== after[0]) throw new Error('move to bottom');
    await pg.click('#trList .trrow:last-child [data-move="top"]'); await pg.waitForTimeout(200);
    if ((await order())[0] !== after[0]) throw new Error('move to top');
    // the saved order is used when the page is drawn again
    await pg.click('nav.tabs a[href="#week"]'); await pg.click('nav.tabs a[href="#trainees"]'); await pg.waitForSelector('#trList .trrow');
    if ((await order())[0] !== after[0]) throw new Error('order lost after leaving the page');
    // search
    await pg.fill('#trSearch', 'amy'); await pg.waitForTimeout(100);
    const vis = await pg.$$eval('#trList .trrow:not([hidden])', r => r.map(x => x.dataset.id)); if (vis.join() !== 'po1') throw new Error('search: ' + vis.join());
    await pg.fill('#trSearch', 'nobody-here'); if (await pg.$eval('.trnone', e => e.hidden)) throw new Error('no-match message');
    await pg.fill('#trSearch', ''); await pg.click('[data-act="orderAZ"]'); await pg.waitForTimeout(300);
    if ((await pg.evaluate(() => (window.__STUB__.playerOrder || {}).freelance))) throw new Error('Sort A-Z did not reset');
  });

  // Player page: Cancelled and All tabs; select by status and date range
  await run('trainee-tabs-filters', asCoachA({ extra: [{ collection: 'sessions', id: 'tf1', data: { id: 'tf1', date: '2030-09-02', time: '18:00', duration: 60, status: 'planned', location: 'Padel Pro', traineeIds: ['t1'], clubId: 'freelance', coachId: COACH_A.id } }, { collection: 'sessions', id: 'tf2', data: { id: 'tf2', date: '2030-09-09', time: '18:00', duration: 60, status: 'planned', location: 'Padel Pro', traineeIds: ['t1'], clubId: 'freelance', coachId: COACH_A.id } }, { collection: 'sessions', id: 'tf3', data: { id: 'tf3', date: '2030-09-16', time: '18:00', duration: 60, status: 'cancelled', location: 'Padel Pro', traineeIds: ['t1'], clubId: 'freelance', coachId: COACH_A.id } }, { collection: 'sessions', id: 'tf4', data: { id: 'tf4', date: '2030-10-07', time: '18:00', duration: 60, status: 'planned', location: 'Padel Pro', traineeIds: ['t1'], clubId: 'freelance', coachId: COACH_A.id } }] }), async pg => {
    await pg.evaluate(() => { location.hash = 'trainee-t1'; }); await pg.waitForSelector('[data-trsess="cancelled"]');
    if (await pg.$('#trSessions [data-id="tf3"]')) throw new Error('cancelled session shown under Upcoming');
    await pg.click('[data-trsess="cancelled"]'); await pg.waitForTimeout(200);
    if (!(await pg.$('#trSessions [data-act="editSession"][data-id="tf3"]'))) throw new Error('cancelled session not editable in Cancelled tab');
    if (await pg.$('#trSessions [data-id="tf1"]')) throw new Error('planned session under Cancelled');
    await pg.click('[data-trsess="all"]'); await pg.waitForTimeout(200);
    for (const id of ['tf1', 'tf2', 'tf3', 'tf4']) if (!(await pg.$('#trSessions [data-act="editSession"][data-id="' + id + '"]'))) throw new Error('All tab misses ' + id);
    await pg.click('[data-act="trSelOn"][data-tab="all"]'); await pg.waitForSelector('[data-trflt="status"]');
    await pg.selectOption('[data-trflt="status"]', 'planned'); await pg.fill('[data-trflt="from"]', '2030-09-01'); await pg.fill('[data-trflt="to"]', '2030-09-30');
    await pg.click('[data-act="trPickMatch"]'); await pg.waitForTimeout(200);
    const picked = await pg.$$eval('[data-trpick]:checked', x => x.map(e => e.dataset.trpick).sort().join(','));
    if (picked !== 'tf1,tf2') throw new Error('matching picked: ' + picked);
    await pg.selectOption('[data-trflt="status"]', 'cancelled'); await pg.fill('[data-trflt="from"]', ''); await pg.fill('[data-trflt="to"]', '');
    await pg.click('[data-act="trPickMatch"]'); await pg.waitForTimeout(200);
    if ((await pg.$$eval('[data-trpick]:checked', x => x.map(e => e.dataset.trpick).join(','))) !== 'tf3') throw new Error('status filter');
    if (!(await pg.$('[data-act="trBulkEdit"]:not([disabled])'))) throw new Error('bulk edit not available in All tab');
  });

  // Bulk permanent delete from the player page
  await run('bulk-purge-no-permission', asCoachA({ extra: [{ collection: 'sessions', id: 'bp1', data: { id: 'bp1', date: '2030-08-01', time: '18:00', duration: 60, status: 'planned', location: 'Padel Pro', traineeIds: ['t1'], clubId: 'freelance', coachId: COACH_A.id } }, { collection: 'sessions', id: 'bp2', data: { id: 'bp2', date: '2030-08-02', time: '18:00', duration: 60, status: 'planned', location: 'Padel Pro', traineeIds: ['t1'], clubId: 'freelance', coachId: COACH_A.id } }] }), async pg => {
    await pg.evaluate(() => { location.hash = 'trainee-t1'; }); await pg.waitForSelector('[data-act="trSelOn"]');
    await pg.click('[data-act="trSelOn"]'); await pg.check('[data-trpick="bp1"]'); await pg.waitForTimeout(200);
    if (await pg.$('[data-act="trBulkPurge"]')) throw new Error('coach without permission offered bulk delete');
  });
  await run('bulk-purge', (() => { const w = asCoachA({ extra: [{ collection: 'sessions', id: 'bp3', data: { id: 'bp3', date: '2030-08-03', time: '18:00', duration: 60, status: 'planned', location: 'Padel Pro', traineeIds: ['t1'], clubId: 'freelance', coachId: COACH_A.id } }, { collection: 'sessions', id: 'bp4', data: { id: 'bp4', date: '2030-08-04', time: '18:00', duration: 60, status: 'planned', location: 'Padel Pro', traineeIds: ['t1'], clubId: 'freelance', coachId: COACH_A.id } }, { collection: 'sessions', id: 'bp5', data: { id: 'bp5', date: '2020-08-05', time: '18:00', duration: 60, status: 'done', location: 'Padel Pro', traineeIds: ['t1'], clubId: 'freelance', coachId: COACH_A.id } }, { collection: 'sessions', id: 'bp6', data: { id: 'bp6', date: '2020-08-06', time: '18:00', duration: 60, status: 'done', location: 'Padel Pro', traineeIds: ['t1'], clubId: 'freelance', coachId: COACH_A.id } }] }); w.members.find(m => m.user_id === COACH_A.id && m.org_id === 'freelance').can_delete = true; return w; })(), async pg => {
    await pg.evaluate(() => { location.hash = 'trainee-t1'; }); await pg.waitForSelector('[data-act="trSelOn"]'); await pg.waitForTimeout(300);
    await pg.click('[data-act="trSelOn"]'); await pg.check('[data-trpick="bp3"]'); await pg.check('[data-trpick="bp4"]');
    await pg.click('[data-act="trBulkPurge"]'); if (!/again/i.test(await pg.textContent('[data-act="trBulkPurge"]'))) throw new Error('no confirm step');
    await pg.click('[data-act="trBulkPurge"]'); await pg.waitForTimeout(600);
    const left = await pg.evaluate(() => window.__STUB__.docs.filter(d => d.collection === 'sessions' && /^bp/.test(d.id)).map(d => d.id).sort().join(','));
    if (left !== 'bp5,bp6') throw new Error('left: ' + left);
    if (!(await text(pg)).includes('2 of 2 sessions deleted permanently')) throw new Error('no summary');
    await pg.click('[data-trsess="past"]'); await pg.waitForSelector('[data-act="trSelOn"][data-tab="past"]');
    await pg.click('[data-act="trSelOn"][data-tab="past"]'); await pg.check('[data-trpick="bp5"]');
    await pg.click('[data-act="trBulkPurge"]'); await pg.click('[data-act="trBulkPurge"]'); await pg.waitForTimeout(500);
    if (await pg.evaluate(() => window.__STUB__.docs.some(d => d.collection === 'sessions' && d.id === 'bp5'))) throw new Error('past session not deleted');
  });

  // Cancel button says whether players will be told
  await run('cancel-button-label', asCoachA({ extra: [{ collection: 'sessions', id: 'lb1', data: { id: 'lb1', date: '2030-05-11', time: '18:00', duration: 60, status: 'planned', location: 'Padel Pro', traineeIds: ['t1'], clubId: 'freelance', coachId: COACH_A.id } }] }), async pg => {
    await pg.evaluate(() => { location.hash = 'trainee-t1'; }); await pg.waitForSelector('#trSessions [data-act="cancelSession"][data-id="lb1"]');
    await pg.click('#trSessions [data-act="cancelSession"][data-id="lb1"]'); await pg.waitForSelector('#cs-notify');
    const lbl = () => pg.textContent('.sheet button[type="submit"]');
    if (!/notify players/i.test(await lbl())) throw new Error('ticked label: ' + await lbl());
    await pg.uncheck('#cs-notify'); if (!/without notifying/i.test(await lbl())) throw new Error('unticked label: ' + await lbl());
    await pg.keyboard.press('Escape'); await pg.waitForTimeout(200);
    await pg.click('#trSessions [data-act="editSession"][data-id="lb1"]'); await pg.waitForSelector('#se-status');
    await pg.selectOption('#se-status', 'cancelled'); if (!/notify players/i.test(await lbl())) throw new Error('edit form label: ' + await lbl());
    await pg.uncheck('#se-notify'); if (!/without notifying/i.test(await lbl())) throw new Error('edit form unticked label: ' + await lbl());
    await pg.selectOption('#se-status', 'planned'); if ((await lbl()).trim() !== 'Save') throw new Error('label not back to Save');
  });
  // Permanent delete: coach needs permission from a club admin
  await run('purge-no-permission', asCoachA({ extra: [{ collection: 'sessions', id: 'pg1', data: { id: 'pg1', date: '2030-05-12', time: '18:00', duration: 60, status: 'planned', location: 'Padel Pro', traineeIds: ['t1'], clubId: 'freelance', coachId: COACH_A.id } }] }), async pg => {
    await pg.evaluate(() => { location.hash = 'trainee-t1'; }); await pg.waitForSelector('#trSessions [data-act="editSession"][data-id="pg1"]');
    await pg.click('#trSessions [data-act="editSession"][data-id="pg1"]'); await pg.waitForSelector('#se-status'); await pg.waitForTimeout(300);
    if (await pg.$('.sheet [data-del]')) throw new Error('coach without permission can delete');
  });
  await run('purge-with-permission', (() => { const w = asCoachA({ extra: [{ collection: 'sessions', id: 'pg2', data: { id: 'pg2', date: '2030-05-13', time: '18:00', duration: 60, status: 'planned', location: 'Padel Pro', traineeIds: ['t1'], clubId: 'freelance', coachId: COACH_A.id } }] }); w.members.find(m => m.user_id === COACH_A.id && m.org_id === 'freelance').can_delete = true; return w; })(), async pg => {
    await pg.evaluate(() => { location.hash = 'trainee-t1'; }); await pg.waitForSelector('#trSessions [data-act="editSession"][data-id="pg2"]'); await pg.waitForTimeout(300);
    await pg.click('#trSessions [data-act="editSession"][data-id="pg2"]'); await pg.waitForSelector('.sheet [data-del]');
    if (!/delete permanently/i.test(await pg.textContent('.sheet [data-del]'))) throw new Error('button label');
    await pg.click('.sheet [data-del]'); await pg.click('.sheet [data-del]'); await pg.waitForTimeout(500);
    if (await pg.evaluate(() => window.__STUB__.docs.some(d => d.collection === 'sessions' && d.id === 'pg2'))) throw new Error('session not deleted');
    if (await pg.$('#trSessions [data-id="pg2"]')) throw new Error('still listed');
  });
  await run('purge-permission-admin', asOwner(), async pg => {
    await pg.click('nav.tabs a[href="#team"]'); await pg.waitForSelector('[data-delperm]');
    await pg.check('[data-delperm="' + COACH_A.id + '"]'); await pg.waitForTimeout(300);
    if (!(await pg.evaluate(id => window.__STUB__.members.find(m => m.user_id === id && m.org_id === 'freelance').can_delete, COACH_A.id))) throw new Error('permission not saved');
  });
  await run('deleted-log-restore', { ...asOwner(), deletedLog: [{ id: 1, session_id: 'gone1', club_id: 'freelance', data: { id: 'gone1', date: '2030-06-01', time: '19:00', status: 'planned', location: 'Padel Pro', traineeIds: ['t1'], clubId: 'freelance', coachId: COACH_A.id }, deleted_at: new Date().toISOString(), deleted_by_name: 'Coach A' }] }, async pg => {
    await pg.click('nav.tabs a[href="#deletedlog"]'); await pg.waitForSelector('[data-act="dlRestore"]');
    if (!(await text(pg)).includes('Deleted by Coach A')) throw new Error('who deleted not shown');
    await pg.click('[data-act="dlRestore"]'); await pg.click('[data-act="dlRestore"]'); await pg.waitForTimeout(500);
    if (!(await pg.evaluate(() => window.__STUB__.docs.some(d => d.collection === 'sessions' && d.id === 'gone1')))) throw new Error('not restored');
    if (!(await text(pg)).includes('Restored')) throw new Error('log does not show Restored');
  });

  // Arabic: time fields keep their value and show hours on the left
  await run('arabic-time-fields', asCoachA({ extra: [{ collection: 'sessions', id: 'at1', data: { id: 'at1', date: '2030-04-01', time: '18:30', duration: 60, status: 'planned', location: 'Padel Pro', traineeIds: ['t1'], clubId: 'freelance', coachId: COACH_A.id } }] }), async pg => {
    await pg.waitForSelector('#langBtn'); await pg.click('#langBtn'); await pg.waitForTimeout(300);
    const hoursLeft = async sel => pg.$eval(sel, el => { const cs = getComputedStyle(el); return cs.direction === 'ltr'; });
    await pg.evaluate(() => { location.hash = 'trainee-t1'; }); await pg.waitForSelector('#trSessions [data-act="editSession"][data-id="at1"]');
    await pg.click('#trSessions [data-act="editSession"][data-id="at1"]'); await pg.waitForSelector('#se-time');
    if ((await pg.inputValue('#se-time')) !== '18:30') throw new Error('session time field empty in Arabic: ' + await pg.inputValue('#se-time'));
    if (!(await hoursLeft('#se-time'))) throw new Error('session time field is right-to-left');
    await (await pg.$('#se-time')).screenshot({ path: '/tmp/claude-0/-home-claude/b67e96e7-5324-5d1c-8f05-8bec10272ab4/scratchpad/shots/ar-time-field.png' });
    await pg.keyboard.press('Escape'); await pg.waitForTimeout(200);
    if (await pg.$('[data-act="editSlot"]')) { await pg.click('[data-act="editSlot"]'); await pg.waitForSelector('#sl-time');
      if (!(await pg.inputValue('#sl-time'))) throw new Error('weekly slot time empty in Arabic');
      if (!(await hoursLeft('#sl-time'))) throw new Error('weekly slot time field is right-to-left');
      await pg.keyboard.press('Escape'); }
    else throw new Error('no weekly slot to check');
  });

  // Players list: each card counts only the sessions still ahead
  await run('remaining-sessions', asCoachA({ extra: [
      { collection: 'sessions', id: 'r1', data: { id: 'r1', date: '2030-03-01', time: '18:00', duration: 60, status: 'planned', location: 'Padel Pro', traineeIds: ['t1'], clubId: 'freelance', coachId: COACH_A.id } },
      { collection: 'sessions', id: 'r2', data: { id: 'r2', date: '2030-03-08', time: '18:00', duration: 60, status: 'planned', location: 'Padel Pro', traineeIds: ['t1'], clubId: 'freelance', coachId: COACH_A.id } },
      { collection: 'sessions', id: 'r3', data: { id: 'r3', date: '2030-03-15', time: '18:00', duration: 60, status: 'cancelled', location: 'Padel Pro', traineeIds: ['t1'], clubId: 'freelance', coachId: COACH_A.id } }] }), async pg => {
    await pg.click('nav.tabs a[href="#trainees"]'); await pg.waitForSelector('a[href="#trainee-t1"]');
    const c = await pg.textContent('a[href="#trainee-t1"]');
    if (!/2 remaining sessions/.test(c)) throw new Error('card shows: ' + c.replace(/\s+/g, ' ').slice(0, 200));
  });

  // Player page shows the player's photo (initials when there is none)
  await run('player-photo', (() => { const w = asCoachA(); w.docs.find(d => d.id === 't1' && d.collection === 'trainees').data.linkedUserId = PLAYER.id;
      (w.users = w.users || []).some(u => u.id === PLAYER.id) || w.users.push(PLAYER);
      w.profiles = [...(w.profiles || []).filter(p => p.id !== PLAYER.id), { id: PLAYER.id, email: PLAYER.email, full_name: 'Sample Player', avatar_path: PLAYER.id + '/a.jpg' }]; return w; })(), async pg => {
    await pg.evaluate(() => { location.hash = 'trainee-t1'; }); await pg.waitForSelector('.trphoto');
    await pg.waitForSelector('.trphoto img.av', { timeout: 4000 }).catch(() => {});
    if (!(await pg.$('.trphoto img.av'))) throw new Error('no photo on the player page');
    await pg.click('.trphoto-link'); await pg.waitForSelector('.photobox img');
    if (pg.context().pages().length > 1) throw new Error('photo opened a new page');
    await pg.keyboard.press('Escape'); await pg.waitForTimeout(150); if (await pg.$('.photobox')) throw new Error('pop-up did not close');
    await pg.screenshot({ path: '/tmp/claude-0/-home-claude/b67e96e7-5324-5d1c-8f05-8bec10272ab4/scratchpad/shots/player-photo-page.png', clip: { x: 0, y: 0, width: 1280, height: 420 } });
    await pg.evaluate(() => { location.hash = 'trainee-t2'; }); await pg.waitForTimeout(300);
    if (await pg.$('.trphoto') && !(await pg.$('.trphoto span.av'))) throw new Error('no initials for a player without a photo');
  });

  // Club settings: suggested planned sessions on/off
  await run('club-settings', asOwner(), async pg => {
    await pg.click('nav.tabs a[href="#clubsettings"]'); await pg.waitForSelector('[data-clubset="suggestPlanned"]');
    if (!(await pg.isChecked('[data-clubset="suggestPlanned"]'))) throw new Error('suggestions not on by default');
    await pg.uncheck('[data-clubset="suggestPlanned"]'); await pg.waitForTimeout(300);
    if ((await pg.evaluate(() => window.__STUB__.orgs.find(o => o.id === 'freelance').settings || {})).suggestPlanned !== false) throw new Error('setting not saved');
  });
  await run('system-settings', asOwner(), async pg => {
    await pg.click('nav.tabs a[href="#syssettings"]'); await pg.waitForSelector('[data-sysset="defaultClub"]');
    await pg.selectOption('[data-sysset="defaultClub"]', 'freelance'); await pg.waitForTimeout(300);
    if ((await pg.evaluate(() => window.__STUB__.defaultClub)) !== 'freelance') throw new Error('default club not saved');
    if (!(await text(pg)).toLowerCase().includes('no default coach yet')) throw new Error('missing hint about the default coach');
    await pg.click('[data-act="openClubSettings"]'); await pg.waitForSelector('[data-clubset="defaultCoach"]');
    if (!(await text(pg)).includes("platform's default club")) throw new Error('club settings do not say this is the default club');
    const opts = await pg.$$eval('[data-clubset="defaultCoach"] option', o => o.map(x => x.value).filter(Boolean));
    if (!opts.length) throw new Error('no coaches to choose');
    await pg.selectOption('[data-clubset="defaultCoach"]', opts[0]); await pg.waitForTimeout(300);
    if ((await pg.evaluate(() => window.__STUB__.orgs.find(o => o.id === 'freelance').settings || {})).defaultCoach !== opts[0]) throw new Error('default coach not saved');
    await pg.click('nav.tabs a[href="#syssettings"]'); await pg.waitForTimeout(300);
    if (!(await text(pg)).includes('as players of')) throw new Error('summary does not name the coach');
  });
  const ghostsOf = async pg => { await pg.waitForSelector('#wkf-cancelled'); await pg.waitForTimeout(400); return pg.$$eval('.ghost', x => x.length); };
  await run('suggestions-on', asCoachA(), async pg => { if (!(await ghostsOf(pg))) throw new Error('no suggested sessions when the setting is on'); });
  await run('suggestions-off', { ...asCoachA(), orgs: [{ id: 'freelance', name: 'Freelance coaches', is_freelance: true, settings: { suggestPlanned: false } }, { id: 'academy', name: 'Academy', is_freelance: false }] },
    async pg => { if (await ghostsOf(pg)) throw new Error('suggested sessions shown although the club turned them off'); });
  await run('club-settings-coach', asCoachA(), async pg => {
    await pg.waitForSelector('nav.tabs a[href="#week"]');
    if (await pg.$('nav.tabs a[href="#clubsettings"]')) throw new Error('coach sees club settings');
    if (await pg.$('nav.tabs a[href="#notiflog"]')) throw new Error('coach sees the notification log');
  });
  // Cancelled sessions hidden by default
  await run('hide-cancelled', asCoachA({ extra: [{ collection: 'sessions', id: 'cx1', data: { id: 'cx1', date: new Date().toISOString().slice(0, 10), time: '07:15', duration: 60, status: 'cancelled', location: 'Padel Pro', traineeIds: ['t1'], clubId: 'freelance', coachId: COACH_A.id } }] }), async pg => {
    await pg.waitForSelector('#wkf-cancelled'); await pg.waitForTimeout(300);
    if ((await pg.inputValue('#wkf-cancelled')) !== '') throw new Error('default is not Hide');
    if ((await text(pg)).includes('07:15')) throw new Error('cancelled session shown by default');
    await pg.selectOption('#wkf-cancelled', 'show'); await pg.waitForTimeout(300);
    if (!(await text(pg)).includes('07:15')) throw new Error('cancelled session not shown after choosing Show');
  });
  // Sys admin: notification log
  await run('notification-log', { ...asOwner(), notifs: [
      { id: 7, user_id: PLAYER.id, kind: 'booked', title_en: 'New session booked', body_en: 'Coach A · Tue', title_ar: 'x', body_ar: '', link: '', created_at: new Date().toISOString(), read_at: null, org_id: 'freelance', venue: 'Padel Pro', coach_id: COACH_A.id, player_id: 't1' },
      { id: 6, user_id: COACH_A.id, kind: 'request', title_en: 'Sample asked to cancel', body_en: '', title_ar: 'x', body_ar: '', link: '', created_at: new Date(Date.now() - 3600e3).toISOString(), read_at: new Date().toISOString(), org_id: 'freelance', player_id: 't1' }] }, async pg => {
    await pg.click('nav.tabs a[href="#notiflog"]'); await pg.waitForSelector('.nltable tbody tr');
    const n = await pg.$$eval('.nltable tbody tr', x => x.length); if (n !== 2) throw new Error('rows ' + n);
    const tx = await pg.textContent('.nltable'); if (!tx.includes('Unread') || !tx.includes('Freelance coaches')) throw new Error('read state or club missing');
    await pg.selectOption('[data-nlf="status"]', 'unread'); await pg.waitForTimeout(400);
    if ((await pg.$$eval('.nltable tbody tr', x => x.length)) !== 1) throw new Error('status filter did not apply');
    await pg.selectOption('[data-nlf="player"]', 't1'); await pg.waitForTimeout(400);
    const f = await pg.evaluate(() => window.__STUB__.lastNlFilter); if (f.player !== 't1' || f.status !== 'unread') throw new Error('filters not sent ' + JSON.stringify(f));
  });

  // Player page: the player's sessions with Edit / Cancel right there
  await run('trainee-sessions', asCoachA({ extra: [{ collection: 'sessions', id: 'fut9', data: { id: 'fut9', date: '2030-02-05', time: '18:30', duration: 60, status: 'planned', location: 'Padel Pro', traineeIds: ['t1'], clubId: 'freelance', coachId: COACH_A.id } }] }), async pg => {
    await pg.evaluate(() => { location.hash = 'trainee-t1'; }); await pg.waitForSelector('#trSessions');
    if (!(await pg.$('#trSessions [data-act="cancelSession"][data-id="fut9"]')) || !(await pg.$('#trSessions [data-act="editSession"][data-id="fut9"]'))) throw new Error('no edit/cancel on the player page');
    await pg.click('#trSessions [data-act="editSession"][data-id="fut9"]'); await pg.waitForSelector('.sheet'); await pg.keyboard.press('Escape'); await pg.waitForTimeout(200);
    await pg.click('#trSessions [data-trsess="past"]'); await pg.waitForTimeout(200);
    if (await pg.$('#trSessions [data-id="fut9"]')) throw new Error('upcoming session listed under past');
    await pg.click('#trSessions [data-trsess="up"]'); await pg.click('#trSessions [data-act="trNewSession"]'); await pg.waitForSelector('.sheet');
    const pre = await pg.evaluate(() => [...document.querySelectorAll('.sheet input[type="checkbox"]:checked')].map(x => x.value || x.dataset.id || x.id).join(','));
    if (!/t1/.test(pre)) throw new Error('new session not pre-filled with the player: ' + pre);
    await pg.keyboard.press('Escape'); await pg.waitForTimeout(200);
    await pg.click('#langBtn'); await pg.waitForTimeout(300);
    const tm = await pg.textContent('#trSessions'); if (!tm.includes('06:30 م')) throw new Error('Arabic time format: ' + tm.slice(0, 200));
    if (tm.includes('18:30')) throw new Error('24-hour time left in Arabic');
    const order = await pg.evaluate(() => [...document.querySelectorAll('#trSessions .time')].slice(0, 1).map(el => { const w = document.createTreeWalker(el, 4); let t;
      while ((t = w.nextNode()) && t.textContent.indexOf('م') < 0); if (!t) return 'none ' + JSON.stringify(el.textContent);
      const x = t.textContent, k = x.indexOf('م'), r = document.createRange(); r.setStart(t, k); r.setEnd(t, k + 1); const xm = r.getBoundingClientRect().x;
      const xs = [...x].map((c, i) => /[0-9]/.test(c) ? (r.setStart(t, i), r.setEnd(t, i + 1), r.getBoundingClientRect().x) : null).filter(v => v != null); return xm > Math.max(...xs) && xs[0] < xs[xs.length - 1] ? 'ok' : 'bad ' + JSON.stringify(x) + ' ' + xm + ' ' + xs.join(','); })[0]);
    await (await pg.$('#trSessions .time')).screenshot({ path: '/tmp/claude-0/-home-claude/b67e96e7-5324-5d1c-8f05-8bec10272ab4/scratchpad/shots/ar-time.png' });
    if (order !== 'ok') throw new Error('Arabic time not hours-first: ' + order);
  });

  // Venue address, map location and phone
  await run('venue-contact', asOwner(), async pg => {
    await pg.click('nav.tabs a[href="#clubs"]'); await pg.waitForSelector('[data-act="editClub"]');
    await pg.click('[data-act="editClub"]'); await pg.waitForSelector('#cl-maps');
    await pg.fill('#cl-maps', 'not a link'); await pg.click('.sheet button[type="submit"]'); await pg.waitForTimeout(200);
    if (!(await pg.$('#cl-maps'))) throw new Error('bad map link accepted');
    await pg.fill('#cl-addr', 'Al Andalus, Riyadh'); await pg.fill('#cl-maps', '24.713600, 46.675300'); await pg.fill('#cl-phone', '+966 50 000 0000');
    if (!(await pg.$('.sheet .vltest a[href*="destination=24.713600"]'))) throw new Error('no map check link');
    await pg.click('.sheet button[type="submit"]'); await pg.waitForTimeout(500);
    const v = await pg.evaluate(() => window.__STUB__.docs.find(d => d.collection === 'venues' && d.data.phone));
    if (!v || v.data.address !== 'Al Andalus, Riyadh' || !v.data.mapsUrl) throw new Error('details not saved ' + JSON.stringify(v && v.data));
    const card = await text(pg); if (!card.includes('Al Andalus, Riyadh') || !card.includes('+966 50 000 0000')) throw new Error('details not on the venue card');
    if (!(await pg.$('.vl[data-href*="google.com/maps/dir"]')) || !(await pg.$('.vl[data-href="tel:+966500000000"]'))) throw new Error('no directions/call links');
    const sess = await pg.evaluate(name => { const d = window.__STUB__.docs.find(x => x.collection === 'sessions'); return d && d.id; }, v.data.name);
    await pg.evaluate(([id, name]) => { location.hash = 'session-' + id; }, [sess, v.data.name]);
    const sv = await pg.evaluate(id => window.__STUB__.docs.find(x => x.id === id).data.location, sess);
    await pg.waitForTimeout(400);
    if (sv === v.data.name && !(await pg.$('.vblock .vl[data-href*="google.com/maps"]'))) throw new Error('session page has no directions');
  });
  await run('venue-contact-player', (() => { const w = shared(); w.user = PLAYER; w.docs.find(d => d.id === 't1' && d.collection === 'trainees').data.linkedUserId = PLAYER.id;
      const v = w.docs.find(d => d.collection === 'venues'); Object.assign(v.data, { address: 'Al Andalus, Riyadh', mapsUrl: 'https://maps.app.goo.gl/abc', phone: '+966500000000' });
      w.docs.push({ collection: 'sessions', id: 'fut1', data: { id: 'fut1', date: '2030-01-15', time: '18:00', duration: 60, status: 'planned', location: v.data.name + ' · Court 2', traineeIds: ['t1'], clubId: 'freelance', coachId: COACH_A.id } });
      return w; })(), async pg => {
    await pg.waitForSelector('.pc-next'); await pg.waitForTimeout(400);
    if (!(await pg.$('.pc-next .vl[data-href="https://maps.app.goo.gl/abc"]'))) throw new Error('next session has no directions');
    if (!(await pg.$('.pc-next .vl[data-href="tel:+966500000000"]'))) throw new Error('next session has no call link');
  });

  // Notifications
  const notes = [
    { id: 3, user_id: PLAYER.id, kind: 'booked', title_en: 'New session booked', body_en: 'Coach A · Tue 18:00', title_ar: 'تم حجز حصة جديدة', body_ar: 'Coach A', link: '', created_at: new Date(Date.now() - 120000).toISOString(), read_at: null },
    { id: 2, user_id: PLAYER.id, kind: 'feedback', title_en: 'New feedback from Coach A', body_en: 'Mon', title_ar: 'تقييم جديد', body_ar: '', link: '', created_at: new Date(Date.now() - 7200000).toISOString(), read_at: null },
    { id: 1, user_id: COACH_A.id, kind: 'request', title_en: 'SECRET-OTHER', body_en: '', title_ar: 'x', body_ar: '', link: '', created_at: new Date().toISOString(), read_at: null }];
  await run('notifications-bell', { ...world({ user: PLAYER, linked: true }), notifs: notes }, async pg => {
    await pg.waitForSelector('#bellBtn:not([hidden])'); const bd = await pg.textContent('#bellBtn .bdg');
    if (bd.trim() !== '2') throw new Error('badge shows ' + bd);
    await pg.click('#bellBtn'); await pg.waitForSelector('#ntPanel .ntitem');
    const items = await pg.$$eval('#ntPanel .ntitem', x => x.length); if (items !== 2) throw new Error('items ' + items);
    if ((await text(pg)).includes('SECRET-OTHER')) throw new Error('shows someone else\'s notification');
    await pg.click('#ntPanel .ntitem[data-id="3"]'); await pg.waitForTimeout(200);
    if (await pg.$('#ntPanel')) throw new Error('panel still open after choosing an item');
    if ((await pg.textContent('#bellBtn .bdg')).trim() !== '1') throw new Error('badge did not drop to 1');
    await pg.click('#bellBtn'); await pg.click('[data-nt="all"]'); await pg.waitForTimeout(150);
    if (!(await pg.$eval('#bellBtn .bdg', e => e.hidden))) throw new Error('badge still shown after mark all');
    if (await pg.$('#ntPanel .ntitem.unread')) throw new Error('unread items remain');
    await pg.keyboard.press('Escape'); if (await pg.$('#ntPanel')) throw new Error('Escape did not close');
  });
  await run('notifications-settings', { ...world({ user: PLAYER, linked: true }), notifs: notes, notifPrefs: { reminders: true } }, async pg => {
    await pg.waitForSelector('#ntCard'); const t = await pg.textContent('#ntCard');
    if (!/reminders/i.test(t)) throw new Error('no reminder setting');
    await pg.uncheck('[data-ntpref="reminders"]'); await pg.waitForTimeout(200);
    const st = await pg.evaluate(() => window.__STUB__.notifPrefs); if (st.reminders !== false) throw new Error('reminder setting not saved');
    if (!(await pg.$('[data-nt="enable"]')) && !(await pg.$('#ntCard .notice'))) throw new Error('no device switch or guidance');
    await pg.click('#langBtn'); await pg.waitForTimeout(200);
    if ((await pg.evaluate(() => window.__STUB__.myLang)) !== 'ar') throw new Error('language not sent');
    if (!(await pg.textContent('#ntCard')).includes('الإشعارات')) throw new Error('settings not in Arabic');
  }, '#account');
  await run('notifications-coach', { ...asCoachA(), notifs: notes }, async pg => {
    await pg.waitForSelector('#bellBtn:not([hidden])'); await pg.click('#bellBtn'); await pg.waitForSelector('#ntPanel');
    const t = await pg.textContent('#ntPanel'); if (!t.includes('SECRET-OTHER')) throw new Error('coach does not see own notification');
    if (t.includes('New session booked')) throw new Error('coach sees the player\'s notifications');
  });

  // My account
  const PNG = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAIAAAAmkwkpAAAAFElEQVR4nGP8z8DAwMDAxMDAwAAAJAQDAcF0ux0AAAAASUVORK5CYII=', 'base64');
  await run('account-edit', asCoachA(), async pg => {
    await pg.click('#userChip'); await pg.waitForSelector('#acctForm'); if ((await pg.inputValue('#ac-full')) !== 'Coach A') throw new Error('name not prefilled');
    await pg.fill('#ac-disp', 'Coach Mo'); await pg.fill('#ac-phone', '+966 50 111 2222'); await pg.click('#acctForm button[type="submit"]'); await pg.waitForTimeout(400);
    const chip = await pg.innerText('#userChip'); if (!chip.includes('Coach Mo')) throw new Error('chip ' + chip);
    const p = await pg.evaluate(id => window.__STUB__.profiles.find(x => x.id === id), COACH_A.id); if (p.display_name !== 'Coach Mo' || p.phone !== '+966 50 111 2222') throw new Error('not saved ' + JSON.stringify(p));
    await pg.fill('#ac-phone', 'call me'); await pg.click('#acctForm button[type="submit"]'); await pg.waitForTimeout(200);
    if (await pg.locator('#acctForm .ferr').isHidden()) throw new Error('bad phone accepted'); });
  await run('account-photo', asCoachA(), async pg => {
    if (!(await pg.locator('#userChip span.av').count())) throw new Error('no default initials picture');
    await pg.setInputFiles('#av-file', { name: 'me.png', mimeType: 'image/png', buffer: PNG }); await pg.waitForTimeout(700);
    const st = await pg.evaluate(id => ({ up: window.__STUB__.uploads, p: window.__STUB__.profiles.find(x => x.id === id) }), COACH_A.id);
    if (!st.up || st.up[0].type !== 'image/jpeg' || !st.up[0].path.startsWith(COACH_A.id + '/')) throw new Error('upload ' + JSON.stringify(st.up));
    if (st.p.avatar_path !== st.up[0].path) throw new Error('avatar not saved'); if (!(await pg.locator('#userChip img.av').count())) throw new Error('chip has no photo');
    await pg.click('[data-act="rmPhoto"]'); await pg.waitForTimeout(400);
    if (await pg.locator('#userChip img.av').count()) throw new Error('photo not removed'); if (!(await pg.evaluate(() => (window.__STUB__.removed || []).length))) throw new Error('file not deleted'); }, '#account');
  await run('account-email', asCoachA(), async pg => {
    await pg.fill('#ac-email', 'coach.a@example.com'); await pg.click('#emailForm button[type="submit"]'); await pg.waitForTimeout(200);
    if (await pg.locator('#emailForm .ferr').isHidden()) throw new Error('same email accepted');
    await pg.fill('#ac-email', 'new.coach@example.com'); await pg.click('#emailForm button[type="submit"]'); await pg.waitForTimeout(300);
    const u = await pg.evaluate(() => window.__STUB__.authUpdates); if (!u || u[0].email !== 'new.coach@example.com') throw new Error('email ' + JSON.stringify(u));
    if (await pg.locator('#emailForm .ok').isHidden()) throw new Error('no confirmation message'); }, '#account');
  await run('account-google', (() => { const w = asCoachA(); w.user = { ...COACH_A, app_metadata: { provider: 'google', providers: ['google'] } }; return w; })(), async pg => {
    const tx = await text(pg); if (!tx.includes('You sign in with Google') || !tx.includes('Set a password')) throw new Error('no Google guidance');
    await pg.fill('#ac-pw', 'longenough1'); await pg.click('#pwForm button[type="submit"]'); await pg.waitForTimeout(300);
    const u = await pg.evaluate(() => window.__STUB__.authUpdates); if (!u || u[0].password !== 'longenough1') throw new Error('password not set'); }, '#account');
  await run('account-player', { ...shared(), user: PLAYER, docs: (() => { const w = shared(); w.docs.find(d => d.id === 't1' && d.collection === 'trainees').data.linkedUserId = PLAYER.id; return w.docs; })() }, async pg => {
    await pg.click('#userChip'); await pg.waitForSelector('#acctForm'); await pg.fill('#ac-phone', '0501234567'); await pg.click('#acctForm button[type="submit"]'); await pg.waitForTimeout(300);
    const ph = await pg.evaluate(() => window.__STUB__.docs.find(d => d.id === 't1' && d.collection === 'trainees').data.phone); if (ph !== '0501234567') throw new Error('player phone not synced ' + ph);
    await pg.click('a.back'); await pg.waitForSelector('.ptabs'); });
  { // a newer version goes live while the page is open: the bar appears, and the next return to the app refreshes
    const pg = await b.newPage({ viewport: { width: 1280, height: 900 } }); let ok2 = true;
    await pg.addInitScript(st => { window.__STUB__ = st; }, asCoachA());
    await pg.route('**/', async r => { const res = await r.fetch(); const body = (await res.text()).replace('__BUILD__', '1111111'); r.fulfill({ response: res, body }); });
    await pg.route('**/version.txt*', r => r.fulfill({ status: 200, contentType: 'text/plain', body: '2222222' }));
    await pg.goto('http://localhost:8765/'); await pg.waitForTimeout(600);
    await pg.evaluate(() => document.dispatchEvent(new Event('visibilitychange'))); await pg.waitForTimeout(600);
    try { await pg.waitForSelector('#updbar', { timeout: 20000 }); console.log('PASS update-notice'); } catch (e) { console.log('FAIL update-notice', e.message); ok = false; }
    await pg.close(); }
  await run('player-unlinked', { user: { id: '33333333-3333-4333-8333-333333333333', email: 'n@example.com' }, docs: [] }, async pg => {
    await pg.waitForSelector('#my-id'); const v = await pg.inputValue('#my-id'); if (!/^3333/.test(v)) throw new Error('id ' + v); });
  await b.close(); srv.close(); if (errs.length) { console.log('ERRORS:\n' + errs.join('\n')); ok = false; } process.exit(ok ? 0 : 1);
})();
