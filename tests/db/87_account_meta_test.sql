-- Photos and last sign-in: who can see what.
\set ON_ERROR_STOP 1
create or replace function pg_temp.ok(c boolean, msg text) returns void language plpgsql as $$
begin if c is not true then raise exception 'FAILED: %', msg; end if; raise notice 'ok: %', msg; end $$;
update auth.users set last_sign_in_at = '2026-11-12 10:00+00' where email like 'player@%';
create temp table am as select (select count(*) from auth.users) as n_users, (select user_id from public.user_roles where role = 'sysadmin' limit 1) as sys,
  (select id from auth.users where email like 'player@%' limit 1) as player,
  (select e.coach_id from public.enrollments e join public.docs d on d.collection = 'trainees' and d.id = e.player_id
     where d.data ->> 'linkedUserId' = (select id::text from auth.users where email like 'player@%' limit 1) limit 1) as coach;
grant select on am to authenticated;
select set_config('request.jwt.claim.sub', (select sys::text from am), false);
set role authenticated;
select pg_temp.ok((select count(*) from public.account_meta()) = (select n_users from am), 'a sys admin sees every account');
reset role;
select set_config('request.jwt.claim.sub', (select coach::text from am), false);
set role authenticated;
select pg_temp.ok((select last_sign_in_at from public.account_meta() where user_id = (select player from am)) = '2026-11-12 10:00+00', 'a coach sees the last sign-in of their player');
select pg_temp.ok(not exists (select 1 from public.account_meta() where player_id is null), 'a coach sees no accounts that are not their players');
reset role;
select set_config('request.jwt.claim.sub', (select player::text from am), false);
set role authenticated;
select pg_temp.ok((select count(*) from public.account_meta() where user_id <> auth.uid()) = 0, 'a player sees no other accounts');
reset role;
