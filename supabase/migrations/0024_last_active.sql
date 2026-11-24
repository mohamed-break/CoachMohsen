-- "Last sign-in" only changed when someone typed their password or used Google again; people who stay
-- signed in on their phone kept an old date. Now the Users and Players pages show the last time the
-- person actually used the app: the latest of
--   • their last sign-in,
--   • their sign-in being renewed in the background (auth.sessions, updated about hourly while in use),
--   • the app reporting that it was opened (profiles.last_seen_at, via touch_last_seen()).
alter table public.profiles add column if not exists last_seen_at timestamptz;

create or replace function public.touch_last_seen()
returns void language sql security definer set search_path = public as $$
  update public.profiles set last_seen_at = now()
   where id = auth.uid() and (last_seen_at is null or last_seen_at < now() - interval '2 minutes');
$$;
revoke execute on function public.touch_last_seen() from public, anon;
grant execute on function public.touch_last_seen() to authenticated;

create or replace function public.account_meta()
returns table (user_id uuid, player_id text, avatar_path text, name text, last_sign_in_at timestamptz)
language sql stable security definer set search_path = public, auth as $$
  with linked as (
    select (d.data ->> 'linkedUserId')::uuid as uid, d.id as pid
      from public.docs d
     where d.collection = 'trainees' and coalesce(d.data ->> 'linkedUserId', '') ~ '^[0-9a-f-]{36}$'
  ), sess as (
    select s.user_id, max(greatest(s.updated_at, s.refreshed_at at time zone 'UTC')) as at from auth.sessions s group by s.user_id
  )
  select u.id, l.pid, p.avatar_path, public.display_name(u.id),
         nullif(greatest(coalesce(u.last_sign_in_at, '-infinity'), coalesce(p.last_seen_at, '-infinity'), coalesce(se.at, '-infinity')), '-infinity')
    from auth.users u
    left join public.profiles p on p.id = u.id
    left join linked l on l.uid = u.id
    left join sess se on se.user_id = u.id
   where public.is_sysadmin() or (l.pid is not null and public.can_see_player(l.pid));
$$;
