-- Notifications: an in-app list for every account, plus phone/computer (web push) alerts.
--   • public.notifications    – one row per message, in English and Arabic; each person reads only their own
--   • public.push_subscriptions – the devices a person switched alerts on for
--   • triggers below write the messages when sessions, requests, players, coaches and accounts change
--   • send_reminders() runs every 15 minutes (pg_cron): reminders 1 day and 2 hours before a session,
--     and a 7:00 (Riyadh) summary of the day for each coach
--   • push_kick() hands new messages to the site's /api/push function (pg_net), which delivers them
------------------------------------------------------------------------------------------

create table if not exists public.notifications (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references auth.users(id) on delete cascade,
  kind       text not null,
  title_en   text not null,
  body_en    text not null default '',
  title_ar   text not null,
  body_ar    text not null default '',
  link       text not null default '',
  created_at timestamptz not null default now(),
  read_at    timestamptz,
  pushed_at  timestamptz
);
create index if not exists notifications_user_idx on public.notifications (user_id, id desc);
create index if not exists notifications_unpushed_idx on public.notifications (id) where pushed_at is null;
alter table public.notifications enable row level security;
drop policy if exists notifications_own on public.notifications;
create policy notifications_own on public.notifications for select to authenticated using (user_id = auth.uid());
revoke insert, update, delete on public.notifications from anon, authenticated;
grant select on public.notifications to authenticated;

create table if not exists public.push_subscriptions (
  endpoint   text primary key,
  user_id    uuid not null references auth.users(id) on delete cascade,
  p256dh     text not null,
  auth       text not null,
  created_at timestamptz not null default now()
);
create index if not exists push_subscriptions_user_idx on public.push_subscriptions (user_id);
alter table public.push_subscriptions enable row level security;
drop policy if exists push_subscriptions_own on public.push_subscriptions;
create policy push_subscriptions_own on public.push_subscriptions for select to authenticated using (user_id = auth.uid());
revoke insert, update, delete on public.push_subscriptions from anon, authenticated;

alter table public.profiles add column if not exists notif_prefs jsonb not null default '{}'::jsonb;
alter table public.profiles add column if not exists lang text;

-- Settings only the database itself reads (never exposed through the API).
create schema if not exists private;
revoke all on schema private from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then execute 'revoke all on schema private from anon, authenticated'; end if;
end $$;
create table if not exists private.push_config (
  id            int primary key default 1 check (id = 1),
  secret        text not null default encode(extensions.gen_random_bytes(24), 'hex'),
  fn_url        text,
  api_url       text,
  api_key       text,
  vapid_public  text,
  vapid_private text,
  subject       text
);
insert into private.push_config (id) values (1) on conflict do nothing;
create table if not exists private.notif_sent (key text primary key, at timestamptz not null default now());

-- Live updates for the bell.
do $$ begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'notifications') then
    execute 'alter publication supabase_realtime add table public.notifications';
  end if;
end $$;

------------------------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------------------------
create or replace function public.notify(p_user uuid, p_kind text, p_link text, p_title_en text, p_body_en text, p_title_ar text, p_body_ar text)
returns void language plpgsql security definer set search_path = public as $$
declare prefs jsonb;
begin
  if p_user is null then return; end if;
  if not exists (select 1 from auth.users where id = p_user) then return; end if;
  select coalesce(notif_prefs, '{}'::jsonb) into prefs from public.profiles where id = p_user;
  prefs := coalesce(prefs, '{}'::jsonb);
  if p_kind in ('reminder', 'summary') and prefs ->> 'reminders' = 'false' then return; end if;
  if p_kind = 'feedback' and prefs ->> 'feedback' = 'false' then return; end if;
  insert into public.notifications (user_id, kind, link, title_en, body_en, title_ar, body_ar)
  values (p_user, p_kind, coalesce(p_link, ''), p_title_en, coalesce(p_body_en, ''), p_title_ar, coalesce(p_body_ar, ''));
end;
$$;

