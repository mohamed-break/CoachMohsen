-- Last active: the latest of sign-in, background renewal and the app being opened.
\set ON_ERROR_STOP 1
create or replace function pg_temp.ok(c boolean, msg text) returns void language plpgsql as $$
begin if c is not true then raise exception 'FAILED: %', msg; end if; raise notice 'ok: %', msg; end $$;
insert into auth.users (id, email, last_sign_in_at) values ('00000000-0000-4000-8000-0000000b0001', 'la.sys@example.com', now() - interval '10 days'),
  ('00000000-0000-4000-8000-0000000b0002', 'la.user@example.com', now() - interval '12 days');
insert into public.user_roles (user_id, role) values ('00000000-0000-4000-8000-0000000b0001', 'sysadmin') on conflict (user_id) do update set role = 'sysadmin';
insert into auth.sessions (user_id, updated_at) values ('00000000-0000-4000-8000-0000000b0002', now() - interval '3 hours');
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-0000000b0001', false);
set role authenticated;
select pg_temp.ok((select last_sign_in_at > now() - interval '4 hours' from public.account_meta() where user_id = '00000000-0000-4000-8000-0000000b0002'), 'background renewal counts as active');
select public.touch_last_seen();
select pg_temp.ok((select last_sign_in_at > now() - interval '1 minute' from public.account_meta() where user_id = '00000000-0000-4000-8000-0000000b0001'), 'opening the app counts as active');
reset role;
