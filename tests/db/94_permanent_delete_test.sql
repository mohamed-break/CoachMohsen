-- Permanent delete of sessions: who may, what is removed, the log, and restore.
\set ON_ERROR_STOP 1
create or replace function pg_temp.ok(c boolean, msg text) returns void language plpgsql as $$
begin if c is not true then raise exception 'FAILED: %', msg; end if; raise notice 'ok: %', msg; end $$;
create or replace function pg_temp.as_user(u text) returns void language sql as $$ select set_config('request.jwt.claim.sub', u, false) $$;
insert into auth.users (id, email) values
  ('00000000-0000-4000-8000-00000000e001', 'e.sys@example.com'),
  ('00000000-0000-4000-8000-00000000e002', 'e.admin@example.com'),
  ('00000000-0000-4000-8000-00000000e003', 'e.coach@example.com'),
  ('00000000-0000-4000-8000-00000000e004', 'e.player@example.com');
insert into public.user_roles (user_id, role) values ('00000000-0000-4000-8000-00000000e001', 'sysadmin') on conflict (user_id) do update set role = 'sysadmin';
insert into public.orgs (id, name) values ('eclub', 'Purge Club');
insert into public.org_members (org_id, user_id, role) values ('eclub', '00000000-0000-4000-8000-00000000e002', 'club_admin'), ('eclub', '00000000-0000-4000-8000-00000000e003', 'coach');
insert into public.docs (collection, id, data) values ('trainees', 'ep1', '{"id":"ep1","name":"Eve","linkedUserId":"00000000-0000-4000-8000-00000000e004"}');
select pg_temp.as_user('00000000-0000-4000-8000-00000000e003');
insert into public.docs (collection, id, data) values
  ('sessions', 'es1', jsonb_build_object('id','es1','date',to_char(now() at time zone 'Asia/Riyadh' + interval '6 days','YYYY-MM-DD'),'time','17:00','status','planned','traineeIds',jsonb_build_array('ep1'),'clubId','eclub','coachId','00000000-0000-4000-8000-00000000e003')),
  ('sessremarks', 'es1', '{"text":"private note","clubId":"eclub","coachId":"00000000-0000-4000-8000-00000000e003"}');
select pg_temp.ok((select count(*) from public.notifications where session_id = 'es1') = 1, 'booking notice linked to the session');
select pg_temp.as_user('00000000-0000-4000-8000-00000000e004');
set role authenticated;
select public.request_cancel('es1', 'Busy');
reset role;

-- a coach without permission cannot delete, not even directly
select pg_temp.as_user('00000000-0000-4000-8000-00000000e003');
set role authenticated;
do $$ begin perform public.purge_session('es1'); raise exception 'FAILED: coach deleted without permission';
exception when insufficient_privilege then raise notice 'ok: coach needs permission'; end $$;
do $$ begin delete from public.docs where collection = 'sessions' and id = 'es1'; raise exception 'FAILED: direct delete allowed';
exception when insufficient_privilege then raise notice 'ok: direct delete refused'; end $$;
reset role;
-- the club admin allows the coach
select pg_temp.as_user('00000000-0000-4000-8000-00000000e002');
set role authenticated;
select public.set_delete_permission('eclub', '00000000-0000-4000-8000-00000000e003', true);
select pg_temp.ok(public.delete_permissions('eclub') ? '00000000-0000-4000-8000-00000000e003', 'permission granted');
reset role;
select pg_temp.as_user('00000000-0000-4000-8000-00000000e003');
set role authenticated;
do $$ begin perform public.set_delete_permission('eclub', '00000000-0000-4000-8000-00000000e003', true); raise exception 'FAILED: coach granted themselves';
exception when insufficient_privilege then raise notice 'ok: only club admins grant it'; end $$;
select pg_temp.ok(public.purge_session('es1') > 0, 'coach with permission deletes permanently');
reset role;
select pg_temp.ok(not exists (select 1 from public.docs where id = 'es1' or data ->> 'sessionId' = 'es1'), 'session, request and remarks gone');
select pg_temp.ok(not exists (select 1 from public.notifications where session_id = 'es1'), 'its notifications gone');
select pg_temp.ok(not exists (select 1 from public.notifications where user_id = '00000000-0000-4000-8000-00000000e004' and kind = 'cancelled'), 'player not told');
select pg_temp.ok(not exists (select 1 from public.notifications where user_id = '00000000-0000-4000-8000-00000000e003' and kind = 'request_withdrawn'), 'coach not told about the removed request');

-- the log: sys admins only
select pg_temp.as_user('00000000-0000-4000-8000-00000000e002');
set role authenticated;
do $$ begin perform public.deleted_sessions_list(); raise exception 'FAILED: club admin read the log';
exception when insufficient_privilege then raise notice 'ok: log is for sys admins'; end $$;
reset role;
select pg_temp.as_user('00000000-0000-4000-8000-00000000e001');
set role authenticated;
select pg_temp.ok((public.deleted_sessions_list('{"org":"eclub"}') -> 0 ->> 'session_id') = 'es1', 'sys admin sees the deleted session');
select pg_temp.ok((public.deleted_sessions_list('{"org":"eclub"}') -> 0 -> 'players' ->> 0) = 'Eve' and (public.deleted_sessions_list('{"org":"eclub"}') -> 0 ->> 'requests') = '1', 'with players and what was removed');
select public.restore_session((public.deleted_sessions_list('{"org":"eclub"}') -> 0 ->> 'id')::bigint);
reset role;
select pg_temp.ok(exists (select 1 from public.docs where collection = 'sessions' and id = 'es1' and coach_id = '00000000-0000-4000-8000-00000000e003' and club_id = 'eclub'), 'session restored with its coach and club');
select pg_temp.ok(exists (select 1 from public.docs where collection = 'sessremarks' and id = 'es1' and coach_id = '00000000-0000-4000-8000-00000000e003'), 'private remarks restored');
select pg_temp.ok(exists (select 1 from public.docs where collection = 'requests' and data ->> 'sessionId' = 'es1'), 'request restored');
select pg_temp.ok((select count(*) from public.notifications where user_id = '00000000-0000-4000-8000-00000000e004' and kind = 'booked') = 0, 'restore is quiet');
select pg_temp.as_user('00000000-0000-4000-8000-00000000e001');
set role authenticated;
select pg_temp.ok((public.deleted_sessions_list('{"state":"restored"}') -> 0 ->> 'restored_at') is not null, 'log shows it was restored');
do $$ begin perform public.restore_session((public.deleted_sessions_list('{"org":"eclub"}') -> 0 ->> 'id')::bigint); raise exception 'FAILED: restored twice';
exception when invalid_parameter_value then raise notice 'ok: cannot restore twice'; end $$;
reset role;
-- a coach cannot delete another coach's session even with permission
insert into auth.users (id, email) values ('00000000-0000-4000-8000-00000000e005', 'e.coach2@example.com');
insert into public.org_members (org_id, user_id, role, can_delete_sessions) values ('eclub', '00000000-0000-4000-8000-00000000e005', 'coach', true);
select pg_temp.as_user('00000000-0000-4000-8000-00000000e005');
set role authenticated;
do $$ begin perform public.purge_session('es1'); raise exception 'FAILED: deleted another coach''s session';
exception when insufficient_privilege then raise notice 'ok: only own sessions'; end $$;
reset role;