-- "once only" guard for reminders, feedback and summaries
create or replace function public.notif_once(p_key text)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  insert into private.notif_sent (key) values (p_key);
  return true;
exception when unique_violation then return false;
end;
$$;

create or replace function public.player_uid(p_player text)
returns uuid language sql stable security definer set search_path = public as $$
  select case when d.data ->> 'linkedUserId' ~* '^[0-9a-f-]{36}$' then (d.data ->> 'linkedUserId')::uuid end
    from public.docs d where d.collection = 'trainees' and d.id = p_player;
$$;
create or replace function public.player_name(p_player text)
returns text language sql stable security definer set search_path = public as $$
  select coalesce((select nullif(data ->> 'name', '') from public.docs where collection = 'trainees' and id = p_player), '—');
$$;
create or replace function public.notif_person(p_user uuid)
returns text language plpgsql stable security definer set search_path = public as $$
declare n text;
begin
  begin n := public.display_name(p_user); exception when others then n := null; end;
  return coalesce(nullif(n, ''), (select email from public.profiles where id = p_user), '—');
end;
$$;

-- When a session starts, as a real moment (dates and times are entered in Saudi time).
create or replace function public.session_at(d jsonb)
returns timestamptz language plpgsql stable as $$
begin
  if coalesce(d ->> 'date', '') !~ '^\d{4}-\d{2}-\d{2}$' then return null; end if;
  return ((d ->> 'date') || ' ' || case when coalesce(d ->> 'time', '') ~ '^\d{1,2}:\d{2}' then d ->> 'time' else '00:00' end)::timestamp
         at time zone 'Asia/Riyadh';
exception when others then return null;
end;
$$;

create or replace function public.notif_when(d jsonb, p_lang text)
returns text language plpgsql stable as $$
declare dt date; tm text := coalesce(nullif(d ->> 'time', ''), '');
  ar_days text[] := array['الأحد','الاثنين','الثلاثاء','الأربعاء','الخميس','الجمعة','السبت'];
begin
  if coalesce(d ->> 'date', '') !~ '^\d{4}-\d{2}-\d{2}$' then return tm; end if;
  dt := (d ->> 'date')::date;
  if p_lang = 'ar' then return trim(ar_days[extract(dow from dt)::int + 1] || ' ' || to_char(dt, 'DD/MM') || ' · ' || tm, ' ·'); end if;
  return trim(to_char(dt, 'Dy DD Mon') || ' · ' || tm, ' ·');
exception when others then return coalesce(d ->> 'date', '');
end;
$$;

-- "Venue · Court 2" (venue names are stored on the session; court names come from the venue)
create or replace function public.notif_place(d jsonb, p_lang text)
returns text language sql stable security definer set search_path = public as $$
  select nullif(concat_ws(' · ', nullif(d ->> 'location', ''),
    (select nullif(case when p_lang = 'ar' then coalesce(nullif(c ->> 'name_ar', ''), c ->> 'name') else c ->> 'name' end, '')
       from public.docs v, jsonb_array_elements(coalesce(v.data -> 'courts', '[]'::jsonb)) c
      where v.collection = 'venues' and v.data ->> 'name' = d ->> 'location' and c ->> 'id' = d ->> 'courtId' limit 1)), '');
$$;

create or replace function public.notif_session_line(d jsonb, p_lang text)
returns text language sql stable as $$
  select concat_ws(' · ', nullif(public.notif_when(d, p_lang), ''), public.notif_place(d, p_lang));
$$;

------------------------------------------------------------------------------------------
-- Sessions: booked, changed, cancelled, feedback
------------------------------------------------------------------------------------------
create or replace function public.notif_sessions()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  actor uuid := auth.uid();
  n jsonb; o jsonb; sid text; coach uuid; pid text; u uuid; cname text;
  active_new text[]; ids_old text[]; fut boolean;
