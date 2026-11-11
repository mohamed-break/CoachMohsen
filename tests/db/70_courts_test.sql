-- CoachMohsen: one club, one venue with 4 courts, 16 skills, and no double booking across coaches.
\set ON_ERROR_STOP 1
create or replace function pg_temp.ok(c boolean, msg text) returns void language plpgsql as $$
begin if c is not true then raise exception 'FAILED: %', msg; end if; raise notice 'ok: %', msg; end $$;
select pg_temp.ok((select string_agg(id, ',') from public.orgs) = 'padelpro', 'only the Padel Pro club exists');
select pg_temp.ok((select jsonb_array_length(data -> 'courts') from public.docs where collection = 'venues' and id = 'andalus') = 4, 'Andalus has 4 courts');
select pg_temp.ok((select data ->> 'name' from public.docs where collection = 'venues' and id = 'andalus') = 'Padel Pro - Andalus', 'venue name');
select pg_temp.ok((select count(*) from public.docs where collection = 'skills' and club_id = 'padelpro') = 16, '16 skills in Padel Pro');

-- two coaches in the club
insert into auth.users (id, email) values ('00000000-0000-4000-8000-0000000000c1', 'c1@test.dev'), ('00000000-0000-4000-8000-0000000000c2', 'c2@test.dev');
insert into public.org_members (org_id, user_id, role) values ('padelpro', '00000000-0000-4000-8000-0000000000c1', 'coach'), ('padelpro', '00000000-0000-4000-8000-0000000000c2', 'coach');
create or replace function pg_temp.book(coach text, sid text, d text, tm text, dur int, court text, st text default 'planned') returns text language plpgsql as $$
begin perform set_config('request.jwt.claim.sub', coach, false); set local role authenticated;
  insert into public.docs (collection, id, data) values ('sessions', sid, jsonb_build_object('id', sid, 'clubId', 'padelpro', 'coachId', coach, 'date', d, 'time', tm, 'duration', dur, 'courtId', court, 'courtName', 'Court 1', 'status', st, 'traineeIds', '[]'::jsonb))
  on conflict (collection, id) do update set data = excluded.data;
  reset role; return 'booked';
exception when others then reset role; return sqlerrm; end $$;
select pg_temp.ok(pg_temp.book('00000000-0000-4000-8000-0000000000c1', 's1', '2026-12-01', '18:00', 60, 'andalus-c1') = 'booked', 'coach 1 books court 1 at 18:00');
select pg_temp.ok(pg_temp.book('00000000-0000-4000-8000-0000000000c2', 's2', '2026-12-01', '18:30', 60, 'andalus-c1') like 'COURT_BUSY%', 'coach 2 cannot overlap on court 1');
select pg_temp.ok(pg_temp.book('00000000-0000-4000-8000-0000000000c2', 's2', '2026-12-01', '18:30', 60, 'andalus-c2') = 'booked', 'coach 2 books court 2 instead');
select pg_temp.ok(pg_temp.book('00000000-0000-4000-8000-0000000000c2', 's3', '2026-12-01', '19:00', 90, 'andalus-c1') = 'booked', 'back-to-back on court 1 is fine');
select pg_temp.ok(pg_temp.book('00000000-0000-4000-8000-0000000000c2', 's4', '2026-12-01', '', 60, 'andalus-c3') like 'COURT_NEEDS_TIME%', 'a court booking needs a time');
select pg_temp.ok(pg_temp.book('00000000-0000-4000-8000-0000000000c1', 's1', '2026-12-01', '18:00', 60, 'andalus-c1', 'cancelled') = 'booked', 'coach 1 cancels');
select pg_temp.ok(pg_temp.book('00000000-0000-4000-8000-0000000000c2', 's5', '2026-12-01', '18:00', 60, 'andalus-c1') = 'booked', 'a cancelled session frees the court');
select pg_temp.ok(pg_temp.book('00000000-0000-4000-8000-0000000000c1', 's1', '2026-12-01', '18:00', 60, 'andalus-c1') like 'COURT_BUSY%', 'reopening a cancelled session checks the court again');
-- busy list: times only, own flag
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-0000000000c1', false);
set role authenticated;
select pg_temp.ok((select count(*) from public.court_busy('2026-12-01')) = 3, 'busy list shows every active booking that day');
select pg_temp.ok((select count(*) from public.court_busy('2026-12-01') where mine) = 0, 'busy list marks only own sessions as mine');
select pg_temp.ok((select count(*) from public.docs where collection = 'sessions' and coach_id <> auth.uid()) = 0, 'coach 1 still cannot read coach 2''s sessions');
reset role;
