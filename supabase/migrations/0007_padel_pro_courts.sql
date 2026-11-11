-- CoachMohsen · migration 0007 · one club (Padel Pro), one venue (Padel Pro - Andalus) with 4 courts,
-- the 16 standard skills, and court booking: a court holds one session at a time, whoever the coach is.

-- 1. The single club. The built-in freelance club from 0005 is not used in this app.
insert into public.orgs (id, name, is_freelance) values ('padelpro', 'Padel Pro', false)
on conflict (id) do update set name = excluded.name;
update public.docs set data = data || '{"clubId":"padelpro"}'::jsonb where club_id = 'freelance';
insert into public.org_members (org_id, user_id, role)
  select 'padelpro', user_id, role from public.org_members where org_id = 'freelance' on conflict do nothing;
insert into public.club_players (org_id, player_id)
  select 'padelpro', player_id from public.club_players where org_id = 'freelance' on conflict do nothing;
insert into public.enrollments (org_id, player_id, coach_id)
  select 'padelpro', player_id, coach_id from public.enrollments where org_id = 'freelance' on conflict do nothing;
delete from public.orgs where id = 'freelance';

-- save_org copied skills from the freelance club; in this app new clubs copy them from Padel Pro.
create or replace function public.save_org(p_id text, p_name text, p_freelance boolean)
returns text language plpgsql security definer set search_path = public as $$
declare v_id text := coalesce(nullif(trim(p_id), ''), 'c' || substr(md5(random()::text || clock_timestamp()::text), 1, 10));
begin
  if not public.is_sysadmin() then raise exception 'only a sys admin can manage clubs' using errcode = '42501'; end if;
  if coalesce(trim(p_name), '') = '' then raise exception 'club name is required' using errcode = '22023'; end if;
  insert into public.orgs (id, name, is_freelance) values (v_id, trim(p_name), coalesce(p_freelance, false))
  on conflict (id) do update set name = excluded.name;
  insert into public.docs (collection, id, data)
    select 'skills', v_id || '-' || d.id, d.data || jsonb_build_object('id', v_id || '-' || d.id, 'clubId', v_id)
      from public.docs d where d.collection = 'skills' and d.club_id = 'padelpro' and v_id <> 'padelpro'
  on conflict (collection, id) do nothing;
  return v_id;
end;
$$;

-- 2. Venue and courts (court ids are unique across venues).
insert into public.docs (collection, id, data) values ('venues', 'andalus', jsonb_build_object(
  'id', 'andalus', 'name', 'Padel Pro - Andalus', 'isDefault', true, 'clubId', 'padelpro',
  'courts', jsonb_build_array(
    jsonb_build_object('id', 'andalus-c1', 'name', 'Court 1', 'name_ar', 'ملعب 1'),
    jsonb_build_object('id', 'andalus-c2', 'name', 'Court 2', 'name_ar', 'ملعب 2'),
    jsonb_build_object('id', 'andalus-c3', 'name', 'Court 3', 'name_ar', 'ملعب 3'),
    jsonb_build_object('id', 'andalus-c4', 'name', 'Court 4', 'name_ar', 'ملعب 4'))))
on conflict (collection, id) do nothing;

-- 3. The 16 standard skills.
insert into public.docs (collection, id, data)
select 'skills', s.id, jsonb_build_object('id', s.id, 'category', s.cat, 'name_en', s.en, 'name_ar', s.ar, 'clubId', 'padelpro')
from (values
  ('back-glass', 'walls', 'Back glass exit', 'الخروج من الزجاج الخلفي'),
  ('backhand', 'strokes', 'Backhand', 'الضربة الخلفية'),
  ('bandeja', 'overhead', 'Bandeja', 'البانديخا'),
  ('chiquita', 'strokes', 'Chiquita', 'التشيكيتا'),
  ('communication', 'tactics', 'Partner communication', 'التواصل مع الشريك'),
  ('footwork', 'tactics', 'Footwork', 'حركة القدمين'),
  ('forehand', 'strokes', 'Forehand', 'الضربة الأمامية'),
  ('lob', 'strokes', 'Lob', 'اللوب'),
  ('positioning', 'tactics', 'Positioning & transitions', 'التمركز والانتقال'),
  ('return', 'serve', 'Return of serve', 'استقبال الإرسال'),
  ('serve', 'serve', 'Serve', 'الإرسال'),
  ('side-glass', 'walls', 'Side glass / double wall', 'الزجاج الجانبي / الحائط المزدوج'),
  ('smash', 'overhead', 'Smash', 'السماش'),
  ('vibora', 'overhead', 'Víbora', 'الفيبورا'),
  ('volley-bh', 'net', 'Backhand volley', 'الفولي الخلفي'),
  ('volley-fh', 'net', 'Forehand volley', 'الفولي الأمامي')) s(id, cat, en, ar)