begin
  if TG_OP = 'DELETE' then
    if old.collection <> 'sessions' then return null; end if;
  elsif new.collection <> 'sessions' then return null; end if;

  n := case when TG_OP <> 'DELETE' then new.data end;
  o := case when TG_OP <> 'INSERT' then old.data end;
  sid := coalesce(new.id, old.id);
  coach := coalesce(case when TG_OP <> 'DELETE' then new.coach_id end, old.coach_id);
  cname := public.notif_person(coach);

  -- removed: a planned future session is gone → tell its players
  if TG_OP = 'DELETE' then
    if coalesce(o ->> 'status', 'planned') = 'planned' and public.session_at(o) > now() then
      for pid in select jsonb_array_elements_text(coalesce(o -> 'traineeIds', '[]')) except select jsonb_array_elements_text(coalesce(o -> 'excused', '[]')) loop
        u := public.player_uid(pid);
        if u is not null and u is distinct from actor then
          perform public.notify(u, 'cancelled', '', 'Session cancelled', cname || ' · ' || public.notif_session_line(o, 'en'),
                                'تم إلغاء الحصة', cname || ' · ' || public.notif_session_line(o, 'ar'));
        end if;
      end loop;
    end if;
    return null;
  end if;

  fut := public.session_at(n) > now();
  select array_agg(x) into active_new from (
    select jsonb_array_elements_text(coalesce(n -> 'traineeIds', '[]')) x
    except select jsonb_array_elements_text(coalesce(n -> 'excused', '[]'))) t;
  active_new := coalesce(active_new, '{}');
  ids_old := coalesce((select array_agg(x) from jsonb_array_elements_text(coalesce(o -> 'traineeIds', '[]')) x), '{}');

  if coalesce(n ->> 'status', 'planned') = 'planned' and fut then
    -- booked: new session, or players added to it
    foreach pid in array active_new loop
      continue when TG_OP = 'UPDATE' and pid = any(ids_old);
      u := public.player_uid(pid);
      if u is not null and u is distinct from actor then
        perform public.notify(u, 'booked', '', 'New session booked', cname || ' · ' || public.notif_session_line(n, 'en'),
                              'تم حجز حصة جديدة', cname || ' · ' || public.notif_session_line(n, 'ar'));
      end if;
    end loop;
    -- booked for the coach by a club admin
    if TG_OP = 'INSERT' and coach is not null and actor is not null and actor <> coach then
      perform public.notify(coach, 'booked_for_coach', 'session-' || sid,
        'A session was booked for you', public.notif_person(actor) || ' · ' || public.notif_session_line(n, 'en'),
        'تم حجز حصة لك', public.notif_person(actor) || ' · ' || public.notif_session_line(n, 'ar'));
    end if;
    -- changed: date, time, venue or court
    if TG_OP = 'UPDATE' and coalesce(o ->> 'status', 'planned') = 'planned'
       and (n ->> 'date', n ->> 'time', n ->> 'location', n ->> 'courtId') is distinct from (o ->> 'date', o ->> 'time', o ->> 'location', o ->> 'courtId') then
      foreach pid in array active_new loop
        continue when not pid = any(ids_old);
        u := public.player_uid(pid);
        if u is not null and u is distinct from actor then
          perform public.notify(u, 'changed', '', 'Session changed', cname || ' · ' || public.notif_session_line(n, 'en'),
                                'تم تعديل الحصة', cname || ' · ' || public.notif_session_line(n, 'ar'));
        end if;
      end loop;
    end if;
  end if;

  -- cancelled by the coach (players whose own request was approved already know)
  if TG_OP = 'UPDATE' and n ->> 'status' = 'cancelled' and coalesce(o ->> 'status', 'planned') <> 'cancelled' and fut then
    foreach pid in array active_new loop
      u := public.player_uid(pid);
      continue when u is null or u is not distinct from actor;
      continue when exists (select 1 from public.docs where collection = 'requests' and id = sid || ':' || u::text and data ->> 'status' = 'approved');
      perform public.notify(u, 'cancelled', '', 'Session cancelled', cname || ' · ' || public.notif_session_line(n, 'en'),
                            'تم إلغاء الحصة', cname || ' · ' || public.notif_session_line(n, 'ar'));
    end loop;
  end if;

  -- feedback: once per session and player, only where this coach shows feedback to the player
  if jsonb_typeof(n -> 'feedback') = 'object' then
    for pid in select k from jsonb_object_keys(n -> 'feedback') k loop
      continue when n -> 'feedback' -> pid is null or n -> 'feedback' -> pid in ('{}'::jsonb, 'null'::jsonb);
      continue when (o -> 'feedback' -> pid) is not distinct from (n -> 'feedback' -> pid);
      continue when not exists (select 1 from public.docs where collection = 'coachplayer' and coach_id = coach
                                  and data ->> 'playerId' = pid and coalesce((data ->> 'showFeedback')::boolean, false));
      u := public.player_uid(pid);
      continue when u is null or u is not distinct from actor;
      continue when not public.notif_once('fb:' || sid || ':' || pid);
      perform public.notify(u, 'feedback', '', 'New feedback from ' || cname, public.notif_when(n, 'en'),
                            'تقييم جديد من ' || cname, public.notif_when(n, 'ar'));
    end loop;
  end if;
  return null;
