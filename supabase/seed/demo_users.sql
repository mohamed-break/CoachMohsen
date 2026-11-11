-- Padel 360 · demo accounts in the "Padel Pro" club (one per role) with a little sample data.
-- Run by the deploy workflow only when the DEMO_PASSWORD secret is set:
--   psql "$DB_URL" -v pw="$DEMO_PASSWORD" -f supabase/seed/demo_users.sql
-- Safe to run again: accounts are updated (password reset to DEMO_PASSWORD), sample data is added once.
--   sysadmin@coachmohsen.dev   Sys admin
--   clubadmin@coachmohsen.dev  Club admin of Padel Pro
--   coach@coachmohsen.dev      Coach in Padel Pro
--   player@coachmohsen.dev     Player, coached by the demo coach
\set ON_ERROR_STOP 1
\o /dev/null
select set_config('demo.pw', :'pw', false);
\o

do $$
declare
  pw text := current_setting('demo.pw');
  acct record; v_id uuid;
  v_sys uuid; v_admin uuid; v_coach uuid; v_player uuid;
  v_venue text; v_sk1 text; v_sk2 text;
begin
  if length(coalesce(pw, '')) < 8 then raise exception 'DEMO_PASSWORD must be at least 8 characters'; end if;
  if not exists (select 1 from public.orgs where id = 'padelpro') then raise exception 'the freelance club is missing (migration 0005)'; end if;

  for acct in select * from (values ('sysadmin@coachmohsen.dev', 'Demo Sys Admin'), ('clubadmin@coachmohsen.dev', 'Demo Club Admin'),
                                    ('coach@coachmohsen.dev', 'Demo Coach'), ('player@coachmohsen.dev', 'Demo Player')) a(email, name) loop
    select id into v_id from auth.users where lower(email) = acct.email;
    if v_id is null then
      v_id := gen_random_uuid();
      insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                              raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                              confirmation_token, recovery_token, email_change_token_new, email_change)
      values ('00000000-0000-0000-0000-000000000000', v_id, 'authenticated', 'authenticated', acct.email,
              extensions.crypt(pw, extensions.gen_salt('bf')), now(),
              '{"provider":"email","providers":["email"]}'::jsonb, jsonb_build_object('full_name', acct.name), now(), now(), '', '', '', '');
      insert into auth.identities (provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
      values (v_id::text, v_id, jsonb_build_object('sub', v_id::text, 'email', acct.email, 'email_verified', true), 'email', now(), now(), now());
    else
      update auth.users set encrypted_password = extensions.crypt(pw, extensions.gen_salt('bf')),
             email_confirmed_at = coalesce(email_confirmed_at, now()), updated_at = now() where id = v_id;
    end if;
    insert into public.profiles (id, email, full_name) values (v_id, acct.email, acct.name)
    on conflict (id) do update set full_name = coalesce(public.profiles.full_name, excluded.full_name);
    case acct.email
      when 'sysadmin@coachmohsen.dev' then v_sys := v_id;
      when 'clubadmin@coachmohsen.dev' then v_admin := v_id;
      when 'coach@coachmohsen.dev' then v_coach := v_id;
      else v_player := v_id;
    end case;
  end loop;

  -- roles
  insert into public.user_roles (user_id, role) values (v_sys, 'sysadmin') on conflict (user_id) do update set role = 'sysadmin';
  insert into public.org_members (org_id, user_id, role) values ('padelpro', v_admin, 'club_admin'), ('padelpro', v_coach, 'coach') on conflict do nothing;

  -- the demo player's profile, coached by the demo coach
  insert into public.docs (collection, id, data) values ('trainees', 'demo-player',
    jsonb_build_object('id', 'demo-player', 'name', 'Demo Player', 'level', 3.5, 'hand', 'right', 'side', 'drive',
                       'startDate', to_char(current_date - 30, 'YYYY-MM-DD'), 'linkedUserId', v_player::text))
  on conflict (collection, id) do update set data = public.docs.data || jsonb_build_object('linkedUserId', v_player::text);
  insert into public.club_players (org_id, player_id) values ('padelpro', 'demo-player') on conflict do nothing;
  insert into public.enrollments (org_id, player_id, coach_id) values ('padelpro', 'demo-player', v_coach) on conflict do nothing;

  select data ->> 'name' into v_venue from public.docs where collection = 'venues' and club_id = 'padelpro'
   order by (data ->> 'isDefault')::boolean desc nulls last, id limit 1;
  select id into v_sk1 from public.docs where collection = 'skills' and club_id = 'padelpro' order by id limit 1;
  select id into v_sk2 from public.docs where collection = 'skills' and club_id = 'padelpro' and id <> coalesce(v_sk1, '') order by id limit 1;

  insert into public.docs (collection, id, data) values ('coachplayer', 'demo-player@' || v_coach::text,
    jsonb_build_object('id', 'demo-player@' || v_coach::text, 'playerId', 'demo-player', 'coachId', v_coach::text, 'clubId', 'padelpro',
      'showFeedback', true, 'goals', 'Consistent bandeja and better net positioning',
      'fixedSlots', jsonb_build_array(jsonb_build_object('id', 'demo-slot', 'day', 0, 'time', '19:00', 'duration', 60, 'location', coalesce(v_venue, ''), 'courtId', 'andalus-c4', 'courtName', 'Court 4'))))
  on conflict (collection, id) do nothing;

  -- three sample sessions with the demo coach (two done with ratings, one coming up)
  insert into public.docs (collection, id, data)
  select 'sessions', s.id, jsonb_build_object('id', s.id, 'clubId', 'padelpro', 'coachId', v_coach::text,
      'date', to_char(current_date + s.d, 'YYYY-MM-DD'), 'time', '19:00', 'duration', 60, 'status', s.st,
      'location', coalesce(v_venue, ''), 'courtId', 'andalus-c4', 'courtName', 'Court 4', 'focus', s.focus, 'traineeIds', jsonb_build_array('demo-player'),
      'activities', (select coalesce(jsonb_agg(x), '[]'::jsonb) from (values
         (case when v_sk1 is not null then jsonb_build_object('id', s.id || '-a1', 'skillId', v_sk1, 'title', 'Warm-up rally', 'minutes', 20) end),
         (case when v_sk2 is not null then jsonb_build_object('id', s.id || '-a2', 'skillId', v_sk2, 'title', 'Drill', 'minutes', 30) end)) v(x) where x is not null),
      'feedback', case when s.st = 'done' and v_sk1 is not null then jsonb_build_object('demo-player', jsonb_build_object(
         'overall', s.r, 'general', s.gen,
         'skills', jsonb_build_object(v_sk1, jsonb_build_object('rating', s.r, 'comment', 'Good rhythm'))
                   || case when v_sk2 is not null then jsonb_build_object(v_sk2, jsonb_build_object('rating', s.r - 1, 'comment', 'Keep the racket up')) else '{}'::jsonb end))
         else '{}'::jsonb end)
  from (values ('demo-s1', -7, 'done', 'Basics and footwork', 3, 'Solid start, keep working on footwork.'),
               ('demo-s2', -3, 'done', 'Net play', 4, 'Clear progress at the net.'),
               ('demo-s3', 4, 'planned', 'Overheads', 0, '')) s(id, d, st, focus, r, gen)
  where not exists (select 1 from public.docs x where x.collection = 'sessions' and x.id = s.id)
  on conflict (collection, id) do nothing;
end
$$;
