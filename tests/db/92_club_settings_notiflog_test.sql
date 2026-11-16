-- Club settings and the sys admin notification log.
\set ON_ERROR_STOP 1
create or replace function pg_temp.ok(c boolean, msg text) returns void language plpgsql as $$
begin if c is not true then raise exception 'FAILED: %', msg; end if; raise notice 'ok: %', msg; end $$;
create or replace function pg_temp.as_user(u text) returns void language sql as $$ select set_config('request.jwt.claim.sub', u, false) $$;
insert into auth.users (id, email) values
  ('00000000-0000-4000-8000-00000000c001', 'c.sys@example.com'),
  ('00000000-0000-4000-8000-00000000c002', 'c.admin@example.com'),
  ('00000000-0000-4000-8000-00000000c003', 'c.coach@example.com'),
  ('00000000-0000-4000-8000-00000000c004', 'c.player@example.com');
insert into public.user_roles (user_id, role) values ('00000000-0000-4000-8000-00000000c001', 'sysadmin') on conflict (user_id) do update set role = 'sysadmin';
insert into public.orgs (id, name) values ('cclub', 'Settings Club');
insert into public.org_members (org_id, user_id, role) values ('cclub', '00000000-0000-4000-8000-00000000c002', 'club_admin'), ('cclub', '00000000-0000-4000-8000-00000000c003', 'coach');
insert into public.docs (collection, id, data) values ('trainees', 'cp1', '{"id":"cp1","name":"Cara","linkedUserId":"00000000-0000-4000-8000-00000000c004"}');
insert into public.club_players (org_id, player_id) values ('cclub', 'cp1');

-- settings: admins change them, coaches cannot; everyone in the club can read them
select pg_temp.as_user('00000000-0000-4000-8000-00000000c003');
set role authenticated;
do $$ begin perform public.set_club_settings('cclub', '{"suggestPlanned":false}'); raise exception 'FAILED: coach changed settings';
exception when insufficient_privilege then raise notice 'ok: coaches cannot change club settings'; end $$;
reset role;
select pg_temp.as_user('00000000-0000-4000-8000-00000000c002');
set role authenticated;
select pg_temp.ok((public.set_club_settings('cclub', '{"suggestPlanned":false,"junk":1}') ->> 'suggestPlanned') = 'false', 'club admin turns suggestions off');
reset role;
select pg_temp.ok(not (select settings ? 'junk' from public.orgs where id = 'cclub'), 'unknown settings ignored');
select pg_temp.as_user('00000000-0000-4000-8000-00000000c003');
set role authenticated;
select pg_temp.ok((public.club_settings() -> 'cclub' ->> 'suggestPlanned') = 'false', 'coach reads the club setting');
reset role;
select pg_temp.as_user('00000000-0000-4000-8000-00000000c004');
set role authenticated;
select pg_temp.ok(public.club_settings() ? 'cclub', 'player reads their club''s settings');
reset role;

-- a session booking records club, venue, coach and player on the message
select pg_temp.as_user('00000000-0000-4000-8000-00000000c003');
insert into public.docs (collection, id, data) values ('sessions', 'cs1', jsonb_build_object('id','cs1','date',to_char(now() at time zone 'Asia/Riyadh' + interval '3 days','YYYY-MM-DD'),
  'time','18:00','status','planned','location','Andalus','traineeIds',jsonb_build_array('cp1'),'clubId','cclub','coachId','00000000-0000-4000-8000-00000000c003'));
select pg_temp.ok((select org_id = 'cclub' and venue = 'Andalus' and coach_id = '00000000-0000-4000-8000-00000000c003' and player_id = 'cp1'
                     from public.notifications where kind = 'booked' and user_id = '00000000-0000-4000-8000-00000000c004'), 'booking message knows its club, venue, coach and player');

-- the log: sys admin only, with filters
select pg_temp.as_user('00000000-0000-4000-8000-00000000c002');
set role authenticated;
do $$ begin perform public.admin_notifications(); raise exception 'FAILED: club admin read the log';
exception when insufficient_privilege then raise notice 'ok: only sys admins see the log'; end $$;
reset role;
select pg_temp.as_user('00000000-0000-4000-8000-00000000c001');
set role authenticated;
select pg_temp.ok(jsonb_array_length(public.admin_notifications('{"org":"cclub"}')) >= 1, 'filter by club');
select pg_temp.ok(jsonb_array_length(public.admin_notifications('{"venue":"Andalus","player":"cp1"}')) >= 1, 'filter by venue and player');
select pg_temp.ok(jsonb_array_length(public.admin_notifications('{"coach":"00000000-0000-4000-8000-00000000c003","status":"unread"}')) >= 1, 'filter by coach and unread');
select pg_temp.ok(jsonb_array_length(public.admin_notifications('{"org":"nope"}')) = 0, 'unknown club → nothing');
select pg_temp.ok((public.admin_notifications('{"player":"cp1"}') -> 0 ->> 'player_name') = 'Cara', 'names included');
select pg_temp.ok(jsonb_array_length(public.admin_notif_filters() -> 'orgs') >= 1, 'filter choices');
reset role;
select pg_temp.as_user('00000000-0000-4000-8000-00000000c004');
set role authenticated;
select public.mark_notifications_read();
reset role;
select pg_temp.as_user('00000000-0000-4000-8000-00000000c001');
set role authenticated;
select pg_temp.ok((public.admin_notifications('{"player":"cp1","status":"read"}') -> 0 ->> 'read_at') is not null, 'read time shown');
reset role;