on conflict (collection, id) do nothing;

-- 4. Court booking. A session that is not cancelled and has a court needs a start time, and no other
-- such session may overlap it on the same court and day. Checked in the database so it holds across
-- coaches, who cannot see each other's sessions.
create or replace function public.session_minutes(p_time text)
returns integer language sql immutable as $$
  select case when p_time ~ '^\d{1,2}:\d{2}' then split_part(p_time, ':', 1)::int * 60 + split_part(p_time, ':', 2)::int end;
$$;
create or replace function public.session_length(p_duration text)
returns integer language sql immutable as $$
  select case when coalesce(p_duration, '') ~ '^\d+(\.\d+)?$' and p_duration::numeric > 0 then round(p_duration::numeric)::int else 60 end;
$$;

create or replace function public.check_court_free()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_court text := coalesce(new.data ->> 'courtId', ''); v_st int; v_en int; c record;
begin
  if new.collection <> 'sessions' or v_court = '' or coalesce(new.data ->> 'status', 'planned') = 'cancelled' then return new; end if;
  v_st := public.session_minutes(new.data ->> 'time');
  if v_st is null then raise exception 'COURT_NEEDS_TIME: a session on a court needs a start time' using errcode = 'P0001'; end if;
  v_en := v_st + public.session_length(new.data ->> 'duration');
  perform pg_advisory_xact_lock(hashtext('court:' || v_court || ':' || coalesce(new.data ->> 'date', '')));
  select d.data ->> 'time' as t, public.session_length(d.data ->> 'duration') as len into c
    from public.docs d
   where d.collection = 'sessions' and d.id <> new.id
     and d.data ->> 'courtId' = v_court and d.data ->> 'date' = new.data ->> 'date'
     and coalesce(d.data ->> 'status', 'planned') <> 'cancelled'
     and public.session_minutes(d.data ->> 'time') is not null
     and public.session_minutes(d.data ->> 'time') < v_en
     and public.session_minutes(d.data ->> 'time') + public.session_length(d.data ->> 'duration') > v_st
   limit 1;
  if found then
    raise exception 'COURT_BUSY: % is booked from % for % min', coalesce(new.data ->> 'courtName', v_court), c.t, c.len using errcode = 'P0001';
  end if;
  return new;
end;
$$;
drop trigger if exists docs_court on public.docs;
create trigger docs_court before insert or update on public.docs for each row execute function public.check_court_free();

-- Busy courts on a day, for the booking screen. Only times, never who booked them.
create or replace function public.court_busy(p_date text)
returns table (session_id text, court_id text, start_time text, duration integer, mine boolean)
language sql stable security definer set search_path = public as $$
  select d.id, d.data ->> 'courtId', d.data ->> 'time', public.session_length(d.data ->> 'duration'), d.coach_id = auth.uid()
    from public.docs d
   where public.is_staff() and d.collection = 'sessions' and d.data ->> 'date' = p_date
     and coalesce(d.data ->> 'courtId', '') <> '' and coalesce(d.data ->> 'status', 'planned') <> 'cancelled'
   order by 3;
$$;
grant execute on function public.court_busy(text), public.session_minutes(text), public.session_length(text) to authenticated;
revoke execute on function public.court_busy(text) from anon, public;