end;
$$;
drop trigger if exists docs_notify_sessions on public.docs;
create trigger docs_notify_sessions after insert or update or delete on public.docs
  for each row execute function public.notif_sessions();

------------------------------------------------------------------------------------------
-- Cancellation requests
------------------------------------------------------------------------------------------
create or replace function public.notif_requests()
returns trigger language plpgsql security definer set search_path = public as $$
declare n jsonb; o jsonb; coach uuid; pname text; u uuid; sd jsonb; reason text;
begin
  if TG_OP = 'DELETE' then
    if old.collection <> 'requests' then return null; end if;
  elsif new.collection <> 'requests' then return null; end if;
  n := case when TG_OP <> 'DELETE' then new.data end;
  o := case when TG_OP <> 'INSERT' then old.data end;
  sd := coalesce(n, o);
  coach := case when sd ->> 'coachId' ~* '^[0-9a-f-]{36}$' then (sd ->> 'coachId')::uuid end;
  pname := public.player_name(sd ->> 'playerId');
  reason := nullif(trim(coalesce(sd ->> 'reason', '')), '');

  if TG_OP = 'DELETE' then
    if o ->> 'status' = 'pending' and coach is not null and coach is distinct from auth.uid() then
      perform public.notify(coach, 'request_withdrawn', 'session-' || (o ->> 'sessionId'),
        pname || ' withdrew their cancellation request', public.notif_when(o, 'en'),
        'سحب ' || pname || ' طلب الإلغاء', public.notif_when(o, 'ar'));
    end if;
    return null;
  end if;

  if n ->> 'status' = 'pending' and coach is not null and coach is distinct from auth.uid() then
    if TG_OP = 'INSERT' or coalesce(o ->> 'status', '') <> 'pending' then
      perform public.notify(coach, 'request', 'session-' || (n ->> 'sessionId'),
        pname || ' asked to cancel a session', concat_ws(' · ', public.notif_when(n, 'en'), reason),
        'طلب ' || pname || ' إلغاء حصة', concat_ws(' · ', public.notif_when(n, 'ar'), reason));
    elsif (n ->> 'reason', n ->> 'at') is distinct from (o ->> 'reason', o ->> 'at') then
      perform public.notify(coach, 'request', 'session-' || (n ->> 'sessionId'),
        pname || ' resent a cancellation request', concat_ws(' · ', public.notif_when(n, 'en'), reason),
        'أعاد ' || pname || ' إرسال طلب الإلغاء', concat_ws(' · ', public.notif_when(n, 'ar'), reason));
    end if;
  elsif TG_OP = 'UPDATE' and n ->> 'status' in ('approved', 'declined') and coalesce(o ->> 'status', '') = 'pending' then
    u := case when n ->> 'playerUid' ~* '^[0-9a-f-]{36}$' then (n ->> 'playerUid')::uuid end;
    if u is not null and u is distinct from auth.uid() then
      if n ->> 'status' = 'approved' then
        perform public.notify(u, 'request_approved', '', 'Cancellation approved', public.notif_when(n, 'en'),
                              'تمت الموافقة على الإلغاء', public.notif_when(n, 'ar'));
      else
        perform public.notify(u, 'request_declined', '', 'Cancellation declined — the session stays booked', public.notif_when(n, 'en'),
                              'تم رفض طلب الإلغاء — الحصة باقية', public.notif_when(n, 'ar'));
      end if;
    end if;
  end if;
  return null;
