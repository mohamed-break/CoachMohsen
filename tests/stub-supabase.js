// In-memory stand-in for supabase-js, used only by tests/smoke.js.
// It mimics the multi-club database: documents are filtered by the same read rules as the
// real row-level security, and the club actions (RPCs) behave like supabase/migrations/0005.
(function(){
  const T = window.__STUB__ || {user:null, docs:[], profiles:[]};
  const rows = T.docs = T.docs || [];
  T.orgs = T.orgs || [{id:'freelance', name:'Freelance coaches', is_freelance:true}];
  T.profiles = T.profiles || []; T.members = T.members || []; T.players = T.players || []; T.enroll = T.enroll || []; T.users = T.users || [];
  const uid = () => T.user ? T.user.id : null;
  const sys = () => T.role === 'sysadmin';
  const isMember = o => T.members.some(m => m.org_id === o && m.user_id === uid());
  const isAdmin = o => sys() || T.members.some(m => m.org_id === o && m.user_id === uid() && m.role === 'club_admin');
  const isCoach = o => T.members.some(m => m.org_id === o && m.user_id === uid() && m.role === 'coach');
  const canSee = p => sys() || T.enroll.some(e => e.player_id === p && e.coach_id === uid()) ||
    T.players.some(c => c.player_id === p && T.members.some(m => m.org_id === c.org_id && m.user_id === uid() && m.role === 'club_admin'));
  const own = r => ({club: r.data?.clubId || null, coach: r.data?.coachId || null, owner: r.data?.playerUid || null});
  function canRead(r){ const c = r.collection, o = own(r);
    if (sys()) return true;
    if (c === 'trainees') return canSee(r.id);
    if (c === 'sessions' || c === 'blocks') return o.coach === uid() || isAdmin(o.club);
    if (['coachplayer','coachnotes','sessremarks'].includes(c)) return o.coach === uid();
    if (c === 'skills' || c === 'venues') return isMember(o.club);
    if (c === 'requests') return o.owner === uid() || o.coach === uid() || isAdmin(o.club);
    return false; }
  const name = u => { const p = T.users.find(x => x.id === u); return p ? (p.name || String(p.email).split('@')[0]) : ''; };
  const deep = (a,b)=> (a&&b&&typeof a==='object'&&typeof b==='object'&&!Array.isArray(a)&&!Array.isArray(b))
    ? Object.keys({...a,...b}).reduce((o,k)=>(o[k]= k in b ? (k in a ? deep(a[k],b[k]) : b[k]) : a[k], o),{}) : b;
  const hex = () => Math.random().toString(16).slice(2, 14);
  function q(table){
    let filters=[], op='select', payload=null, single=false, rng=null;
    const src = table==='docs' ? rows.filter(canRead)
      : table==='app_public_settings' ? (T.settings||(T.settings=[{key:'theme',value:'protour'}]))
      : table==='club_players' ? T.players.filter(c => isAdmin(c.org_id) || T.enroll.some(e => e.org_id===c.org_id && e.player_id===c.player_id && e.coach_id===uid()))
      : table==='enrollments' ? T.enroll.filter(e => e.coach_id===uid() || isAdmin(e.org_id))
      : T.profiles;
    const api = {
      select(){return api}, order(){return api},
      eq(c,v){filters.push(r=>r[c]===v);return api},
      in(c,a){filters.push(r=>a.includes(r[c]));return api},
      range(a,b){rng=[a,b];return api},
      maybeSingle(){single=true;return api},
      upsert(row){op='upsert';payload=row;return api},
      delete(){op='delete';return api},
      then(res){
        if(op==='upsert'){const cc=courtClash(payload);if(cc)return res({error:{message:cc}});const i=rows.findIndex(r=>r.collection===payload.collection&&r.id===payload.id);if(i>=0)rows[i]=payload;else rows.push(payload);return res({error:null})}
        if(op==='delete'){for(let i=rows.length-1;i>=0;i--)if(canRead(rows[i])&&filters.every(f=>f(rows[i])))rows.splice(i,1);return res({error:null})}
        let out=src.filter(r=>filters.every(f=>f(r)));
        if(rng)out=out.slice(rng[0],rng[1]+1);
        return res({data: single?(out[0]||null):out, error:null});
      }
    };
    return api;
  }
  const ok = data => Promise.resolve({data, error:null});
  const fail = message => Promise.resolve({data:null, error:{message}});
  const doc = (c,id) => rows.find(r => r.collection===c && r.id===id);
  // like the database trigger: a court holds one active session at a time
  const mins = t => { const m = /^(\d{1,2}):(\d{2})/.exec(t || ''); return m ? (+m[1]) * 60 + (+m[2]) : null; };
  function courtClash(row){ const d = row.data || {}; if (row.collection !== 'sessions' || !d.courtId || d.status === 'cancelled') return null;
    const st = mins(d.time); if (st == null) return 'COURT_NEEDS_TIME: a session on a court needs a start time'; const en = st + (+d.duration || 60);
    const c = rows.find(r => r.collection === 'sessions' && r.id !== row.id && r.data.courtId === d.courtId && r.data.date === d.date && r.data.status !== 'cancelled' && mins(r.data.time) != null && mins(r.data.time) < en && mins(r.data.time) + (+r.data.duration || 60) > st);
    return c ? `COURT_BUSY: ${d.courtName || d.courtId} is booked from ${c.data.time} for ${+c.data.duration || 60} min` : null; }
  const RPC = {
    is_staff: () => ok(sys() || T.members.some(m => m.user_id===uid())),
    my_role: () => ok(sys() ? 'sysadmin' : T.members.some(m => m.user_id===uid()) ? 'coach' : 'player'),
    my_context: () => ok({uid:uid(), sysadmin:sys(),
      memberships: T.members.filter(m => m.user_id===uid()).map(m => { const o = T.orgs.find(x => x.id===m.org_id)||{}; return {org:m.org_id, name:o.name, freelance:!!o.is_freelance, role:m.role}; }),
      orgs: sys() ? T.orgs.map(o => ({org:o.id, name:o.name, freelance:!!o.is_freelance})) : []}),
    club_people: a => ok(T.members.filter(m => m.org_id===a.p_org && (isAdmin(a.p_org) || m.role==='coach'))
      .map(m => ({user_id:m.user_id, email:(T.users.find(u => u.id===m.user_id)||{}).email||'', name:name(m.user_id), role:m.role, avatar_path:(T.profiles.find(p => p.id===m.user_id)||{}).avatar_path||null}))),
    save_org: a => { if(!sys()) return fail('only a sys admin can manage clubs'); const id = a.p_id || ('c'+hex().slice(0,10));
      const o = T.orgs.find(x => x.id===id); if(o) o.name=a.p_name; else { T.orgs.push({id, name:a.p_name, is_freelance:!!a.p_freelance});
        rows.filter(r => r.collection==='skills' && r.data.clubId==='freelance').forEach(r => rows.push({collection:'skills', id:id+'-'+r.id, data:{...r.data, id:id+'-'+r.id, clubId:id}})); }
      return ok(id); },
    delete_org: a => { if(!sys()) return fail('no'); T.orgs = T.orgs.filter(o => o.id!==a.p_org); return ok(null); },
    add_member: a => { if(!(sys() || (a.p_role==='coach' && isAdmin(a.p_org)))) return fail('not allowed');
      const u = T.users.find(x => String(x.email).toLowerCase()===String(a.p_email).trim().toLowerCase()); if(!u) return fail('No account uses this email yet.');
      if(!T.members.some(m => m.org_id===a.p_org && m.user_id===u.id && m.role===a.p_role)) T.members.push({org_id:a.p_org, user_id:u.id, role:a.p_role}); return ok(u.id); },
    remove_member: a => { T.members = T.members.filter(m => !(m.org_id===a.p_org && m.user_id===a.p_user && m.role===a.p_role)); if(a.p_role==='coach') T.enroll = T.enroll.filter(e => !(e.org_id===a.p_org && e.coach_id===a.p_user)); return ok(null); },
    create_player: a => { if(!(isAdmin(a.p_org) || isCoach(a.p_org))) return fail('not a coach of this club'); const id = 'p'+hex();
      rows.push({collection:'trainees', id, data:{...a.p_data, id, linkedUserId:a.p_data.linkedUserId||''}}); T.players.push({org_id:a.p_org, player_id:id});
      if(isCoach(a.p_org)) T.enroll.push({org_id:a.p_org, player_id:id, coach_id:uid()}); return ok(id); },
    add_player_by_email: a => { const u = T.users.find(x => String(x.email).toLowerCase()===String(a.p_email).trim().toLowerCase()); if(!u) return fail('No account uses this email yet.');
      let tr = rows.find(r => r.collection==='trainees' && r.data.linkedUserId===u.id); if(!tr){ const id='p'+hex(); tr={collection:'trainees', id, data:{id, name:name(u.id), linkedUserId:u.id}}; rows.push(tr); }
      if(!T.players.some(c => c.org_id===a.p_org && c.player_id===tr.id)) T.players.push({org_id:a.p_org, player_id:tr.id});
      if(isCoach(a.p_org) && !T.enroll.some(e => e.org_id===a.p_org && e.player_id===tr.id && e.coach_id===uid())) T.enroll.push({org_id:a.p_org, player_id:tr.id, coach_id:uid()});
      return ok(tr.id); },
    set_player_coaches: a => { if(!isAdmin(a.p_org)) return fail('only a club admin can assign coaches');
      T.enroll = T.enroll.filter(e => !(e.org_id===a.p_org && e.player_id===a.p_player)).concat((a.p_coaches||[]).map(c => ({org_id:a.p_org, player_id:a.p_player, coach_id:c}))); return ok(null); },
    remove_player: a => { if(isAdmin(a.p_org)){ T.enroll = T.enroll.filter(e => !(e.org_id===a.p_org && e.player_id===a.p_player)); T.players = T.players.filter(c => !(c.org_id===a.p_org && c.player_id===a.p_player)); }
      else T.enroll = T.enroll.filter(e => !(e.org_id===a.p_org && e.player_id===a.p_player && e.coach_id===uid())); return ok(null); },
    hand_over: a => { if(!isAdmin(a.p_org)) return fail('only a club admin can hand over'); let n=0;
      rows.forEach(r => { if(['sessions','blocks','coachnotes','sessremarks','requests'].includes(r.collection) && r.data.clubId===a.p_org && r.data.coachId===a.p_from){ r.data.coachId=a.p_to; n++; } });
      rows.forEach(r => { if(r.collection==='coachplayer' && r.data.coachId===a.p_from){ r.data.coachId=a.p_to; r.id=r.data.playerId+'@'+a.p_to; r.data.id=r.id; } });
      T.enroll.forEach(e => { if(e.org_id===a.p_org && e.coach_id===a.p_from) e.coach_id=a.p_to; }); return ok(n); },
    request_cancel: a => { const tr = rows.find(r => r.collection==='trainees' && r.data.linkedUserId===uid()); const s = doc('sessions', a.p_session);
      if(!tr || !s) return fail('this is not one of your sessions'); const id = a.p_session+':'+uid();
      const d = {sessionId:a.p_session, playerUid:uid(), playerId:tr.id, coachId:s.data.coachId, clubId:s.data.clubId, status:'pending', reason:a.p_reason||'', date:s.data.date, time:s.data.time, seen:true};
      const ex = doc('requests', id); if(ex) ex.data=d; else rows.push({collection:'requests', id, data:d}); return ok(null); },
    ack_request: a => { const r = doc('requests', a.p_id); if(r && r.data.playerUid===uid()) r.data.seen=true; return ok(null); },
    player_360: () => { const tr = rows.find(r => r.collection==='trainees' && r.data.linkedUserId===uid()); if(!tr) return ok(null); const pid = tr.id;
      const cps = rows.filter(r => r.collection==='coachplayer' && r.data.playerId===pid);
      const show = c => !!(cps.find(r => r.data.coachId===c)||{data:{}}).data.showFeedback;
      const sk = id => (doc('skills', id)||{data:{}}).data;
      const history = rows.filter(r => r.collection==='sessions' && (r.data.traineeIds||[]).includes(pid)).map(r => { const s=r.data, sh=show(s.coachId), fb=(s.feedback||{})[pid]||{};
        return {id:r.id, date:s.date, time:s.time||'', duration:s.duration, location:s.location||'', status:(s.excused||[]).includes(pid)?'cancelled':(s.status||'planned'), focus:s.focus||'',
          size:Math.max(1,(s.traineeIds||[]).length), coachName:name(s.coachId), clubName:(T.orgs.find(o => o.id===s.clubId)||{}).name||'', showFeedback:sh, cancelReason:s.status==='cancelled'?(s.cancelReason||''):'',
          activities:(s.activities||[]).map(x => ({title:x.title||'', minutes:x.minutes, skillId:x.skillId||'', name_en:sk(x.skillId).name_en||'', name_ar:sk(x.skillId).name_ar||''})),
          items:Object.entries(fb.skills||{}).filter(([k,v]) => v.rating || (sh && v.comment)).map(([k,v]) => ({skillId:k, name_en:sk(k).name_en||'', name_ar:sk(k).name_ar||'', rating:v.rating||0, comment:sh?(v.comment||''):''})),
          general:sh?(fb.general||''):'', overall:sh?(fb.overall||0):0}; }).sort((a,b) => (b.date+b.time).localeCompare(a.date+a.time));
      return ok({traineeName:tr.data.name, level:tr.data.level, playerId:pid, fixedSlots:cps.flatMap(r => (r.data.fixedSlots||[]).map(x => ({...x, coachName:name(r.data.coachId)}))), history}); },
    update_my_profile: a => { if(a.p_phone && !/^\+?[0-9 ()-]{6,20}$/.test(a.p_phone)) return fail('phone number');
      const p = T.profiles.find(x => x.id===uid()); if(p){ p.full_name=a.p_full_name||null; p.display_name=a.p_display_name||null; p.phone=a.p_phone||null; }
      rows.forEach(r => { if(r.collection==='trainees' && r.data.linkedUserId===uid()){ if(a.p_display_name||a.p_full_name) r.data.name=a.p_display_name||a.p_full_name; if(a.p_phone) r.data.phone=a.p_phone; } }); return ok(null); },
    set_my_avatar: a => { if(a.p_path && a.p_path.split('/')[0]!==uid()) return fail('not your photo'); const p = T.profiles.find(x => x.id===uid()); if(p) p.avatar_path=a.p_path||null; return ok(null); },
    admin_create_player: a => { if(!isAdmin(a.p_org)) return fail('only a club admin or sys admin can add players');
      const em=String(a.p_email||'').trim().toLowerCase(); let u=null, fresh=false;
      if(em){ u=T.users.find(x=>String(x.email).toLowerCase()===em); if(!u){ u={id:'u'+hex(), email:em, name:a.p_name, role:'player', created_at:new Date().toISOString()}; T.users.push(u); T.profiles.push({id:u.id,email:em,full_name:a.p_name,phone:a.p_phone||null}); fresh=true; } }
      let tr=u&&rows.find(r=>r.collection==='trainees'&&r.data.linkedUserId===u.id);
      if(!tr){ const id='p'+hex(); tr={collection:'trainees', id, data:{id, name:a.p_name, phone:a.p_phone||'', level:a.p_level, linkedUserId:u?u.id:''}}; rows.push(tr); }
      if(!T.players.some(c=>c.org_id===a.p_org&&c.player_id===tr.id)) T.players.push({org_id:a.p_org, player_id:tr.id});
      (a.p_coaches||[]).forEach(c=>{ if(!T.enroll.some(e=>e.org_id===a.p_org&&e.player_id===tr.id&&e.coach_id===c)) T.enroll.push({org_id:a.p_org, player_id:tr.id, coach_id:c}); });
      return ok({playerId:tr.id, userId:u?u.id:null, newAccount:fresh}); },
    set_theme: a => { if(!sys()) return fail('only a sys admin can change the theme'); const st=(T.settings||(T.settings=[{key:'theme',value:'protour'}])).find(x=>x.key==='theme'); st.value=a.p_theme; return ok(null); },
    find_user_by_email: a => { const u=T.users.find(x=>(x.email||'').toLowerCase()===String(a.p_email).trim().toLowerCase()); return ok(u?u.id:null); },
    delete_user: a => { T.users=T.users.filter(x=>x.id!==a.p_user); rows.forEach(r=>{if(r.collection==='trainees'&&r.data.linkedUserId===a.p_user)r.data.linkedUserId=''}); return ok(1); },
    list_users: () => ok(T.users),
    set_user_role: a => { const u=T.users.find(x=>x.id===a.p_user); if(u) u.role=a.p_role; return ok(null); },
    doc_merge: a => { const r=doc(a.p_collection, a.p_id); if(!r || !canRead(r)) return fail('missing'); const nd=deep(r.data, a.p_patch); const cc=courtClash({collection:r.collection,id:r.id,data:nd}); if(cc) return fail(cc); r.data=nd; return ok(null); },
    court_busy: a => ok(T.hideBusy ? [] : rows.filter(r => r.collection==='sessions' && r.data.date===a.p_date && r.data.courtId && r.data.status!=='cancelled').map(r => ({session_id:r.id, court_id:r.data.courtId, start_time:r.data.time, duration:+r.data.duration||60, mine:r.data.coachId===uid()}))),
  };
  const realFetch = window.fetch;
  window.fetch = (u, o) => String(u).includes('/auth/v1/settings')
    ? Promise.resolve(new Response(JSON.stringify({ external: T.providers || {} }), { headers: { 'content-type': 'application/json' } }))
    : realFetch(u, o);
  window.supabase = {createClient(){return {
    from:q,
    storage:{from(bucket){return{
      upload:async(path,blob)=>{ if(path.split('/')[0]!==uid()) return {error:{message:'denied'}}; (T.uploads=T.uploads||[]).push({path,size:blob.size,type:blob.type}); return {data:{path},error:null}; },
      remove:async(paths)=>{ (T.removed=T.removed||[]).push(...paths); return {error:null}; },
      getPublicUrl:path=>({data:{publicUrl:'data:image/svg+xml;utf8,'+encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" width="8" height="8"><rect width="8" height="8" fill="#3BB07A"/></svg>')+'#'+path}})}}},
    rpc(n,a){ return RPC[n] ? RPC[n](a||{}) : fail('unknown rpc '+n); },
    auth:{getSession:async()=>({data:{session:T.user?{user:T.user}:null}}),onAuthStateChange(cb){ /* like supabase-js: report the current session right after subscribing */ queueMicrotask(()=>cb('INITIAL_SESSION', T.user?{user:T.user}:null)); return{data:{subscription:{unsubscribe(){}}}}},
      signOut:async()=>({}),signInWithOAuth:async()=>({error:null}),signInWithPassword:async()=>({error:null}),signUp:async()=>({data:{session:null},error:null}),resetPasswordForEmail:async()=>({error:null}),updateUser:async(v)=>{(T.authUpdates=T.authUpdates||[]).push(v);return{data:{user:{...T.user,new_email:v.email||T.user.new_email}},error:null}}},
    channel(){const c={on(){return c},subscribe(){return c}};return c}, removeChannel(){}
  }}};
})();