-- 5. Players see the court as part of the place.
create or replace function public.player_360()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_pid text; v_p jsonb; res jsonb;
begin
  select id, data into v_pid, v_p from public.docs where collection = 'trainees' and data ->> 'linkedUserId' = auth.uid()::text limit 1;
  if v_pid is null then return null; end if;
  with cp as (
    select coach_id, coalesce((data ->> 'showFeedback')::boolean, false) as show, coalesce(data -> 'fixedSlots', '[]'::jsonb) as slots
      from public.docs where collection = 'coachplayer' and data ->> 'playerId' = v_pid
  ), sk as (
    select id, data from public.docs where collection = 'skills'
  ), ss as (
    select s.id, s.data, s.coach_id, s.club_id, coalesce(cp.show, false) as show,
           coalesce(s.data -> 'excused', '[]'::jsonb) ? v_pid as excused,
           s.data -> 'feedback' -> v_pid as fb
      from public.docs s left join cp on cp.coach_id = s.coach_id
     where s.collection = 'sessions' and s.data -> 'traineeIds' ? v_pid
  )
  select jsonb_build_object(
    'traineeName', v_p ->> 'name', 'level', v_p -> 'level', 'playerId', v_pid,
    'fixedSlots', coalesce((select jsonb_agg(sl || jsonb_build_object('coachName', public.display_name(cp.coach_id)))
                            from cp, jsonb_array_elements(cp.slots) sl), '[]'::jsonb),
    'history', coalesce((select jsonb_agg(h order by h ->> 'date' desc, h ->> 'time' desc) from (
      select jsonb_build_object(
        'id', ss.id, 'date', ss.data ->> 'date', 'time', coalesce(ss.data ->> 'time', ''),
        'duration', ss.data -> 'duration', 'location', concat_ws(' · ', nullif(ss.data ->> 'location', ''), nullif(ss.data ->> 'courtName', '')),
        'status', case when ss.excused then 'cancelled' else coalesce(ss.data ->> 'status', 'planned') end,
        'focus', coalesce(ss.data ->> 'focus', ''),
        'size', greatest(1, (select count(*) from jsonb_array_elements_text(ss.data -> 'traineeIds') t
                              where not (coalesce(ss.data -> 'excused', '[]'::jsonb) ? t))),
        'coachName', public.display_name(ss.coach_id),
        'clubName', (select name from public.orgs where id = ss.club_id),
        'showFeedback', ss.show,
        'cancelReason', case when ss.data ->> 'status' = 'cancelled' then coalesce(ss.data ->> 'cancelReason', '') else '' end,
        'activities', coalesce((select jsonb_agg(jsonb_build_object('title', coalesce(a ->> 'title', ''), 'minutes', a -> 'minutes',
                          'skillId', coalesce(a ->> 'skillId', ''), 'name_en', coalesce(sk.data ->> 'name_en', ''), 'name_ar', coalesce(sk.data ->> 'name_ar', '')))
                        from jsonb_array_elements(coalesce(ss.data -> 'activities', '[]'::jsonb)) a left join sk on sk.id = a ->> 'skillId'), '[]'::jsonb),
        'items', coalesce((select jsonb_agg(jsonb_build_object('skillId', e.key,
                          'name_en', coalesce(sk.data ->> 'name_en', ''), 'name_ar', coalesce(sk.data ->> 'name_ar', ''),
                          'rating', coalesce((e.value ->> 'rating')::int, 0),
                          'comment', case when ss.show then coalesce(e.value ->> 'comment', '') else '' end))
                        from jsonb_each(coalesce(ss.fb -> 'skills', '{}'::jsonb)) e left join sk on sk.id = e.key
                        where coalesce((e.value ->> 'rating')::int, 0) > 0 or (ss.show and coalesce(e.value ->> 'comment', '') <> '')), '[]'::jsonb),
        'general', case when ss.show then coalesce(ss.fb ->> 'general', '') else '' end,
        'overall', case when ss.show then coalesce((ss.fb ->> 'overall')::int, 0) else 0 end
      ) as h from ss) x), '[]'::jsonb)
  ) into res;
  return res;
end;
$$;