end;
$$;
drop trigger if exists docs_notify_requests on public.docs;
create trigger docs_notify_requests after insert or update or delete on public.docs
  for each row execute function public.notif_requests();

------------------------------------------------------------------------------------------
-- Players joining and being assigned
------------------------------------------------------------------------------------------
create or replace function public.notif_enrollments()
returns trigger language plpgsql security definer set search_path = public as $$
declare actor uuid := auth.uid(); club text; pname text;
begin
  if actor is null or actor = new.coach_id then return null; end if;
  club := (select name from public.orgs where id = new.org_id);
  pname := public.player_name(new.player_id);
  if public.player_uid(new.player_id) = actor then
    perform public.notify(new.coach_id, 'player_joined', 'trainee-' || new.player_id,
      'New player joined with your invite link', pname || ' · ' || coalesce(club, ''),
      'انضم لاعب جديد عبر رابط الدعوة الخاص بك', pname || ' · ' || coalesce(club, ''));
  else
    perform public.notify(new.coach_id, 'player_assigned', 'trainee-' || new.player_id,
      'A player was assigned to you', pname || ' · ' || coalesce(club, '') || ' · ' || public.notif_person(actor),
      'تم إسناد لاعب إليك', pname || ' · ' || coalesce(club, '') || ' · ' || public.notif_person(actor));
  end if;
  return null;
end;
$$;
drop trigger if exists enrollments_notify on public.enrollments;
create trigger enrollments_notify after insert on public.enrollments for each row execute function public.notif_enrollments();

create or replace function public.notif_club_players()
returns trigger language plpgsql security definer set search_path = public as $$
declare actor uuid := auth.uid(); club text; pname text; a uuid;
begin
  if actor is null or public.player_uid(new.player_id) is distinct from actor then return null; end if;  -- joined by themselves (invite link)
  club := (select name from public.orgs where id = new.org_id);
  pname := public.player_name(new.player_id);
  for a in select user_id from public.org_members where org_id = new.org_id and role = 'club_admin' and user_id <> actor loop
    perform public.notify(a, 'club_player_joined', 'trainee-' || new.player_id,
      'New player joined ' || coalesce(club, 'the club'), pname,
      'انضم لاعب جديد إلى ' || coalesce(club, 'النادي'), pname);
  end loop;
  return null;
end;
$$;
drop trigger if exists club_players_notify on public.club_players;
create trigger club_players_notify after insert on public.club_players for each row execute function public.notif_club_players();

------------------------------------------------------------------------------------------
-- Coaches added to / removed from a club → the club admins
------------------------------------------------------------------------------------------
create or replace function public.notif_org_members()
returns trigger language plpgsql security definer set search_path = public as $$
declare r record; club text; who text; a uuid;
begin
  r := case when TG_OP = 'DELETE' then old else new end;
  if r.role <> 'coach' then return null; end if;
  club := (select name from public.orgs where id = r.org_id);
  if club is null then return null; end if;  -- the whole club is being deleted
  who := public.notif_person(r.user_id);
  for a in select user_id from public.org_members where org_id = r.org_id and role = 'club_admin'
            and user_id is distinct from auth.uid() and user_id <> r.user_id loop
    if TG_OP = 'INSERT' then
      perform public.notify(a, 'coach_added', 'team', 'Coach added to ' || club, who, 'تمت إضافة مدرب إلى ' || club, who);
    else
      perform public.notify(a, 'coach_removed', 'team', 'Coach removed from ' || club, who, 'تمت إزالة مدرب من ' || club, who);
    end if;
  end loop;
  return null;
