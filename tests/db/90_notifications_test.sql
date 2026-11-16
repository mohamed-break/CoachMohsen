-- Notifications: who gets told what.
\set ON_ERROR_STOP 1
create or replace function pg_temp.ok(c boolean, msg text) returns void language plpgsql as $$
begin if c is not true then raise exception 'FAILED: %', msg; end if; raise notice 'ok: %', msg; end $$;
create or replace function pg_temp.got(u text, k text) returns int language sql as $$
  select count(*)::int from public.notifications where user_id = u::uuid and kind = k $$;
create or replace function pg_temp.as_user(u text) returns void language sql as $$ select set_config('request.jwt.claim.sub', u, false) $$;

-- people: sys admin, club admin, coach, player
insert into auth.users (id, email) values
  ('00000000-0000-4000-8000-00000000a001', 'n.sys@example.com'),
  ('00000000-0000-4000-8000-00000000a002', 'n.admin@example.com'),
  ('00000000-0000-4000-8000-00000000a003', 'n.coach@example.com'),
  ('00000000-0000-4000-8000-00000000a004', 'n.player@example.com');
insert into public.user_roles (user_id, role) values ('00000000-0000-4000-8000-00000000a001', 'sysadmin') on conflict (user_id) do update set role = 'sysadmin';
insert into public.orgs (id, name) values ('nclub', 'Notif Club');
insert into public.org_members (org_id, user_id, role) values ('nclub', '00000000-0000-4000-8000-00000000a002', 'club_admin');

-- a new account → sys admin is told
insert into auth.users (id, email) values ('00000000-0000-4000-8000-00000000a005', 'n.new@example.com');
select pg_temp.ok(pg_temp.got('00000000-0000-4000-8000-00000000a001', 'new_account') >= 1, 'sys admin told about a new account');

-- a club admin adds a coach → other club admins are told, not the one acting
insert into public.org_members (org_id, user_id, role) values ('nclub', '00000000-0000-4000-8000-00000000a005', 'club_admin');
select pg_temp.as_user('00000000-0000-4000-8000-00000000a005');
insert into public.org_members (org_id, user_id, role) values ('nclub', '00000000-0000-4000-8000-00000000a003', 'coach');
select pg_temp.ok(pg_temp.got('00000000-0000-4000-8000-00000000a002', 'coach_added') = 1, 'club admin told about a new coach');
select pg_temp.ok(pg_temp.got('00000000-0000-4000-8000-00000000a005', 'coach_added') = 0, 'the admin who added the coach is not told');

-- a player joins through the coach's invite link → coach and club admins are told
insert into public.docs (collection, id, data) values ('trainees', 'np1', '{"id":"np1","name":"Nora","linkedUserId":"00000000-0000-4000-8000-00000000a004"}');
select pg_temp.as_user('00000000-0000-4000-8000-00000000a004');
insert into public.club_players (org_id, player_id) values ('nclub', 'np1');
insert into public.enrollments (org_id, player_id, coach_id) values ('nclub', 'np1', '00000000-0000-4000-8000-00000000a003');
select pg_temp.ok(pg_temp.got('00000000-0000-4000-8000-00000000a003', 'player_joined') = 1, 'coach told a player joined via the link');
select pg_temp.ok(pg_temp.got('00000000-0000-4000-8000-00000000a002', 'club_player_joined') = 1, 'club admin told a player joined');

-- a club admin assigns a player → the coach is told
insert into public.docs (collection, id, data) values ('trainees', 'np2', '{"id":"np2","name":"Omar"}');
select pg_temp.as_user('00000000-0000-4000-8000-00000000a002');
insert into public.club_players (org_id, player_id) values ('nclub', 'np2');
insert into public.enrollments (org_id, player_id, coach_id) values ('nclub', 'np2', '00000000-0000-4000-8000-00000000a003');
select pg_temp.ok(pg_temp.got('00000000-0000-4000-8000-00000000a003', 'player_assigned') = 1, 'coach told about an assigned player');

-- the coach books a session → the player is told (in both languages, with the venue)
insert into public.docs (collection, id, data) values ('venues', 'nv1', '{"id":"nv1","name":"Andalus","clubId":"nclub","courts":[{"id":"c2","name":"Court 2","name_ar":"ملعب 2"}]}');
select pg_temp.as_user('00000000-0000-4000-8000-00000000a003');
insert into public.docs (collection, id, data) values ('sessions', 'ns1', jsonb_build_object('id','ns1','date',to_char(now() at time zone 'Asia/Riyadh' + interval '5 days','YYYY-MM-DD'),
  'time','18:00','status','planned','location','Andalus','courtId','c2','traineeIds',jsonb_build_array('np1'),'clubId','nclub','coachId','00000000-0000-4000-8000-00000000a003'));
