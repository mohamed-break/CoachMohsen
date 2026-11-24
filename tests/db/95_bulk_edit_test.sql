-- Bulk edit: one combined notice per player instead of one per session.
\set ON_ERROR_STOP 1
create or replace function pg_temp.ok(c boolean, msg text) returns void language plpgsql as $$
begin if c is not true then raise exception 'FAILED: %', msg; end if; raise notice 'ok: %', msg; end $$;
create or replace function pg_temp.as_user(u text) returns void language sql as $$ select set_config('request.jwt.claim.sub', u, false) $$;
insert into auth.users (id, email) values
  ('00000000-0000-4000-8000-00000000f002', 'f.admin@example.com'),
  ('00000000-0000-4000-8000-00000000f003', 'f.coach@example.com'),
  ('00000000-0000-4000-8000-00000000f004', 'f.player@example.com'),
  ('00000000-0000-4000-8000-00000000f005', 'f.coach2@example.com');
insert into public.orgs (id, name) values ('fclub', 'Bulk Club');
insert into public.org_members (org_id, user_id, role) values ('fclub', '00000000-0000-4000-8000-00000000f002', 'club_admin'),
  ('fclub', '00000000-0000-4000-8000-00000000f003', 'coach'), ('fclub', '00000000-0000-4000-8000-00000000f005', 'coach');
insert into public.docs (collection, id, data) values ('trainees', 'fp1', '{"id":"fp1","name":"Faye","linkedUserId":"00000000-0000-4000-8000-00000000f004"}');
select pg_temp.as_user('00000000-0000-4000-8000-00000000f003');
insert into public.docs (collection, id, data)
select 'sessions', 'fs' || g, jsonb_build_object('id', 'fs' || g, 'date', to_char(now() at time zone 'Asia/Riyadh' + (g || ' days')::interval + interval '3 days', 'YYYY-MM-DD'),
  'time', '18:00', 'status', 'planned', 'traineeIds', jsonb_build_array('fp1'), 'clubId', 'fclub', 'coachId', '00000000-0000-4000-8000-00000000f003')
from generate_series(1, 3) g;
delete from public.notifications;
-- bulk change of time: no per-session notices
update public.docs set data = data || '{"time":"19:00","bulkEdit":"b1"}' where collection = 'sessions' and id in ('fs1', 'fs2', 'fs3');
select pg_temp.ok((select count(*) from public.notifications where user_id = '00000000-0000-4000-8000-00000000f004') = 0, 'no notice per session');
set role authenticated;
select public.bulk_session_notice(array['fs1', 'fs2', 'fs3'], 'changed', true);
reset role;
select pg_temp.ok((select count(*) from public.notifications where user_id = '00000000-0000-4000-8000-00000000f004' and kind = 'changed' and title_en = '3 sessions changed') = 1, 'one combined notice');
-- a normal single edit still notifies
update public.docs set data = data || '{"time":"20:00"}' where collection = 'sessions' and id = 'fs1';
select pg_temp.ok((select count(*) from public.notifications where user_id = '00000000-0000-4000-8000-00000000f004' and kind = 'changed') = 2, 'single edit still notifies');
-- bulk cancel, quietly
update public.docs set data = data || '{"status":"cancelled","notifyPlayers":false,"bulkEdit":"b2"}' where collection = 'sessions' and id in ('fs2', 'fs3');
select pg_temp.ok((select count(*) from public.notifications where user_id = '00000000-0000-4000-8000-00000000f004' and kind = 'cancelled') = 0, 'bulk cancel sends nothing by itself');
-- admin moves sessions to another coach: that coach gets one notice
select pg_temp.as_user('00000000-0000-4000-8000-00000000f002');
update public.docs set data = data || '{"coachId":"00000000-0000-4000-8000-00000000f005","bulkEdit":"b3"}' where collection = 'sessions' and id in ('fs1', 'fs2');
set role authenticated;
select public.bulk_session_notice(array['fs1', 'fs2'], 'coach', false);
reset role;
select pg_temp.ok((select count(*) from public.notifications where user_id = '00000000-0000-4000-8000-00000000f005' and title_en = '2 sessions were assigned to you') = 1, 'new coach told once');
-- someone who doesn't manage the sessions can't send notices
insert into auth.users (id, email) values ('00000000-0000-4000-8000-00000000f009', 'f.out@example.com');
select pg_temp.as_user('00000000-0000-4000-8000-00000000f009');
set role authenticated;
do $$ begin perform public.bulk_session_notice(array['fs1'], 'changed', true); raise exception 'FAILED: outsider sent notices';
exception when insufficient_privilege then raise notice 'ok: outsiders cannot send notices'; end $$;
reset role;