end;
$$;
drop trigger if exists org_members_notify on public.org_members;
create trigger org_members_notify after insert or delete on public.org_members for each row execute function public.notif_org_members();

------------------------------------------------------------------------------------------
-- New accounts → sys admins
------------------------------------------------------------------------------------------
create or replace function public.notif_new_account()
returns trigger language plpgsql security definer set search_path = public as $$
declare a uuid;
begin
  for a in select user_id from public.user_roles where role = 'sysadmin' and user_id <> new.id loop
    perform public.notify(a, 'new_account', 'users', 'New account signed up', coalesce(new.email, ''),
                          'تم تسجيل حساب جديد', coalesce(new.email, ''));
  end loop;
  return null;
end;
$$;
drop trigger if exists profiles_notify_new on public.profiles;
create trigger profiles_notify_new after insert on public.profiles for each row execute function public.notif_new_account();

------------------------------------------------------------------------------------------
-- Reminders (1 day and 2 hours before) and the coaches' 7:00 summary — run every 15 minutes
------------------------------------------------------------------------------------------
create or replace function public.send_reminders()
returns integer language plpgsql security definer set search_path = public as $$
declare r record; pid text; u uuid; cnt int := 0; local_now timestamp := now() at time zone 'Asia/Riyadh';
  left_ interval; tag text; lines_en text; lines_ar text; c record;
begin
  perform set_config('app.no_kick', '1', true);
  for r in select s.id, s.data, s.coach_id, public.session_at(s.data) as at from public.docs s
            where s.collection = 'sessions' and coalesce(s.data ->> 'status', 'planned') = 'planned'
              and s.data ->> 'date' between to_char(local_now::date, 'YYYY-MM-DD') and to_char(local_now::date + 2, 'YYYY-MM-DD') loop
    continue when r.at is null or r.at <= now();
    left_ := r.at - now();
    if left_ <= interval '2 hours' then tag := 'r2';
    elsif left_ <= interval '24 hours' and left_ > interval '3 hours' then tag := 'r24';
    else continue; end if;
    for pid in select jsonb_array_elements_text(coalesce(r.data -> 'traineeIds', '[]')) except select jsonb_array_elements_text(coalesce(r.data -> 'excused', '[]')) loop
      u := public.player_uid(pid);
      continue when u is null;
      continue when not public.notif_once(tag || ':' || r.id || ':' || pid || ':' || coalesce(r.data ->> 'date', '') || ' ' || coalesce(r.data ->> 'time', ''));
      if tag = 'r2' then
        perform public.notify(u, 'reminder', '', 'Your session starts in 2 hours', public.notif_person(r.coach_id) || ' · ' || public.notif_session_line(r.data, 'en'),
                              'حصتك تبدأ بعد ساعتين', public.notif_person(r.coach_id) || ' · ' || public.notif_session_line(r.data, 'ar'));
      else
        perform public.notify(u, 'reminder', '', 'Reminder: session tomorrow', public.notif_person(r.coach_id) || ' · ' || public.notif_session_line(r.data, 'en'),
                              'تذكير: لديك حصة غداً', public.notif_person(r.coach_id) || ' · ' || public.notif_session_line(r.data, 'ar'));
      end if;
      cnt := cnt + 1;
    end loop;
  end loop;

  -- 7:00–7:59 Riyadh: each coach's day
  if local_now::time >= time '07:00' and local_now::time < time '08:00' then
    for c in select s.coach_id, count(*) as n,
                    string_agg(coalesce(s.data ->> 'time', '') || ' ' || coalesce((select string_agg(public.player_name(x), ', ')
                       from jsonb_array_elements_text(coalesce(s.data -> 'traineeIds', '[]')) x), ''), ' · ' order by s.data ->> 'time') as line
               from public.docs s
              where s.collection = 'sessions' and s.coach_id is not null and coalesce(s.data ->> 'status', 'planned') = 'planned'
                and s.data ->> 'date' = to_char(local_now::date, 'YYYY-MM-DD')
              group by s.coach_id loop
      continue when not public.notif_once('sum:' || c.coach_id || ':' || to_char(local_now::date, 'YYYY-MM-DD'));
      perform public.notify(c.coach_id, 'summary', 'week',
        case when c.n = 1 then 'Today: 1 session' else 'Today: ' || c.n || ' sessions' end, left(c.line, 300),
        case when c.n = 1 then 'اليوم: حصة واحدة' else 'اليوم: ' || c.n || ' حصص' end, left(c.line, 300));
      cnt := cnt + 1;
    end loop;
  end if;

  delete from private.notif_sent where at < now() - interval '30 days';
  delete from public.notifications where created_at < now() - interval '90 days';
  perform set_config('app.no_kick', '0', true);
  perform public.push_kick();
  return cnt;
