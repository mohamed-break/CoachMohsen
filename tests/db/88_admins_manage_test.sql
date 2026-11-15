-- Only club admins and sys admins add or change venues and skills.
\set ON_ERROR_STOP 1
create or replace function pg_temp.ok(c boolean, msg text) returns void language plpgsql as $$
begin if c is not true then raise exception 'FAILED: %', msg; end if; raise notice 'ok: %', msg; end $$;
create temp table vm as select (select id from public.orgs order by is_freelance desc, id limit 1) as org,
  (select m.user_id from public.org_members m where m.role = 'coach'
     and not exists (select 1 from public.org_members a where a.user_id = m.user_id and a.role = 'club_admin')
     and not exists (select 1 from public.user_roles u where u.user_id = m.user_id and u.role = 'sysadmin') order by m.user_id limit 1) as coach;
insert into auth.users (id, email) values ('00000000-0000-4000-8000-0000000000ad', 'venue.admin@example.com');
insert into public.org_members (org_id, user_id, role) select org, '00000000-0000-4000-8000-0000000000ad', 'club_admin' from vm;
grant select on vm to authenticated;
create or replace function pg_temp.try(who uuid, coll text, did text) returns text language plpgsql as $$
begin perform set_config('request.jwt.claim.sub', who::text, false); set local role authenticated;
  insert into public.docs (collection, id, data) values (coll, did, jsonb_build_object('id', did, 'name', 'X', 'name_en', 'X', 'clubId', (select org from vm)));
  reset role; return 'written';
exception when others then reset role; return 'refused'; end $$;
select pg_temp.ok(pg_temp.try((select coach from vm), 'venues', 'v-coach') = 'refused', 'a coach cannot add a venue');
select pg_temp.ok(pg_temp.try((select coach from vm), 'skills', 's-coach') = 'refused', 'a coach cannot add a skill');
select pg_temp.ok(pg_temp.try('00000000-0000-4000-8000-0000000000ad', 'venues', 'v-admin') = 'written', 'a club admin adds a venue');
select pg_temp.ok(pg_temp.try('00000000-0000-4000-8000-0000000000ad', 'skills', 's-admin') = 'written', 'a club admin adds a skill');
select set_config('request.jwt.claim.sub', (select coach::text from vm), false);
set role authenticated;
select pg_temp.ok(exists (select 1 from public.docs where collection = 'venues' and id = 'v-admin'), 'the coach still sees the club''s venues');
reset role;
