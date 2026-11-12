// Smoke test: node tests/smoke.js  (needs playwright; serves public/ locally with a stubbed backend)
const { chromium } = require('playwright'); const http = require('http'); const fs = require('fs'); const path = require('path');
const root = path.join(__dirname, '..', 'public');
const srv = http.createServer((q, s) => { let p = q.url.split('?')[0]; if (p === '/') p = '/index.html';
  if (p.startsWith('/vendor/')) { s.setHeader('content-type','text/javascript'); return s.end(fs.readFileSync(path.join(__dirname,'stub-supabase.js'))); }
  if (p === '/config.js') { s.setHeader('content-type','text/javascript'); return s.end('window.PADEL_CONFIG={supabaseUrl:"https://stub.supabase.co",supabaseAnonKey:"stub"}'); }
  const f = path.join(root, p); if (!fs.existsSync(f)) { s.statusCode = 404; return s.end(); }
  s.setHeader('content-type', p.endsWith('.html') ? 'text/html' : p.endsWith('.svg') ? 'image/svg+xml' : 'text/plain'); s.end(fs.readFileSync(f)); });
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
    await pg.click('nav.tabs a[href="#trainees"]'); await pg.waitForTimeout(300); const c = await pg.locator('.grid2 a.card').count(); if (c !== 1) throw new Error('trainees ' + c);
    await pg.locator('.grid2 a.card').first().click(); await pg.waitForTimeout(300); await pg.waitForSelector('[data-trtab="log"]');
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
    const t = await tabs(pg); if (t.join() !== '#week,#trainees,#skills,#clubs,#team,#users,#appearance') throw new Error('tabs ' + t);
    await pg.click('nav.tabs a[href="#users"]'); await pg.waitForSelector('.utable');
    const opts = await pg.$$eval(`select[data-setrole="${COACH_B.id}"] option`, o => o.map(x => x.value)); if (opts.join() !== 'player,sysadmin') throw new Error('roles ' + opts);
    await pg.selectOption(`select[data-setrole="${COACH_B.id}"]`, 'sysadmin'); await pg.waitForTimeout(400);
    if (await pg.inputValue(`select[data-setrole="${COACH_B.id}"]`) !== 'sysadmin') throw new Error('role not saved'); });
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
  await run('skill-name-suggest', asCoachA(), async pg => {
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
  await run('player-unlinked', { user: { id: '33333333-3333-4333-8333-333333333333', email: 'n@example.com' }, docs: [] }, async pg => {
    await pg.waitForSelector('#my-id'); const v = await pg.inputValue('#my-id'); if (!/^3333/.test(v)) throw new Error('id ' + v); });
  await b.close(); srv.close(); if (errs.length) { console.log('ERRORS:\n' + errs.join('\n')); ok = false; } process.exit(ok ? 0 : 1);
})();
