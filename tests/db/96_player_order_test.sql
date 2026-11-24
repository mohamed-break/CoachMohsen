-- Players page order: saved per person and club; reset to A–Z.
\set ON_ERROR_STOP 1
create or replace function pg_temp.ok(c boolean, msg text) returns void language plpgsql as $$
begin if c is not true then raise exception 'FAILED: %', msg; end if; raise notice 'ok: %', msg; end $$;
insert into auth.users (id, email) values ('00000000-0000-4000-8000-0000000a0001', 'o.coach@example.com'), ('00000000-0000-4000-8000-0000000a0002', 'o.other@example.com');
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-0000000a0001', false);
set role authenticated;
select public.set_player_order('c1', array['p3', 'p1', 'p2']);
select public.set_player_order('c2', array['p9']);
select pg_temp.ok(public.my_player_order() -> 'c1' = '["p3","p1","p2"]'::jsonb and public.my_player_order() ? 'c2', 'order saved per club');
select public.set_player_order('c1', array[]::text[]);
select pg_temp.ok(not public.my_player_order() ? 'c1' and public.my_player_order() ? 'c2', 'reset to A-Z for one club');
reset role;
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-0000000a0002', false);
set role authenticated;
select pg_temp.ok(public.my_player_order() = '{}'::jsonb, 'each person has their own order');
reset role;
