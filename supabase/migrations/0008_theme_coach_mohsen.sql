-- CoachMohsen · migration 0008 · add the "Coach Mohsen" look to the themes a sys admin can choose
create or replace function public.set_theme(p_theme text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_sysadmin() then
    raise exception 'only a sys admin can change the theme' using errcode = '42501';
  end if;
  if p_theme not in ('protour', 'glass', 'royale', 'mohsen') then
    raise exception 'unknown theme %', p_theme using errcode = '22023';
  end if;
  insert into public.app_public_settings (key, value, updated_at, updated_by)
  values ('theme', p_theme, now(), auth.uid())
  on conflict (key) do update set value = excluded.value, updated_at = now(), updated_by = auth.uid();
end;
$$;
grant execute on function public.set_theme(text) to authenticated;
revoke execute on function public.set_theme(text) from anon;
