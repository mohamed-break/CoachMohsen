-- Padel 360 · migration 0003 · app-wide theme chosen by a sys admin
-- Public settings everyone (signed in or not) may read, so the sign-in screen is themed too.
-- Only a sys admin can change them, through set_theme().

create table if not exists public.app_public_settings (
  key        text primary key,
  value      text not null,
  updated_at timestamptz not null default now(),
  updated_by uuid
);
alter table public.app_public_settings enable row level security;

drop policy if exists app_public_settings_read on public.app_public_settings;
create policy app_public_settings_read on public.app_public_settings
  for select to anon, authenticated using (true);

insert into public.app_public_settings (key, value) values ('theme', 'protour')
on conflict (key) do nothing;

create or replace function public.set_theme(p_theme text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_sysadmin() then
    raise exception 'only a sys admin can change the theme' using errcode = '42501';
  end if;
  if p_theme not in ('protour', 'glass', 'royale') then
    raise exception 'unknown theme %', p_theme using errcode = '22023';
  end if;
  insert into public.app_public_settings (key, value, updated_at, updated_by)
  values ('theme', p_theme, now(), auth.uid())
  on conflict (key) do update set value = excluded.value, updated_at = now(), updated_by = auth.uid();
end;
$$;

grant execute on function public.set_theme(text) to authenticated;
revoke execute on function public.set_theme(text) from anon;
