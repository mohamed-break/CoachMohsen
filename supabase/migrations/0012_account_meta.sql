-- CoachMohsen · migration 0012
-- Photos and last sign-in for the Users and Players pages.
-- Sys admins see every account; coaches and club admins see the accounts of the players they can see.
create or replace function public.account_meta()
returns table (user_id uuid, player_id text, avatar_path text, name text, last_sign_in_at timestamptz)
language sql stable security definer set search_path = public, auth as $$
  with linked as (
    select (d.data ->> 'linkedUserId')::uuid as uid, d.id as pid
      from public.docs d
     where d.collection = 'trainees' and coalesce(d.data ->> 'linkedUserId', '') ~ '^[0-9a-f-]{36}$'
  )
  select u.id, l.pid, p.avatar_path, public.display_name(u.id), u.last_sign_in_at
    from auth.users u
    left join public.profiles p on p.id = u.id
    left join linked l on l.uid = u.id
   where public.is_sysadmin() or (l.pid is not null and public.can_see_player(l.pid));
$$;
grant execute on function public.account_meta() to authenticated;
revoke execute on function public.account_meta() from anon, public;
