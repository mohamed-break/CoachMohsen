-- System settings (sys admins) and automatic player registration.
--   • app_settings 'default_club': the platform's default club. Every new account is registered as a player
--     in that club right after signing up (named from the account, Google name when there is one).
--   • Club setting defaultCoach: the coach new players of that club are assigned to, so they appear on
--     that coach's list straight away (and the coach gets a notification).
------------------------------------------------------------------------------------------
create or replace function public.system_settings()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_sysadmin() then raise exception 'Only sys admins can see system settings' using errcode = '42501'; end if;
  return jsonb_build_object('defaultClub', (select value from public.app_settings where key = 'default_club'));
end;
$$;

create or replace function public.set_system_settings(p_settings jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v text;
begin
  if not public.is_sysadmin() then raise exception 'Only sys admins can change system settings' using errcode = '42501'; end if;
  if p_settings ? 'defaultClub' then
    v := nullif(trim(coalesce(p_settings ->> 'defaultClub', '')), '');
    if v is null then
      delete from public.app_settings where key = 'default_club';
    else
      if not exists (select 1 from public.orgs where id = v) then raise exception 'Unknown club' using errcode = '22023'; end if;
      insert into public.app_settings (key, value) values ('default_club', v) on conflict (key) do update set value = excluded.value;
    end if;
  end if;
  return public.system_settings();
end;
$$;

-- Club settings: suggestPlanned (on/off) and defaultCoach (a coach of the club, or empty)
create or replace function public.set_club_settings(p_org text, p_settings jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare clean jsonb := '{}'::jsonb; res jsonb; dc text;
begin
  if not (public.is_sysadmin() or public.is_club_admin(p_org)) then
    raise exception 'Only club admins can change club settings' using errcode = '42501';
  end if;
  if jsonb_typeof(p_settings -> 'suggestPlanned') = 'boolean' then clean := clean || jsonb_build_object('suggestPlanned', p_settings -> 'suggestPlanned'); end if;
  if p_settings ? 'defaultCoach' then
    dc := nullif(trim(coalesce(p_settings ->> 'defaultCoach', '')), '');
    if dc is not null and not exists (select 1 from public.org_members where org_id = p_org and user_id::text = dc and role = 'coach') then
      raise exception 'The default coach must be a coach of this club' using errcode = '22023';
    end if;
  end if;
  update public.orgs set settings = case when p_settings ? 'defaultCoach'
           then (coalesce(settings, '{}'::jsonb) || clean) - 'defaultCoach' || case when dc is null then '{}'::jsonb else jsonb_build_object('defaultCoach', dc) end
           else coalesce(settings, '{}'::jsonb) || clean end
   where id = p_org returning settings into res;
  if res is null then raise exception 'Club not found' using errcode = 'P0002'; end if;
  return res;
end;
$$;

-- A coach who leaves the club stops being its default coach
create or replace function public.clear_default_coach()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if old.role = 'coach' then
    update public.orgs set settings = settings - 'defaultCoach' where id = old.org_id and settings ->> 'defaultCoach' = old.user_id::text;
  end if;
  return null;
end;
$$;
drop trigger if exists org_members_clear_default_coach on public.org_members;
create trigger org_members_clear_default_coach after delete on public.org_members for each row execute function public.clear_default_coach();

------------------------------------------------------------------------------------------
-- New account → player of the default club (with its default coach)
------------------------------------------------------------------------------------------
create or replace function public.auto_register_player(p_user uuid)
returns text language plpgsql security definer set search_path = public as $$
declare v_org text; v_coach uuid; v_pid text; v_name text; v_email text;
begin
  select value into v_org from public.app_settings where key = 'default_club';
  if v_org is null or not exists (select 1 from public.orgs where id = v_org) then return null; end if;
  select email into v_email from auth.users where id = p_user;
  -- the platform owner's own account is not a player
  if exists (select 1 from public.app_settings where key = 'sysadmin_email' and lower(value) = lower(coalesce(v_email, ''))) then return null; end if;
  select id into v_pid from public.docs where collection = 'trainees' and data ->> 'linkedUserId' = p_user::text limit 1;
  if v_pid is null then
    v_name := public.account_name(p_user);
    v_pid := 'p' || substr(md5(random()::text || clock_timestamp()::text), 1, 12);
    insert into public.docs (collection, id, data) values ('trainees', v_pid, jsonb_strip_nulls(jsonb_build_object(
      'id', v_pid, 'name', v_name, 'phone', (select phone from public.profiles where id = p_user),
      'startDate', to_char(current_date, 'YYYY-MM-DD'), 'linkedUserId', p_user::text, 'autoRegistered', true)));
  end if;
  insert into public.club_players (org_id, player_id) values (v_org, v_pid) on conflict do nothing;
  select case when settings ->> 'defaultCoach' ~* '^[0-9a-f-]{36}$' then (settings ->> 'defaultCoach')::uuid end into v_coach from public.orgs where id = v_org;
  if v_coach is not null and exists (select 1 from public.org_members where org_id = v_org and user_id = v_coach and role = 'coach') then
    insert into public.enrollments (org_id, player_id, coach_id) values (v_org, v_pid, v_coach) on conflict do nothing;
    perform set_config('notif.ctx', jsonb_build_object('org', v_org, 'coach', v_coach, 'players', jsonb_build_array(v_pid))::text, true);
    perform public.notify(v_coach, 'player_joined', 'trainee-' || v_pid,
      'New player signed up', public.player_name(v_pid) || ' · ' || coalesce((select name from public.orgs where id = v_org), ''),
      'لاعب جديد سجّل في المنصة', public.player_name(v_pid) || ' · ' || coalesce((select name from public.orgs where id = v_org), ''));
  end if;
  return v_pid;
end;
$$;
revoke execute on function public.auto_register_player(uuid) from public, anon, authenticated;

create or replace function public.profiles_auto_player()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  begin
    perform public.auto_register_player(new.id);
  exception when others then
    raise warning 'auto player registration skipped for %: %', new.id, sqlerrm;  -- never block a sign-up
  end;
  return null;
end;
$$;
drop trigger if exists profiles_auto_player on public.profiles;
create trigger profiles_auto_player after insert on public.profiles for each row execute function public.profiles_auto_player();

revoke execute on function public.system_settings(), public.set_system_settings(jsonb) from public, anon;
grant execute on function public.system_settings(), public.set_system_settings(jsonb) to authenticated;
