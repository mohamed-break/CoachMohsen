-- CoachMohsen · migration 0009 · sys admins and club admins create a player in one step: the player profile, the club, the coaches,
-- and (when an email is given) a ready sign-in account linked to the profile. The player then signs in
-- with Google using that email, or sets a password with "Forgot password".
create or replace function public.admin_create_player(p_org text, p_name text, p_email text, p_phone text,
                                                      p_level numeric, p_coaches uuid[])
returns jsonb language plpgsql security definer set search_path = public, auth, extensions as $$
declare
  v_email text := nullif(lower(trim(coalesce(p_email, ''))), '');
  v_name text := nullif(trim(coalesce(p_name, '')), '');
  v_phone text := nullif(trim(coalesce(p_phone, '')), '');
  v_uid uuid; v_new_account boolean := false; v_pid text; c uuid;
begin
  if not public.is_club_admin(p_org) then raise exception 'only a club admin or sys admin can add players' using errcode = '42501'; end if;
  if not exists (select 1 from public.orgs where id = p_org) then raise exception 'unknown club' using errcode = '22023'; end if;
  if v_name is null then raise exception 'name is required' using errcode = '22023'; end if;
  if v_email is not null and v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'that email does not look right' using errcode = '22023'; end if;
  if v_phone is not null and v_phone !~ '^\+?[0-9 ()-]{6,20}$' then raise exception 'phone number: use digits, spaces, dashes and an optional leading +' using errcode = '22023'; end if;

  if v_email is not null then
    select id into v_uid from auth.users where lower(email) = v_email;
    if v_uid is null then
      v_uid := gen_random_uuid(); v_new_account := true;
      insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
                              created_at, updated_at, confirmation_token, recovery_token, email_change_token_new, email_change)
      values ('00000000-0000-0000-0000-000000000000', v_uid, 'authenticated', 'authenticated', v_email, now(),
              '{"provider":"email","providers":["email"]}'::jsonb, jsonb_build_object('full_name', v_name), now(), now(), '', '', '', '');
      insert into auth.identities (provider_id, user_id, identity_data, provider, created_at, updated_at)
      values (v_uid::text, v_uid, jsonb_build_object('sub', v_uid::text, 'email', v_email, 'email_verified', true), 'email', now(), now());
    end if;
    insert into public.profiles (id, email, full_name, phone) values (v_uid, v_email, v_name, v_phone)
    on conflict (id) do update set full_name = coalesce(public.profiles.full_name, excluded.full_name),
                                   phone = coalesce(public.profiles.phone, excluded.phone);
    select id into v_pid from public.docs where collection = 'trainees' and data ->> 'linkedUserId' = v_uid::text limit 1;
  end if;

  if v_pid is null then
    v_pid := 'p' || substr(md5(random()::text || clock_timestamp()::text), 1, 12);
    insert into public.docs (collection, id, data) values ('trainees', v_pid, jsonb_strip_nulls(jsonb_build_object(
      'id', v_pid, 'name', v_name, 'phone', v_phone, 'level', p_level, 'startDate', to_char(current_date, 'YYYY-MM-DD'),
      'linkedUserId', coalesce(v_uid::text, ''))));
  end if;

  insert into public.club_players (org_id, player_id) values (p_org, v_pid) on conflict do nothing;
  foreach c in array coalesce(p_coaches, '{}') loop
    if exists (select 1 from public.org_members where org_id = p_org and user_id = c and role = 'coach') then
      insert into public.enrollments (org_id, player_id, coach_id) values (p_org, v_pid, c) on conflict do nothing;
    end if;
  end loop;
  return jsonb_build_object('playerId', v_pid, 'userId', v_uid, 'newAccount', v_new_account);
end;
$$;
grant execute on function public.admin_create_player(text, text, text, text, numeric, uuid[]) to authenticated;
revoke execute on function public.admin_create_player(text, text, text, text, numeric, uuid[]) from anon, public;