end;
$$;

------------------------------------------------------------------------------------------
-- Push delivery: new messages are handed to the site's /api/push function in small batches
------------------------------------------------------------------------------------------
create or replace function public.push_kick()
returns void language plpgsql security definer set search_path = public, private as $$
declare c record; items jsonb; batch jsonb; i int;
begin
  if coalesce(current_setting('app.no_kick', true), '') = '1' then return; end if;
  select * into c from private.push_config where id = 1;
  if c is null or c.fn_url is null or c.vapid_private is null or to_regnamespace('net') is null then return; end if;
  with claimed as (
    update public.notifications n set pushed_at = now()
     where n.id in (select id from public.notifications where pushed_at is null and created_at > now() - interval '30 minutes'
                     order by id limit 500 for update skip locked)
    returning n.*)
  select jsonb_agg(jsonb_build_object('endpoint', s.endpoint, 'p256dh', s.p256dh, 'auth', s.auth,
           'payload', jsonb_build_object(
             'title', case when p.lang = 'ar' then cl.title_ar else cl.title_en end,
             'body',  case when p.lang = 'ar' then cl.body_ar  else cl.body_en  end,
             'link', cl.link, 'id', cl.id, 'tag', cl.kind || '-' || cl.id)) order by cl.id)
    into items
    from claimed cl join public.push_subscriptions s on s.user_id = cl.user_id
    left join public.profiles p on p.id = cl.user_id
   where coalesce(p.notif_prefs ->> 'push', 'true') <> 'false';
  if items is null then return; end if;
  i := 0;
  while i < jsonb_array_length(items) loop
    select jsonb_agg(e) into batch from (select e from jsonb_array_elements(items) with ordinality t(e, k) where k > i and k <= i + 20) z;
    execute 'select net.http_post(url := $1, body := $2, headers := $3, timeout_milliseconds := 15000)'
      using c.fn_url,
            jsonb_build_object('secret', c.secret, 'api', jsonb_build_object('url', c.api_url, 'key', c.api_key),
                               'vapid', jsonb_build_object('public', c.vapid_public, 'private', c.vapid_private, 'subject', coalesce(c.subject, 'mailto:admin@example.com')),
                               'items', batch),
            '{"Content-Type": "application/json"}'::jsonb;
    i := i + 20;
  end loop;
end;
$$;

create or replace function public.notif_push_trigger()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public.push_kick();
  return null;
end;
$$;
drop trigger if exists notifications_push on public.notifications;
create trigger notifications_push after insert on public.notifications for each statement execute function public.notif_push_trigger();

-- The push function reports devices that no longer exist.
create or replace function public.push_gone(p_secret text, p_endpoints text[])
returns integer language plpgsql security definer set search_path = public, private as $$
declare n int;
begin
  if p_secret is null or p_secret <> (select secret from private.push_config where id = 1) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  delete from public.push_subscriptions where endpoint = any(coalesce(p_endpoints, '{}'));
  get diagnostics n = row_count;
  return n;
