-- Admins create players in one step, with or without a sign-in account.
\set ON_ERROR_STOP 1
create or replace function pg_temp.ok(c boolean, msg text) returns void language plpgsql as $$
begin if c is not true then raise exception 'FAILED: %', msg; end if; raise notice 'ok: %', msg; end $$;
create temp table ctx as select (select id from public.orgs order by is_freelance desc, id limit 1) as org,
  (select user_id from public.user_roles where role = 'sysadmin' limit 1) as sys,
  (select m.user_id from public.org_members m where m.role = 'coach'
     and not exists (select 1 from public.org_members a where a.user_id = m.user_id and a.role = 'club_admin')
     and not exists (select 1 from public.user_roles u where u.user_id = m.user_id and u.role = 'sysadmin') order by m.user_id limit 1) as coach;
grant select on ctx to authenticated;
select set_config('request.jwt.claim.sub', (select sys::text from ctx), false);
set role authenticated;
create temp table r1 as select public.admin_create_player((select org from ctx), 'Quick Player', 'Quick.Player@Example.com ', '+966 55 000 1111', 3, array[(select coach from ctx)]) as r;
create temp table r2 as select public.admin_create_player((select org from ctx), 'No Email Player', '', '', null, '{}') as r;
reset role;
select pg_temp.ok((select (r ->> 'newAccount')::boolean from r1), 'a new sign-in account is created for a new email');
select pg_temp.ok(exists (select 1 from auth.users u join auth.identities i on i.user_id = u.id where u.email = 'quick.player@example.com' and u.email_confirmed_at is not null), 'account is confirmed and can sign in by email');
select pg_temp.ok((select data ->> 'linkedUserId' from public.docs where collection = 'trainees' and id = (select r ->> 'playerId' from r1)) = (select r ->> 'userId' from r1), 'player profile is linked to the account');
select pg_temp.ok((select full_name || '|' || phone from public.profiles where email = 'quick.player@example.com') = 'Quick Player|+966 55 000 1111', 'account has the name and phone');
select pg_temp.ok(exists (select 1 from public.club_players where player_id = (select r ->> 'playerId' from r1) and org_id = (select org from ctx)), 'player is in the club');
select pg_temp.ok((select count(*) from public.enrollments where player_id = (select r ->> 'playerId' from r1)) = 1, 'player is assigned to the chosen coach');
select pg_temp.ok((select r ->> 'userId' from r2) is null and exists (select 1 from public.docs where collection = 'trainees' and id = (select r ->> 'playerId' from r2)), 'without an email only the profile is created');
-- same email again: no second account or profile
select set_config('request.jwt.claim.sub', (select sys::text from ctx), false);
set role authenticated;
create temp table r3 as select public.admin_create_player((select org from ctx), 'Quick Player', 'quick.player@example.com', '', null, '{}') as r;
reset role;
select pg_temp.ok((select r ->> 'playerId' from r3) = (select r ->> 'playerId' from r1) and not (select (r ->> 'newAccount')::boolean from r3), 'an existing email reuses the account and profile');
-- coaches cannot use it
select set_config('request.jwt.claim.sub', (select coach::text from ctx), false);
set role authenticated;
do $$ begin
  begin perform public.admin_create_player((select org from ctx), 'X', 'x@example.com', '', null, '{}'); raise exception 'FAILED: coach created a player account';
  exception when sqlstate '42501' then raise notice 'ok: a coach cannot create player accounts'; end;
end $$;
reset role;
