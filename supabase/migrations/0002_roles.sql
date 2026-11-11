-- Padel360 · migration 0002 · roles managed inside the app
-- Every account is a player unless it has a row here. A sys admin assigns
-- "coach" or "sysadmin" from the app's Users tab. The coach email list
-- (public.staff) is retired.

create table if not exists public.user_roles (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  role       text not null check (role in ('coach', 'sysadmin')),
  updated_at timestamptz not null default now(),
  updated_by uuid
);
alter table public.user_roles enable row level security;

-- Private settings, readable only by database functions (no policies = no client access).
create table if not exists public.app_settings (
  key   text primary key,
  value text not null
);
alter table public.app_settings enable row level security;

create or replace function public.my_role()
returns text language sql stable security definer set search_path = public as $$
  select coalesce((select role from public.user_roles where user_id = auth.uid()), 'player');
$$;

create or replace function public.is_sysadmin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.user_roles where user_id = auth.uid() and role = 'sysadmin');
$$;

-- Coaches and sys admins get the coach view (same name the app and docs rules already use).
create or replace function public.is_staff()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.user_roles where user_id = auth.uid() and role in ('coach', 'sysadmin'));
$$;

grant execute on function public.my_role(), public.is_sysadmin(), public.is_staff() to authenticated;

-- Sys admins can read the role table; nobody writes it directly.
drop policy if exists user_roles_read on public.user_roles;
create policy user_roles_read on public.user_roles for select to authenticated
  using (user_id = auth.uid() or public.is_sysadmin());

-- List every account with its role (sys admins only).
create or replace function public.list_users()
returns table (id uuid, email text, role text, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_sysadmin() then
    raise exception 'only a sys admin can list users' using errcode = '42501';
  end if;
  return query
    select p.id, p.email, coalesce(r.role, 'player'), p.created_at
      from public.profiles p left join public.user_roles r on r.user_id = p.id
     order by p.created_at;
end;
$$;

-- Change one account's role (sys admins only; a sys admin cannot change their own role,
-- so the system always keeps at least the person making changes).
create or replace function public.set_user_role(p_user uuid, p_role text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_sysadmin() then
    raise exception 'only a sys admin can change roles' using errcode = '42501';
  end if;
  if p_user = auth.uid() then
    raise exception 'you cannot change your own role' using errcode = '42501';
  end if;
  if p_role = 'player' then
    delete from public.user_roles where user_id = p_user;
  elsif p_role in ('coach', 'sysadmin') then
    insert into public.user_roles (user_id, role, updated_at, updated_by)
    values (p_user, p_role, now(), auth.uid())
    on conflict (user_id) do update set role = excluded.role, updated_at = now(), updated_by = auth.uid();
  else
    raise exception 'unknown role %', p_role using errcode = '22023';
  end if;
end;
$$;

grant execute on function public.list_users(), public.set_user_role(uuid, text) to authenticated;
revoke execute on function public.list_users(), public.set_user_role(uuid, text) from anon;

-- New accounts: keep the profile row, and make the configured owner email a sys admin.
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email) values (new.id, new.email)
  on conflict (id) do update set email = excluded.email;
  if exists (select 1 from public.app_settings
             where key = 'sysadmin_email' and lower(value) = lower(new.email)) then
    insert into public.user_roles (user_id, role) values (new.id, 'sysadmin')
    on conflict (user_id) do update set role = 'sysadmin';
  end if;
  return new;
end;
$$;

-- Retire the email list.
drop policy if exists staff_read on public.staff;
drop table if exists public.staff;