select pg_temp.ok(pg_temp.got('00000000-0000-4000-8000-00000000a004', 'booked') = 1, 'player told about the booking');
select pg_temp.ok((select body_en like '%Andalus · Court 2%' and body_ar like '%ملعب 2%' from public.notifications where kind = 'booked' and user_id = '00000000-0000-4000-8000-00000000a004'), 'message names the venue and court');
select pg_temp.ok(pg_temp.got('00000000-0000-4000-8000-00000000a003', 'booked_for_coach') = 0, 'coach not told about their own booking');

-- moved to another time → changed; a feedback edit while hidden → nothing
update public.docs set data = data || '{"time":"19:30"}' where collection = 'sessions' and id = 'ns1';
select pg_temp.ok(pg_temp.got('00000000-0000-4000-8000-00000000a004', 'changed') = 1, 'player told about the change');
update public.docs set data = data || '{"focus":"Volleys"}' where collection = 'sessions' and id = 'ns1';
select pg_temp.ok(pg_temp.got('00000000-0000-4000-8000-00000000a004', 'changed') = 1, 'other edits do not notify');
update public.docs set data = data || '{"feedback":{"np1":{"comment":"Good"}}}' where collection = 'sessions' and id = 'ns1';
select pg_temp.ok(pg_temp.got('00000000-0000-4000-8000-00000000a004', 'feedback') = 0, 'no feedback notice while the coach hides feedback');
insert into public.docs (collection, id, data) values ('coachplayer', 'cpn1', '{"playerId":"np1","showFeedback":true,"coachId":"00000000-0000-4000-8000-00000000a003"}');
update public.docs set data = data || '{"feedback":{"np1":{"comment":"Very good"}}}' where collection = 'sessions' and id = 'ns1';
update public.docs set data = data || '{"feedback":{"np1":{"comment":"Very good!"}}}' where collection = 'sessions' and id = 'ns1';
select pg_temp.ok(pg_temp.got('00000000-0000-4000-8000-00000000a004', 'feedback') = 1, 'feedback notice once, when shown');

-- cancellation request flow
select pg_temp.as_user('00000000-0000-4000-8000-00000000a004');
set role authenticated;
select public.request_cancel('ns1', 'Travel');
select public.request_cancel('ns1', 'Travel, sorry');
select public.withdraw_request('ns1');
reset role;
select pg_temp.ok(pg_temp.got('00000000-0000-4000-8000-00000000a003', 'request') = 2, 'coach told about the request and the resend');
select pg_temp.ok(pg_temp.got('00000000-0000-4000-8000-00000000a003', 'request_withdrawn') = 1, 'coach told about the withdrawal');
set role authenticated;
select public.request_cancel('ns1', 'Ill');
reset role;
select pg_temp.as_user('00000000-0000-4000-8000-00000000a003');
update public.docs set data = data || '{"status":"declined","seen":false}' where collection = 'requests' and id = 'ns1:00000000-0000-4000-8000-00000000a004';
select pg_temp.ok(pg_temp.got('00000000-0000-4000-8000-00000000a004', 'request_declined') = 1, 'player told the request was declined');

-- the coach cancels → player told
update public.docs set data = data || '{"status":"cancelled"}' where collection = 'sessions' and id = 'ns1';
select pg_temp.ok(pg_temp.got('00000000-0000-4000-8000-00000000a004', 'cancelled') = 1, 'player told about the cancellation');

-- a club admin books for the coach → coach told
select pg_temp.as_user('00000000-0000-4000-8000-00000000a002');
insert into public.docs (collection, id, data) values ('sessions', 'ns2', jsonb_build_object('id','ns2','date',to_char(now() at time zone 'Asia/Riyadh' + interval '1 hour','YYYY-MM-DD'),
  'time',to_char(now() at time zone 'Asia/Riyadh' + interval '90 minutes','HH24:MI'),'status','planned','traineeIds',jsonb_build_array('np1'),'clubId','nclub','coachId','00000000-0000-4000-8000-00000000a003'));
select pg_temp.ok(pg_temp.got('00000000-0000-4000-8000-00000000a003', 'booked_for_coach') = 1, 'coach told when an admin books for them');

