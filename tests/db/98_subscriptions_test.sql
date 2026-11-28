-- Subscriptions: prices, who manages, recording packages, usage, eligibility.
\set ON_ERROR_STOP 1
create or replace function pg_temp.ok(c boolean, msg text) returns void language plpgsql as $$
begin if c is not true then raise exception 'FAILED: %', msg; end if; raise notice 'ok: %', msg; end $$;
create or replace function pg_temp.as_user(u text) returns void language sql as $$ select set_config('request.jwt.claim.sub', u, false) $$;
create or replace function pg_temp.pk(p text) returns jsonb language sql as $$ select public.package_usage(p) $$;
insert into auth.users (id, email) values
  ('00000000-0000-4000-8000-0000000c0002', 's.admin@example.com'),
  ('00000000-0000-4000-8000-0000000c0003', 's.coach@example.com'),
  ('00000000-0000-4000-8000-0000000c0004', 's.player@example.com'),
  ('00000000-0000-4000-8000-0000000c0005', 's.coach2@example.com');
insert into public.orgs (id, name) values ('sclub', 'Subs Club');
insert into public.org_members (org_id, user_id, role) values ('sclub', '00000000-0000-4000-8000-0000000c0002', 'club_admin'),
  ('sclub', '00000000-0000-4000-8000-0000000c0003', 'coach'), ('sclub', '00000000-0000-4000-8000-0000000c0005', 'coach');
insert into public.docs (collection, id, data) values ('trainees', 'sp1', '{"id":"sp1","name":"Sami","linkedUserId":"00000000-0000-4000-8000-0000000c0004"}');
insert into public.club_players (org_id, player_id) values ('sclub', 'sp1');

-- prices: club admin yes, coach no (until he is the default coach and allowed)
select pg_temp.as_user('00000000-0000-4000-8000-0000000c0002');
set role authenticated;
select public.set_price_list('sclub', null, '[{"sessions":1,"single":250,"group":150,"validity":7},{"sessions":8,"single":1650,"group":960,"validity":60}]');
select public.set_price_list('sclub', '00000000-0000-4000-8000-0000000c0003', '[{"sessions":8,"single":1800,"validity":60}]');
select pg_temp.ok(jsonb_array_length(public.price_list('sclub')) = 3, 'club and coach prices saved');
reset role;
select pg_temp.as_user('00000000-0000-4000-8000-0000000c0003');
set role authenticated;
do $$ begin perform public.set_price_list('sclub', null, '[]'); raise exception 'FAILED: coach changed prices';
exception when insufficient_privilege then raise notice 'ok: coach cannot change prices'; end $$;
select pg_temp.ok(jsonb_array_length(public.price_list('sclub')) = 3, 'coach can read prices');
reset role;
select pg_temp.as_user('00000000-0000-4000-8000-0000000c0002');
set role authenticated;
select public.set_club_settings('sclub', '{"defaultCoach":"00000000-0000-4000-8000-0000000c0003","defaultCoachManagesSubs":true}');
reset role;
select pg_temp.as_user('00000000-0000-4000-8000-0000000c0003');
set role authenticated;
select pg_temp.ok(public.can_manage_subs('sclub'), 'default coach manages subscriptions when allowed');
-- the default coach records a package with a special price and a longer validity
select public.save_subscription(jsonb_build_object('org','sclub','coach','00000000-0000-4000-8000-0000000c0003','player','sp1','kind','single','sessions',4,
  'start', to_char(current_date - 10, 'YYYY-MM-DD'), 'end', to_char(current_date + 80, 'YYYY-MM-DD'), 'listPrice',900,'price',800,'reason','loyal','payStatus','paid','method','cash'));
reset role;
select pg_temp.as_user('00000000-0000-4000-8000-0000000c0005');
set role authenticated;
do $$ begin perform public.save_subscription(jsonb_build_object('org','sclub','coach','00000000-0000-4000-8000-0000000c0005','player','sp1','sessions',1,'start','2026-12-01','price',1));
  raise exception 'FAILED: other coach recorded a package';
exception when insufficient_privilege then raise notice 'ok: other coaches cannot record packages'; end $$;
reset role;

