-- Default club and default coach: new accounts become players automatically.
\set ON_ERROR_STOP 1
create or replace function pg_temp.ok(c boolean, msg text) returns void language plpgsql as $$
begin if c is not true then raise exception 'FAILED: %', msg; end if; raise notice 'ok: %', msg; end $$;
create or replace function pg_temp.as_user(u text) returns void language sql as $$ select set_config('request.jwt.claim.sub', u, false) $$;
insert into auth.users (id, email) values
  ('00000000-0000-4000-8000-00000000d001', 'd.sys@example.com'),
  ('00000000-0000-4000-8000-00000000d002', 'd.admin@example.com'),
  ('00000000-0000-4000-8000-00000000d003', 'd.coach@example.com');
insert into public.user_roles (user_id, role) values ('00000000-0000-4000-8000-00000000d001', 'sysadmin') on conflict (user_id) do update set role = 'sysadmin';
insert into public.orgs (id, name) values ('dclub', 'Default Club');
insert into public.org_members (org_id, user_id, role) values ('dclub', '00000000-0000-4000-8000-00000000d002', 'club_admin'), ('dclub', '00000000-0000-4000-8000-00000000d003', 'coach');

-- no default club yet → a new account is not a player
insert into auth.users (id, email, raw_user_meta_data) values ('00000000-0000-4000-8000-00000000d010', 'early@example.com', '{"full_name":"Early Bird"}');
select pg_temp.ok(not exists (select 1 from public.docs where collection = 'trainees' and data ->> 'linkedUserId' = '00000000-0000-4000-8000-00000000d010'), 'no default club → no player');

-- only sys admins set the default club
select pg_temp.as_user('00000000-0000-4000-8000-00000000d002');
set role authenticated;
do $$ begin perform public.set_system_settings('{"defaultClub":"dclub"}'); raise exception 'FAILED: club admin set the default club';
exception when insufficient_privilege then raise notice 'ok: only sys admins change system settings'; end $$;
-- club admin sets the default coach; it must be a coach of the club
do $$ begin perform public.set_club_settings('dclub', '{"defaultCoach":"00000000-0000-4000-8000-00000000d002"}'); raise exception 'FAILED: non-coach accepted';
exception when invalid_parameter_value then raise notice 'ok: default coach must be a coach'; end $$;
select pg_temp.ok((public.set_club_settings('dclub', '{"defaultCoach":"00000000-0000-4000-8000-00000000d003"}') ->> 'defaultCoach') = '00000000-0000-4000-8000-00000000d003', 'club admin sets the default coach');
reset role;
select pg_temp.as_user('00000000-0000-4000-8000-00000000d001');
set role authenticated;
select pg_temp.ok((public.set_system_settings('{"defaultClub":"dclub"}') ->> 'defaultClub') = 'dclub', 'sys admin sets the default club');
do $$ begin perform public.set_system_settings('{"defaultClub":"nope"}'); raise exception 'FAILED: unknown club accepted';
exception when invalid_parameter_value then raise notice 'ok: unknown club refused'; end $$;
reset role;

-- a new account now becomes a player of the default club, assigned to the default coach, who is told
select set_config('request.jwt.claim.sub', '', false);
insert into auth.users (id, email, raw_user_meta_data) values ('00000000-0000-4000-8000-00000000d011', 'newbie@example.com', '{"full_name":"Nadia New"}');
select pg_temp.ok((select data ->> 'name' from public.docs where collection = 'trainees' and data ->> 'linkedUserId' = '00000000-0000-4000-8000-00000000d011') = 'Nadia New', 'player created with the account name');
select pg_temp.ok(exists (select 1 from public.club_players cp join public.docs t on t.id = cp.player_id and t.collection = 'trainees'
                           where cp.org_id = 'dclub' and t.data ->> 'linkedUserId' = '00000000-0000-4000-8000-00000000d011'), 'player is in the default club');
select pg_temp.ok(exists (select 1 from public.enrollments e join public.docs t on t.id = e.player_id and t.collection = 'trainees'
                           where e.org_id = 'dclub' and e.coach_id = '00000000-0000-4000-8000-00000000d003' and t.data ->> 'linkedUserId' = '00000000-0000-4000-8000-00000000d011'), 'player assigned to the default coach');