-- reminders: the 2-hour one, once; switched off → none
select public.send_reminders();
select public.send_reminders();
select pg_temp.ok(pg_temp.got('00000000-0000-4000-8000-00000000a004', 'reminder') = 1, '2-hour reminder sent once');
update public.profiles set notif_prefs = '{"reminders":false}' where id = '00000000-0000-4000-8000-00000000a004';
delete from private.notif_sent where key like 'r2:%';
select public.send_reminders();
select pg_temp.ok(pg_temp.got('00000000-0000-4000-8000-00000000a004', 'reminder') = 1, 'no reminders once switched off');

-- each person sees only their own; mark read; settings
select pg_temp.as_user('00000000-0000-4000-8000-00000000a004');
set role authenticated;
select pg_temp.ok((select count(*) from public.notifications) > 0 and (select bool_and(user_id = auth.uid()) from public.notifications), 'a player reads only their own notifications');
select pg_temp.ok(public.mark_notifications_read() > 0, 'mark all as read');
select pg_temp.ok((select count(*) from public.notifications where read_at is null) = 0, 'nothing left unread');
select pg_temp.ok((public.set_notif_prefs('{"feedback":false,"evil":"x"}') ->> 'feedback') = 'false', 'settings saved');
select pg_temp.ok(public.my_notif_prefs() ? 'reminders' and not public.my_notif_prefs() ? 'evil', 'settings read back, unknown keys ignored');
select public.save_push_subscription('https://push.example.com/abc', 'key', 'auth');
select pg_temp.ok((select count(*) from public.push_subscriptions) = 1, 'device saved');
select public.set_my_lang('ar');
do $$ begin
  begin insert into public.notifications (user_id, kind, title_en, title_ar) values (auth.uid(), 'x', 'x', 'x'); raise exception 'FAILED: insert allowed';
  exception when insufficient_privilege then raise notice 'ok: players cannot write notifications'; end;
  begin perform public.notify(auth.uid(), 'x', '', 'x', '', 'x', ''); raise exception 'FAILED: notify allowed';
  exception when insufficient_privilege then raise notice 'ok: players cannot call notify'; end;
  begin perform public.push_gone('wrong', array['https://push.example.com/abc']); raise exception 'FAILED: push_gone allowed';
  exception when insufficient_privilege then raise notice 'ok: push_gone needs the secret'; end;
end $$;
reset role;
select pg_temp.ok((select lang from public.profiles where id = '00000000-0000-4000-8000-00000000a004') = 'ar', 'language saved');
select pg_temp.ok(public.push_gone((select secret from private.push_config), array['https://push.example.com/abc']) = 1, 'dead devices removed with the secret');

-- push hand-off: with a stand-in for pg_net, a new message for someone with a device is posted to /api/push
create schema if not exists net;
create table net.calls (url text, body jsonb, headers jsonb);
create or replace function net.http_post(url text, body jsonb, params jsonb default '{}', headers jsonb default '{}', timeout_milliseconds int default 1000)
returns bigint language sql as $$ insert into net.calls values (url, body, headers); select 1::bigint $$;
update public.notifications set pushed_at = now();
update private.push_config set fn_url = 'https://site.example/api/push', api_url = 'https://db.example', api_key = 'pk', vapid_public = 'pub', vapid_private = 'priv';
insert into public.push_subscriptions (endpoint, user_id, p256dh, auth) values ('https://push.example.com/dev1', '00000000-0000-4000-8000-00000000a004', 'k', 'a');
select pg_temp.as_user('00000000-0000-4000-8000-00000000a003');
update public.docs set data = data || '{"time":"20:00"}' where collection = 'sessions' and id = 'ns2';
select pg_temp.ok((select count(*) from net.calls) = 1, 'one push hand-off');
select pg_temp.ok((select body -> 'items' -> 0 -> 'payload' ->> 'title' from net.calls) = 'تم تعديل الحصة', 'pushed in the player''s language');
select pg_temp.ok((select body ->> 'secret' from net.calls) = (select secret from private.push_config), 'hand-off carries the secret');
select pg_temp.ok((select count(*) from public.notifications where pushed_at is null) = 0, 'messages marked as handed off');
update public.profiles set notif_prefs = notif_prefs || '{"push":false}' where id = '00000000-0000-4000-8000-00000000a004';
update public.docs set data = data || '{"time":"20:30"}' where collection = 'sessions' and id = 'ns2';
select pg_temp.ok((select count(*) from net.calls) = 1, 'no push when switched off (still in the app)');
select pg_temp.ok(pg_temp.got('00000000-0000-4000-8000-00000000a004', 'changed') = 3, 'in-app list still gets it');
