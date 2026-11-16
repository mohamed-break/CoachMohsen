-- Venue contact details: players see the venues of their own clubs only; only admins change venues.
\set ON_ERROR_STOP 1
create or replace function pg_temp.ok(c boolean, msg text) returns void language plpgsql as $$
begin if c is not true then raise exception 'FAILED: %', msg; end if; raise notice 'ok: %', msg; end $$;
insert into auth.users (id, email) values
  ('00000000-0000-4000-8000-00000000b001', 'v.admin@example.com'),
  ('00000000-0000-4000-8000-00000000b002', 'v.coach@example.com'),
  ('00000000-0000-4000-8000-00000000b003', 'v.player@example.com'),
  ('00000000-0000-4000-8000-00000000b004', 'v.other@example.com');
insert into public.orgs (id, name) values ('vclub', 'Venue Club'), ('vother', 'Other Club');
insert into public.org_members (org_id, user_id, role) values ('vclub', '00000000-0000-4000-8000-00000000b001', 'club_admin'), ('vclub', '00000000-0000-4000-8000-00000000b002', 'coach');
insert into public.docs (collection, id, data) values
  ('venues', 'vv1', '{"id":"vv1","name":"Andalus","clubId":"vclub","address":"Al Andalus, Riyadh","mapsUrl":"24.7136, 46.6753","phone":"+966500000000"}'),
  ('venues', 'vv2', '{"id":"vv2","name":"Elsewhere","clubId":"vother"}'),
  ('trainees', 'vp1', '{"id":"vp1","name":"Vera","linkedUserId":"00000000-0000-4000-8000-00000000b003"}');
insert into public.club_players (org_id, player_id) values ('vclub', 'vp1');

select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-00000000b003', false);
set role authenticated;
select pg_temp.ok(jsonb_array_length(public.my_venues()) = 1, 'player sees only their club''s venue');
select pg_temp.ok(public.my_venues() -> 0 ->> 'phone' = '+966500000000' and public.my_venues() -> 0 ->> 'address' <> '', 'with address and phone');
select pg_temp.ok((select count(*) from public.docs where collection = 'venues') = 0, 'player still cannot read venue records directly');
reset role;
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-00000000b004', false);
set role authenticated;
select pg_temp.ok(jsonb_array_length(public.my_venues()) = 0, 'outsider sees no venues');
reset role;
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-00000000b002', false);
set role authenticated;
select pg_temp.ok(jsonb_array_length(public.my_venues()) = 1, 'coach sees the club''s venue');
update public.docs set data = data || '{"phone":"+966511111111"}' where collection = 'venues' and id = 'vv1';
reset role;
select pg_temp.ok((select data ->> 'phone' from public.docs where id = 'vv1' and collection = 'venues') = '+966500000000', 'coach cannot change venue details');
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-00000000b001', false);
set role authenticated;
update public.docs set data = data || '{"phone":"+966522222222"}' where collection = 'venues' and id = 'vv1';
reset role;
select pg_temp.ok((select data ->> 'phone' from public.docs where id = 'vv1' and collection = 'venues') = '+966522222222', 'club admin can change venue details');

-- Arabic times: 12-hour with ص/م, isolated left-to-right
select pg_temp.ok(public.notif_tm('18:05', 'ar') = chr(8294) || '06:05 م' || chr(8297), 'evening time in Arabic');
select pg_temp.ok(public.notif_tm('00:30', 'ar') = chr(8294) || '12:30 ص' || chr(8297), 'after midnight in Arabic');
select pg_temp.ok(public.notif_tm('18:05', 'en') = '18:05', 'English stays 24-hour');
select pg_temp.ok(public.notif_when('{"date":"2026-11-17","time":"09:00"}', 'ar') like '%09:00 ص%', 'Arabic session line uses the new format');
