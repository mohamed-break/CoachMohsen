-- Join links and names from Google.
\set ON_ERROR_STOP 1
create or replace function pg_temp.ok(c boolean, msg text) returns void language plpgsql as $$
begin if c is not true then raise exception 'FAILED: %', msg; end if; raise notice 'ok: %', msg; end $$;
create temp table jc as select (select id from public.orgs order by is_freelance desc, id limit 1) as org,
  (select m.user_id from public.org_members m where m.role = 'coach'
     and not exists (select 1 from public.org_members a where a.user_id = m.user_id and a.role = 'club_admin')
     and not exists (select 1 from public.user_roles u where u.user_id = m.user_id and u.role = 'sysadmin') order by m.user_id limit 1) as coach;
grant select on jc to authenticated, anon;
-- a coach's own link, stable until renewed
select set_config('request.jwt.claim.sub', (select coach::text from jc), false);
set role authenticated;
create temp table codes as select public.my_join_code((select org from jc)) as c1, public.my_join_code((select org from jc)) as c2;
reset role;
grant select on codes to authenticated, anon;
select pg_temp.ok((select c1 = c2 and length(c1) = 10 from codes), 'a coach has one stable invite link');
set role anon;
select pg_temp.ok((select public.join_info((select c1 from codes)) ->> 'coach') is not null, 'the invite shows the coach and club before sign-in');
reset role;
-- a new Google account joins through it
insert into auth.users (id, email, raw_user_meta_data) values ('00000000-0000-4000-8000-00000000a0a1', 'google.player@example.com', '{"full_name":"Layla Hassan","name":"Layla Hassan"}');
select pg_temp.ok((select full_name from public.profiles where id = '00000000-0000-4000-8000-00000000a0a1') = 'Layla Hassan', 'the Google full name is saved on the account');
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-00000000a0a1', false);
set role authenticated;
create temp table j1 as select public.join_with_code((select upper(c1) from codes)) as r;
create temp table j2 as select public.join_with_code((select c1 from codes)) as r;
reset role;
select pg_temp.ok((select data ->> 'name' from public.docs where collection = 'trainees' and id = (select r ->> 'playerId' from j1)) = 'Layla Hassan', 'the new player is named from Google');
select pg_temp.ok(exists (select 1 from public.enrollments where player_id = (select r ->> 'playerId' from j1) and coach_id = (select coach from jc)), 'the player is assigned to the coach who shared the link');
select pg_temp.ok((select r ->> 'playerId' from j2) = (select r ->> 'playerId' from j1) and not (select (r ->> 'newPlayer')::boolean from j2), 'opening the link again creates nothing new');
-- an older account without a name gets it when it later signs in with Google
insert into auth.users (id, email) values ('00000000-0000-4000-8000-00000000a0a2', 'old.account@example.com');
update auth.users set raw_user_meta_data = '{"full_name":"Omar Saleh"}' where id = '00000000-0000-4000-8000-00000000a0a2';
select pg_temp.ok((select full_name from public.profiles where id = '00000000-0000-4000-8000-00000000a0a2') = 'Omar Saleh', 'a later Google sign-in fills an empty name');
-- renewing the link turns the old one off
select set_config('request.jwt.claim.sub', (select coach::text from jc), false);
set role authenticated;
select public.my_join_code((select org from jc), true);
reset role;
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-00000000a0a2', false);
set role authenticated;
do $$ begin
  begin perform public.join_with_code((select c1 from codes)); raise exception 'FAILED: old link still works';
  exception when sqlstate 'P0001' then raise notice 'ok: a renewed link replaces the old one'; end;
  begin perform public.my_join_code((select org from jc)); raise exception 'FAILED: a player got an invite link';
  exception when sqlstate '42501' then raise notice 'ok: players have no invite links'; end;
end $$;
reset role;