select pg_temp.ok(exists (select 1 from public.notifications where user_id = '00000000-0000-4000-8000-00000000d003' and kind = 'player_joined' and title_en = 'New player signed up'), 'default coach told');
-- the coach sees the player through the normal club_people/roster access
select pg_temp.as_user('00000000-0000-4000-8000-00000000d003');
set role authenticated;
select pg_temp.ok(exists (select 1 from public.club_players where org_id = 'dclub'), 'coach sees the new player in the club');
reset role;

-- the default coach leaves → setting cleared; a later sign-up joins the club without a coach
delete from public.org_members where org_id = 'dclub' and user_id = '00000000-0000-4000-8000-00000000d003';
select pg_temp.ok(not ((select settings from public.orgs where id = 'dclub') ? 'defaultCoach'), 'default coach cleared when the coach leaves');
insert into auth.users (id, email) values ('00000000-0000-4000-8000-00000000d012', 'later@example.com');
select pg_temp.ok(exists (select 1 from public.club_players cp join public.docs t on t.id = cp.player_id and t.collection = 'trainees'
                           where cp.org_id = 'dclub' and t.data ->> 'linkedUserId' = '00000000-0000-4000-8000-00000000d012'), 'later sign-up still joins the club');

-- clearing the default club stops it
select pg_temp.as_user('00000000-0000-4000-8000-00000000d001');
set role authenticated;
select pg_temp.ok((public.set_system_settings('{"defaultClub":""}') ->> 'defaultClub') is null, 'default club cleared');
reset role;
insert into auth.users (id, email) values ('00000000-0000-4000-8000-00000000d013', 'after@example.com');
select pg_temp.ok(not exists (select 1 from public.docs where collection = 'trainees' and data ->> 'linkedUserId' = '00000000-0000-4000-8000-00000000d013'), 'no default club → no player again');

-- cancelling without telling the players
insert into auth.users (id, email) values ('00000000-0000-4000-8000-00000000d020', 'q.coach@example.com'), ('00000000-0000-4000-8000-00000000d021', 'q.player@example.com');
insert into public.org_members (org_id, user_id, role) values ('dclub', '00000000-0000-4000-8000-00000000d020', 'coach');
insert into public.docs (collection, id, data) values ('trainees', 'qp1', '{"id":"qp1","name":"Quiet","linkedUserId":"00000000-0000-4000-8000-00000000d021"}');
select pg_temp.as_user('00000000-0000-4000-8000-00000000d020');
insert into public.docs (collection, id, data) values
  ('sessions', 'qs1', jsonb_build_object('id','qs1','date',to_char(now() at time zone 'Asia/Riyadh' + interval '4 days','YYYY-MM-DD'),'time','18:00','status','planned','traineeIds',jsonb_build_array('qp1'),'clubId','dclub','coachId','00000000-0000-4000-8000-00000000d020')),
  ('sessions', 'qs2', jsonb_build_object('id','qs2','date',to_char(now() at time zone 'Asia/Riyadh' + interval '5 days','YYYY-MM-DD'),'time','18:00','status','planned','traineeIds',jsonb_build_array('qp1'),'clubId','dclub','coachId','00000000-0000-4000-8000-00000000d020'));
update public.docs set data = data || '{"status":"cancelled","notifyPlayers":false,"cancelReason":"Rain"}' where collection = 'sessions' and id = 'qs1';
select pg_temp.ok((select count(*) from public.notifications where user_id = '00000000-0000-4000-8000-00000000d021' and kind = 'cancelled') = 0, 'cancelled without telling the player');
update public.docs set data = data || '{"status":"cancelled","notifyPlayers":true,"cancelReason":"Court closed"}' where collection = 'sessions' and id = 'qs2';
select pg_temp.ok((select count(*) from public.notifications where user_id = '00000000-0000-4000-8000-00000000d021' and kind = 'cancelled' and body_en like '%Court closed%') = 1, 'player told, with the reason');