end;
$$;

------------------------------------------------------------------------------------------
-- What the app calls
------------------------------------------------------------------------------------------
create or replace function public.mark_notifications_read(p_ids bigint[] default null)
returns integer language plpgsql security definer set search_path = public as $$
declare n int;
begin
  update public.notifications set read_at = now()
   where user_id = auth.uid() and read_at is null and (p_ids is null or id = any(p_ids));
  get diagnostics n = row_count;
  return n;
end;
$$;

create or replace function public.save_push_subscription(p_endpoint text, p_p256dh text, p_auth text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'sign in first' using errcode = '42501'; end if;
  if coalesce(p_endpoint, '') !~ '^https://' or coalesce(p_p256dh, '') = '' or coalesce(p_auth, '') = '' then
    raise exception 'invalid subscription' using errcode = '22023';
  end if;
  insert into public.push_subscriptions (endpoint, user_id, p256dh, auth) values (p_endpoint, auth.uid(), p_p256dh, p_auth)
  on conflict (endpoint) do update set user_id = excluded.user_id, p256dh = excluded.p256dh, auth = excluded.auth, created_at = now();
end;
$$;

create or replace function public.delete_push_subscription(p_endpoint text)
returns void language sql security definer set search_path = public as $$
  delete from public.push_subscriptions where endpoint = p_endpoint and user_id = auth.uid();
$$;

create or replace function public.set_notif_prefs(p_prefs jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare clean jsonb := '{}'::jsonb; k text; res jsonb;
begin
  if auth.uid() is null then raise exception 'sign in first' using errcode = '42501'; end if;
  foreach k in array array['push', 'reminders', 'feedback'] loop
    if jsonb_typeof(p_prefs -> k) = 'boolean' then clean := clean || jsonb_build_object(k, p_prefs -> k); end if;
  end loop;
  update public.profiles set notif_prefs = coalesce(notif_prefs, '{}'::jsonb) || clean where id = auth.uid()
  returning notif_prefs into res;
  return coalesce(res, '{}'::jsonb);
end;
$$;

create or replace function public.my_notif_prefs()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce((select notif_prefs from public.profiles where id = auth.uid()), '{}'::jsonb)
         || jsonb_build_object('vapid', (select value from public.app_public_settings where key = 'vapid_public'));
$$;

create or replace function public.set_my_lang(p_lang text)
returns void language sql security definer set search_path = public as $$
  update public.profiles set lang = case when p_lang in ('ar', 'en') then p_lang else lang end where id = auth.uid();
$$;

revoke execute on function public.notify(uuid, text, text, text, text, text, text), public.notif_once(text),
  public.send_reminders(), public.push_kick() from public, anon, authenticated;
grant execute on function public.mark_notifications_read(bigint[]), public.save_push_subscription(text, text, text),
  public.delete_push_subscription(text), public.set_notif_prefs(jsonb), public.my_notif_prefs(), public.set_my_lang(text) to authenticated;
revoke execute on function public.mark_notifications_read(bigint[]), public.save_push_subscription(text, text, text),
  public.delete_push_subscription(text), public.set_notif_prefs(jsonb), public.my_notif_prefs(), public.set_my_lang(text) from anon, public;
grant execute on function public.push_gone(text, text[]) to anon, authenticated;

------------------------------------------------------------------------------------------
-- Scheduling (Supabase has pg_cron and pg_net; a plain Postgres without them simply skips this)
------------------------------------------------------------------------------------------
do $$ begin
  begin create extension if not exists pg_net; exception when others then raise notice 'pg_net not available here'; end;
  begin create extension if not exists pg_cron; exception when others then raise notice 'pg_cron not available here'; end;
  if to_regnamespace('cron') is not null then
    perform cron.unschedule(jobid) from cron.job where jobname = 'notif-reminders';
    perform cron.schedule('notif-reminders', '*/15 * * * *', 'select public.send_reminders()');
  end if;
end $$;