-- sessions with coach c0003: one done, one future, one cancelled by the coach, one player-cancelled (eligible), one player-cancelled (charged), one more future, one with another coach
select pg_temp.as_user('00000000-0000-4000-8000-0000000c0003');
insert into public.docs (collection, id, data) values
 ('sessions','ss1', jsonb_build_object('id','ss1','date',to_char(current_date - 5,'YYYY-MM-DD'),'time','18:00','status','done','traineeIds','["sp1"]'::jsonb,'clubId','sclub','coachId','00000000-0000-4000-8000-0000000c0003')),
 ('sessions','ss2', jsonb_build_object('id','ss2','date',to_char(current_date + 5,'YYYY-MM-DD'),'time','18:00','status','planned','traineeIds','["sp1"]'::jsonb,'clubId','sclub','coachId','00000000-0000-4000-8000-0000000c0003')),
 ('sessions','ss3', jsonb_build_object('id','ss3','date',to_char(current_date + 6,'YYYY-MM-DD'),'time','18:00','status','cancelled','traineeIds','["sp1"]'::jsonb,'clubId','sclub','coachId','00000000-0000-4000-8000-0000000c0003')),
 ('sessions','ss4', jsonb_build_object('id','ss4','date',to_char(current_date + 7,'YYYY-MM-DD'),'time','18:00','status','cancelled','traineeIds','["sp1"]'::jsonb,'clubId','sclub','coachId','00000000-0000-4000-8000-0000000c0003')),
 ('sessions','ss5', jsonb_build_object('id','ss5','date',to_char(current_date + 8,'YYYY-MM-DD'),'time','18:00','status','cancelled','traineeIds','["sp1"]'::jsonb,'clubId','sclub','coachId','00000000-0000-4000-8000-0000000c0003')),
 ('sessions','ss6', jsonb_build_object('id','ss6','date',to_char(current_date + 9,'YYYY-MM-DD'),'time','18:00','status','planned','traineeIds','["sp1"]'::jsonb,'clubId','sclub','coachId','00000000-0000-4000-8000-0000000c0003')),
 ('sessions','ss7', jsonb_build_object('id','ss7','date',to_char(current_date + 10,'YYYY-MM-DD'),'time','18:00','status','planned','traineeIds','["sp1"]'::jsonb,'clubId','sclub','coachId','00000000-0000-4000-8000-0000000c0003')),
 ('requests','ss4:00000000-0000-4000-8000-0000000c0004','{"sessionId":"ss4","status":"approved","charged":false}'),
 ('requests','ss5:00000000-0000-4000-8000-0000000c0004','{"sessionId":"ss5","status":"approved","charged":true}');
select pg_temp.as_user('00000000-0000-4000-8000-0000000c0005');
insert into public.docs (collection, id, data) values
 ('sessions','ss9', jsonb_build_object('id','ss9','date',to_char(current_date + 3,'YYYY-MM-DD'),'time','20:00','status','planned','traineeIds','["sp1"]'::jsonb,'clubId','sclub','coachId','00000000-0000-4000-8000-0000000c0005'));
-- package of 4: ss1 used, ss5 charged (used), ss2 + ss6 booked → full; ss7 without a package; coach 2's session without a package
select pg_temp.as_user('00000000-0000-4000-8000-0000000c0002');
set role authenticated;
select pg_temp.ok((select (p ->> 'used')::int = 2 and (p ->> 'booked')::int = 2 and (p ->> 'remaining')::int = 2 and (p ->> 'charged')::int = 1 and (p ->> 'unbooked')::int = 0
                     from jsonb_array_elements(pg_temp.pk('sp1') -> 'packages') p), 'usage: used, booked, remaining, charged');
select pg_temp.ok(jsonb_array_length(pg_temp.pk('sp1') -> 'unpackaged') = 2, 'sessions without a package, per coach');
select pg_temp.ok((select (x ->> 'count')::int from jsonb_array_elements(pg_temp.pk('sp1') -> 'unpackaged') x where x ->> 'coach_id' = '00000000-0000-4000-8000-0000000c0003') = 1, 'one extra session with this coach');
-- a new package takes the unpackaged session
select public.save_subscription(jsonb_build_object('org','sclub','coach','00000000-0000-4000-8000-0000000c0003','player','sp1','sessions',1,'start',to_char(current_date + 20,'YYYY-MM-DD'),'price',250));
select pg_temp.ok((select count(*) from jsonb_array_elements(pg_temp.pk('sp1') -> 'unpackaged') x where x ->> 'coach_id' = '00000000-0000-4000-8000-0000000c0003') = 0, 'next package covers the earlier unpackaged session');
-- eligibility
select pg_temp.ok((pg_temp.pk('sp1') -> 'eligible' ->> 'sclub')::boolean, 'eligible by default');
select public.set_makeup_eligible('sclub', 'sp1', false);
select pg_temp.ok(not (pg_temp.pk('sp1') -> 'eligible' ->> 'sclub')::boolean, 'eligibility changed by the club admin');
-- overview
select pg_temp.ok(jsonb_array_length(public.subs_overview('sclub') -> 'packages') = 2 and (public.subs_overview('sclub') -> 'revenue' ->> 'total')::numeric = 1050, 'overview with revenue');
reset role;
-- the player sees his own packages; another coach sees only his own
select pg_temp.as_user('00000000-0000-4000-8000-0000000c0004');
set role authenticated;
select pg_temp.ok(jsonb_array_length(pg_temp.pk('sp1') -> 'packages') = 2, 'player sees his packages');
do $$ begin perform public.subs_overview('sclub'); raise exception 'FAILED: player saw the overview';
exception when insufficient_privilege then raise notice 'ok: overview is for managers'; end $$;
reset role;
select pg_temp.as_user('00000000-0000-4000-8000-0000000c0005');
set role authenticated;
select pg_temp.ok(jsonb_array_length(pg_temp.pk('sp1') -> 'packages') = 0 and jsonb_array_length(pg_temp.pk('sp1') -> 'unpackaged') = 1, 'another coach sees only his own');
reset role;
