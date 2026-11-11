-- Demo accounts: created once, re-runnable, one per role in the freelance club.
\set pw 'local-demo-pass-123'
\i supabase/seed/demo_users.sql
\i supabase/seed/demo_users.sql
do $$ declare n int; begin
  select count(*) into n from auth.users where email like '%@coachmohsen.dev' and encrypted_password = extensions.crypt('local-demo-pass-123', encrypted_password);
  if n <> 4 then raise exception 'demo users with password: %', n; end if;
  if (select count(*) from auth.identities where email like '%@coachmohsen.dev') <> 4 then raise exception 'identities'; end if;
  if not exists (select 1 from public.user_roles r join auth.users u on u.id = r.user_id where u.email = 'sysadmin@coachmohsen.dev' and r.role = 'sysadmin') then raise exception 'sysadmin role'; end if;
  if (select count(*) from public.org_members m join auth.users u on u.id = m.user_id where m.org_id = 'padelpro' and u.email in ('clubadmin@coachmohsen.dev', 'coach@coachmohsen.dev')) <> 2 then raise exception 'members'; end if;
  if (select count(*) from public.docs where id like 'demo-s%' and collection = 'sessions') <> 3 then raise exception 'sessions'; end if;
  raise notice 'ok: demo accounts and sample data';
end $$;
-- the demo player sees their sessions in the 360 view
select set_config('request.jwt.claim.sub', (select id::text from auth.users where email = 'player@coachmohsen.dev'), false);
set role authenticated;
do $$ begin if jsonb_array_length(public.player_360() -> 'history') <> 3 then raise exception 'player 360 %', public.player_360(); end if; raise notice 'ok: demo player 360 view'; end $$;
reset role;
