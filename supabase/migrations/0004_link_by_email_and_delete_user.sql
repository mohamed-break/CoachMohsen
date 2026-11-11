-- Padel 360 · migration 0004 · link a trainee by account email; sys admins delete accounts

-- Coaches and sys admins look up an account id by its sign-in email (exact match, case-insensitive).
create or replace function public.find_user_by_email(p_email text)
returns uuid language plpgsql stable security definer set search_path = public as $$
declare v uuid;
begin
  if not public.is_staff() then
    raise exception 'only coaches can look up accounts' using errcode = '42501';
  end if;
  select id into v from public.profiles where lower(email) = lower(trim(p_email)) limit 1;
  return v;
end;
$$;
grant execute on function public.find_user_by_email(text) to authenticated;
revoke execute on function public.find_user_by_email(text) from anon;

-- Sys admins delete an account. Any trainee profile linked to it is unlinked first, and the
-- account's player data (progress, requests, claims) is removed. A person who signs up again
-- with the same email gets a brand-new account id, so the old trainee link never comes back.
create or replace function public.delete_user(p_user uuid)
returns integer language plpgsql security definer set search_path = public, auth as $$
declare unlinked integer;
begin
  if not public.is_sysadmin() then
    raise exception 'only a sys admin can delete accounts' using errcode = '42501';
  end if;
  if p_user = auth.uid() then
    raise exception 'you cannot delete your own account' using errcode = '42501';
  end if;

  update public.docs
     set data = jsonb_set(data, '{linkedUserId}', '""'::jsonb), updated_at = now()
   where collection = 'trainees' and data ->> 'linkedUserId' = p_user::text;
  get diagnostics unlinked = row_count;

  delete from public.docs where collection in ('progress', 'requests', 'claims') and id = p_user::text;
  delete from public.user_roles where user_id = p_user;
  delete from public.profiles where id = p_user;
  delete from auth.users where id = p_user;
  return unlinked;
end;
$$;
grant execute on function public.delete_user(uuid) to authenticated;
revoke execute on function public.delete_user(uuid) from anon;
