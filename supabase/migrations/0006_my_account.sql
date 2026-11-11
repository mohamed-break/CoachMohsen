-- Padel 360 · migration 0006 · people manage their own account: photo, name, display name, phone, email

alter table public.profiles add column if not exists display_name text;
alter table public.profiles add column if not exists phone        text;
alter table public.profiles add column if not exists avatar_path  text;

-- The name shown around the app: display name, else full name, else the start of the email.
create or replace function public.display_name(p_user uuid)
returns text language sql stable security definer set search_path = public as $$
  select coalesce(nullif(trim(p.display_name), ''), nullif(trim(p.full_name), ''), split_part(p.email, '@', 1), '')
    from public.profiles p where p.id = p_user;
$$;

-- Save my own name, display name and phone. A player's shared profile follows their account.
create or replace function public.update_my_profile(p_full_name text, p_display_name text, p_phone text)
returns void language plpgsql security definer set search_path = public as $$
declare v_phone text := nullif(trim(coalesce(p_phone, '')), '');
begin
  if auth.uid() is null then raise exception 'sign in first' using errcode = '42501'; end if;
  if length(coalesce(p_full_name, '')) > 120 or length(coalesce(p_display_name, '')) > 60 then
    raise exception 'name is too long' using errcode = '22023';
  end if;
  if v_phone is not null and v_phone !~ '^\+?[0-9 ()-]{6,20}$' then
    raise exception 'phone number: use digits, spaces, dashes and an optional leading +' using errcode = '22023';
  end if;
  update public.profiles
     set full_name = nullif(trim(coalesce(p_full_name, '')), ''),
         display_name = nullif(trim(coalesce(p_display_name, '')), ''),
         phone = v_phone
   where id = auth.uid();
  update public.docs
     set data = data || jsonb_strip_nulls(jsonb_build_object(
                  'name', coalesce(nullif(trim(coalesce(p_display_name, '')), ''), nullif(trim(coalesce(p_full_name, '')), '')),
                  'phone', v_phone)),
         updated_at = now()
   where collection = 'trainees' and data ->> 'linkedUserId' = auth.uid()::text;
end;
$$;

-- Set or clear my photo. Only a file in my own folder of the avatars store is accepted.
create or replace function public.set_my_avatar(p_path text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'sign in first' using errcode = '42501'; end if;
  if p_path is not null and p_path <> '' and split_part(p_path, '/', 1) <> auth.uid()::text then
    raise exception 'not your photo' using errcode = '42501';
  end if;
  update public.profiles set avatar_path = nullif(p_path, '') where id = auth.uid();
end;
$$;

grant execute on function public.update_my_profile(text, text, text), public.set_my_avatar(text) to authenticated;
revoke execute on function public.update_my_profile(text, text, text), public.set_my_avatar(text) from anon, public;

-- Club admins and coaches see their people's photos and display names.
drop function if exists public.club_people(text);
create or replace function public.club_people(p_org text)
returns table (user_id uuid, email text, name text, role text, avatar_path text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_club_admin(p_org) and not public.is_member(p_org) then
    raise exception 'not a member of this club' using errcode = '42501';
  end if;
  return query select m.user_id, p.email, public.display_name(m.user_id), m.role, p.avatar_path
    from public.org_members m join public.profiles p on p.id = m.user_id
   where m.org_id = p_org and (public.is_club_admin(p_org) or m.role = 'coach') order by 3;
end;
$$;
grant execute on function public.club_people(text) to authenticated;
revoke execute on function public.club_people(text) from anon, public;

-- When someone confirms a new email address, their profile follows.
create or replace function public.handle_user_email_change()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.profiles set email = new.email where id = new.id;
  return new;
end;
$$;
drop trigger if exists on_auth_user_email_changed on auth.users;
create trigger on_auth_user_email_changed after update of email on auth.users
  for each row when (old.email is distinct from new.email) execute function public.handle_user_email_change();

-- Photo store: public to view (paths are random), each person writes only their own folder; 2 MB images.
do $$
begin
  if not exists (select 1 from information_schema.schemata where schema_name = 'storage') then return; end if;
  insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
  values ('avatars', 'avatars', true, 2097152, array['image/jpeg', 'image/png', 'image/webp'])
  on conflict (id) do update set public = true, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;
  execute 'drop policy if exists avatars_select_own on storage.objects';
  execute 'drop policy if exists avatars_insert_own on storage.objects';
  execute 'drop policy if exists avatars_update_own on storage.objects';
  execute 'drop policy if exists avatars_delete_own on storage.objects';
  execute $p$create policy avatars_select_own on storage.objects for select to authenticated
    using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text)$p$;
  execute $p$create policy avatars_insert_own on storage.objects for insert to authenticated
    with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text)$p$;
  execute $p$create policy avatars_update_own on storage.objects for update to authenticated
    using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text)
    with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text)$p$;
  execute $p$create policy avatars_delete_own on storage.objects for delete to authenticated
    using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text)$p$;
end
$$;
