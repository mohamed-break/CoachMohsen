-- Users page: register a signed-up account as a player.
\set ON_ERROR_STOP 1
create or replace function pg_temp.ok(c boolean, msg text) returns void language plpgsql as $$
begin if c is not true then raise exception 'FAILED: %', msg; end if; raise notice 'ok: %', msg; end $$;
insert into auth.users (id, email, raw_user_meta_data) values ('00000000-0000-4000-8000-00000000b0b1', 'reg.me@example.com', '{"full_name":"Sara Nabil"}');
create temp table rc as select (select id from public.orgs order by is_freelance desc, id limit 1) as org,
  (select user_id from public.user_roles where role = 'sysadmin' limit 1) as sys;
grant select on rc to authenticated;
select set_config('request.jwt.claim.sub', (select sys::text from rc), false);
set role authenticated;
select pg_temp.ok(not exists (select 1 from public.linked_players() where user_id = '00000000-0000-4000-8000-00000000b0b1'), 'a new account has no player profile');
create temp table rr as select public.register_user_as_player((select org from rc), '00000000-0000-4000-8000-00000000b0b1') as p1,
                                public.register_user_as_player((select org from rc), '00000000-0000-4000-8000-00000000b0b1') as p2;
grant select on rr to authenticated;
select pg_temp.ok((select player_name from public.linked_players() where user_id = '00000000-0000-4000-8000-00000000b0b1') = 'Sara Nabil', 'registered and named from the account');
reset role;
select pg_temp.ok((select p1 = p2 from rr), 'a second tap creates nothing new');
select pg_temp.ok(exists (select 1 from public.club_players where player_id = (select p1 from rr) and org_id = (select org from rc)), 'the player is in the club');
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-00000000b0b1', false);
set role authenticated;
do $$ begin
  begin perform public.register_user_as_player((select org from rc), '00000000-0000-4000-8000-00000000b0b1'); raise exception 'FAILED: a player registered someone';
  exception when sqlstate '42501' then raise notice 'ok: only a sys admin can register players'; end;
end $$;
select pg_temp.ok(not exists (select 1 from public.linked_players()), 'players cannot list linked profiles');
reset role;
