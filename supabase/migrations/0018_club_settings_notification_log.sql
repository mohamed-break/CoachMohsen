-- 1) Club settings (per club, changed by club admins and sys admins). For now one setting:
--    suggestPlanned – when a player's booked sessions from their fixed weekly schedule run out, show the next ones
--    as suggested planned sessions (default on).
-- 2) Notification log for sys admins: each message now records what it is about (club, venue, coach, player),
--    and admin_notifications() lists every message with when it was read, with filters.
------------------------------------------------------------------------------------------
alter table public.orgs add column if not exists settings jsonb not null default '{}'::jsonb;

create or replace function public.club_settings()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_object_agg(o.id, o.settings), '{}'::jsonb)
    from public.orgs o
   where public.is_sysadmin() or public.is_member(o.id)
      or o.id in (select cp.org_id from public.club_players cp join public.docs t on t.collection = 'trainees' and t.id = cp.player_id
                   where t.data ->> 'linkedUserId' = auth.uid()::text);
$$;

create or replace function public.set_club_settings(p_org text, p_settings jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare clean jsonb := '{}'::jsonb; res jsonb;
begin
  if not (public.is_sysadmin() or public.is_club_admin(p_org)) then
    raise exception 'Only club admins can change club settings' using errcode = '42501';
  end if;
  if jsonb_typeof(p_settings -> 'suggestPlanned') = 'boolean' then clean := clean || jsonb_build_object('suggestPlanned', p_settings -> 'suggestPlanned'); end if;
  update public.orgs set settings = coalesce(settings, '{}'::jsonb) || clean where id = p_org returning settings into res;
  if res is null then raise exception 'Club not found' using errcode = 'P0002'; end if;
  return res;
end;
$$;
revoke execute on function public.club_settings(), public.set_club_settings(text, jsonb) from public, anon;
grant execute on function public.club_settings(), public.set_club_settings(text, jsonb) to authenticated;

------------------------------------------------------------------------------------------
alter table public.notifications add column if not exists org_id text;
alter table public.notifications add column if not exists venue text;
alter table public.notifications add column if not exists coach_id uuid;
alter table public.notifications add column if not exists player_id text;
create index if not exists notifications_created_idx on public.notifications (id desc);

create or replace function public.notify(p_user uuid, p_kind text, p_link text, p_title_en text, p_body_en text, p_title_ar text, p_body_ar text)
returns void language plpgsql security definer set search_path = public as $$
declare prefs jsonb; c jsonb; pl text;
begin
  if p_user is null then return; end if;
  if not exists (select 1 from auth.users where id = p_user) then return; end if;
  select coalesce(notif_prefs, '{}'::jsonb) into prefs from public.profiles where id = p_user;
  prefs := coalesce(prefs, '{}'::jsonb);
  if p_kind in ('reminder', 'summary') and prefs ->> 'reminders' = 'false' then return; end if;
  if p_kind = 'feedback' and prefs ->> 'feedback' = 'false' then return; end if;
  -- what the message is about (set by the trigger that writes it): club, venue, coach, player(s)
  begin c := nullif(current_setting('notif.ctx', true), '')::jsonb; exception when others then c := null; end;
  c := coalesce(c, '{}'::jsonb);
  if jsonb_typeof(c -> 'players') = 'array' then
    select t.id into pl from public.docs t
     where t.collection = 'trainees' and t.id in (select jsonb_array_elements_text(c -> 'players')) and t.data ->> 'linkedUserId' = p_user::text limit 1;
    if pl is null and jsonb_array_length(c -> 'players') = 1 then pl := c -> 'players' ->> 0; end if;
  end if;
  insert into public.notifications (user_id, kind, link, title_en, body_en, title_ar, body_ar, org_id, venue, coach_id, player_id)
  values (p_user, p_kind, coalesce(p_link, ''), p_title_en, coalesce(p_body_en, ''), p_title_ar, coalesce(p_body_ar, ''),
          nullif(c ->> 'org', ''), nullif(c ->> 'venue', ''),
          case when c ->> 'coach' ~* '^[0-9a-f-]{36}$' then (c ->> 'coach')::uuid end, pl);
end;
$$;

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
  perform set_config('notif.ctx', (jsonb_build_object('org', coalesce(case when TG_OP <> 'DELETE' then new.club_id end, old.club_id), 'venue', coalesce(n, o) ->> 'location', 'coach', coach, 'players', coalesce(coalesce(n, o) -> 'traineeIds', '[]'::jsonb)))::text, true);

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
  perform set_config('notif.ctx', (jsonb_build_object('org', coalesce(case when TG_OP <> 'DELETE' then new.club_id end, old.club_id), 'coach', coach, 'players', jsonb_build_array(sd ->> 'playerId'), 'venue', (select s.data ->> 'location' from public.docs s where s.collection = 'sessions' and s.id = sd ->> 'sessionId')))::text, true);

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

create or replace function public.notif_enrollments()
returns trigger language plpgsql security definer set search_path = public as $$
declare actor uuid := auth.uid(); club text; pname text;
begin
  if actor is null or actor = new.coach_id then return null; end if;
  club := (select name from public.orgs where id = new.org_id);
  perform set_config('notif.ctx', (jsonb_build_object('org', new.org_id, 'coach', new.coach_id, 'players', jsonb_build_array(new.player_id)))::text, true);
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

create or replace function public.notif_club_players()
returns trigger language plpgsql security definer set search_path = public as $$
declare actor uuid := auth.uid(); club text; pname text; a uuid;
begin
  if actor is null or public.player_uid(new.player_id) is distinct from actor then return null; end if;  -- joined by themselves (invite link)
  club := (select name from public.orgs where id = new.org_id);
  perform set_config('notif.ctx', (jsonb_build_object('org', new.org_id, 'players', jsonb_build_array(new.player_id)))::text, true);
  pname := public.player_name(new.player_id);
  for a in select user_id from public.org_members where org_id = new.org_id and role = 'club_admin' and user_id <> actor loop
    perform public.notify(a, 'club_player_joined', 'trainee-' || new.player_id,
      'New player joined ' || coalesce(club, 'the club'), pname,
      'انضم لاعب جديد إلى ' || coalesce(club, 'النادي'), pname);
  end loop;
  return null;
end;
$$;

create or replace function public.notif_org_members()
returns trigger language plpgsql security definer set search_path = public as $$
declare r record; club text; who text; a uuid;
begin
  r := case when TG_OP = 'DELETE' then old else new end;
  perform set_config('notif.ctx', (jsonb_build_object('org', r.org_id, 'coach', r.user_id))::text, true);
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

create or replace function public.notif_new_account()
returns trigger language plpgsql security definer set search_path = public as $$
declare a uuid;
begin
  perform set_config('notif.ctx', ('{}'::jsonb)::text, true);
  for a in select user_id from public.user_roles where role = 'sysadmin' and user_id <> new.id loop
    perform public.notify(a, 'new_account', 'users', 'New account signed up', coalesce(new.email, ''),
                          'تم تسجيل حساب جديد', coalesce(new.email, ''));
  end loop;
  return null;
end;
$$;

create or replace function public.send_reminders()
returns integer language plpgsql security definer set search_path = public as $$
declare r record; pid text; u uuid; cnt int := 0; local_now timestamp := now() at time zone 'Asia/Riyadh';
  left_ interval; tag text; lines_en text; lines_ar text; c record;
begin
  perform set_config('app.no_kick', '1', true);
  for r in select s.id, s.data, s.coach_id, s.club_id, public.session_at(s.data) as at from public.docs s
            where s.collection = 'sessions' and coalesce(s.data ->> 'status', 'planned') = 'planned'
              and s.data ->> 'date' between to_char(local_now::date, 'YYYY-MM-DD') and to_char(local_now::date + 2, 'YYYY-MM-DD') loop
    continue when r.at is null or r.at <= now();
    left_ := r.at - now();
    if left_ <= interval '2 hours' then tag := 'r2';
    elsif left_ <= interval '24 hours' and left_ > interval '3 hours' then tag := 'r24';
    else continue; end if;
    perform set_config('notif.ctx', (jsonb_build_object('org', r.club_id, 'venue', r.data ->> 'location', 'coach', r.coach_id, 'players', coalesce(r.data -> 'traineeIds', '[]'::jsonb)))::text, true);
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
                       from jsonb_array_elements_text(coalesce(s.data -> 'traineeIds', '[]')) x), ''), ' · ' order by s.data ->> 'time') as line,
                    string_agg(public.notif_tm(coalesce(s.data ->> 'time', ''), 'ar') || ' ' || coalesce((select string_agg(public.player_name(x), '، ')
                       from jsonb_array_elements_text(coalesce(s.data -> 'traineeIds', '[]')) x), ''), ' · ' order by s.data ->> 'time') as line_ar
               from public.docs s
              where s.collection = 'sessions' and s.coach_id is not null and coalesce(s.data ->> 'status', 'planned') = 'planned'
                and s.data ->> 'date' = to_char(local_now::date, 'YYYY-MM-DD')
              group by s.coach_id loop
      continue when not public.notif_once('sum:' || c.coach_id || ':' || to_char(local_now::date, 'YYYY-MM-DD'));
    perform set_config('notif.ctx', (jsonb_build_object('coach', c.coach_id))::text, true);
      perform public.notify(c.coach_id, 'summary', 'week',
        case when c.n = 1 then 'Today: 1 session' else 'Today: ' || c.n || ' sessions' end, left(c.line, 300),
        case when c.n = 1 then 'اليوم: حصة واحدة' else 'اليوم: ' || c.n || ' حصص' end, left(c.line_ar, 300));
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

-- Sys admins: every notification, newest first, with filters
--   p_filters: {org, venue, coach, player, status: read|unread, q, before (id), limit}
create or replace function public.admin_notifications(p_filters jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare f jsonb := coalesce(p_filters, '{}'::jsonb); lim int; res jsonb;
begin
  if not public.is_sysadmin() then raise exception 'Only sys admins can see all notifications' using errcode = '42501'; end if;
  lim := least(greatest(coalesce((f ->> 'limit')::int, 100), 1), 500);
  select coalesce(jsonb_agg(x order by (x ->> 'id')::bigint desc), '[]'::jsonb) into res from (
    select jsonb_build_object(
      'id', n.id, 'kind', n.kind, 'created_at', n.created_at, 'read_at', n.read_at, 'pushed_at', n.pushed_at, 'link', n.link,
      'title_en', n.title_en, 'body_en', n.body_en, 'title_ar', n.title_ar, 'body_ar', n.body_ar,
      'user_id', n.user_id, 'user_name', public.notif_person(n.user_id), 'user_email', p.email,
      'org_id', n.org_id, 'org_name', o.name, 'venue', n.venue,
      'coach_id', n.coach_id, 'coach_name', case when n.coach_id is not null then public.notif_person(n.coach_id) end,
      'player_id', n.player_id, 'player_name', case when n.player_id is not null then public.player_name(n.player_id) end,
      'devices', (select count(*) from public.push_subscriptions s where s.user_id = n.user_id)) as x
      from public.notifications n
      left join public.profiles p on p.id = n.user_id
      left join public.orgs o on o.id = n.org_id
     where (nullif(f ->> 'org', '') is null or n.org_id = f ->> 'org')
       and (nullif(f ->> 'venue', '') is null or n.venue = f ->> 'venue')
       and (nullif(f ->> 'coach', '') is null or n.coach_id::text = f ->> 'coach' or n.user_id::text = f ->> 'coach')
       and (nullif(f ->> 'player', '') is null or n.player_id = f ->> 'player'
            or n.user_id::text = (select t.data ->> 'linkedUserId' from public.docs t where t.collection = 'trainees' and t.id = f ->> 'player'))
       and (coalesce(f ->> 'status', '') = '' or (f ->> 'status' = 'read' and n.read_at is not null) or (f ->> 'status' = 'unread' and n.read_at is null))
       and (nullif(f ->> 'before', '') is null or n.id < (f ->> 'before')::bigint)
       and (nullif(trim(f ->> 'q'), '') is null
            or concat_ws(' ', n.title_en, n.body_en, n.title_ar, n.body_ar, p.email, p.full_name, p.display_name) ilike '%' || trim(f ->> 'q') || '%')
     order by n.id desc
     limit lim) z;
  return res;
end;
$$;

-- Choices for the filters
create or replace function public.admin_notif_filters()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_sysadmin() then raise exception 'Only sys admins' using errcode = '42501'; end if;
  return jsonb_build_object(
    'orgs', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', name) order by name) from public.orgs), '[]'::jsonb),
    'venues', coalesce((select jsonb_agg(distinct jsonb_build_object('name', data ->> 'name', 'org', club_id)) from public.docs
                         where collection = 'venues' and coalesce(data ->> 'name', '') <> ''), '[]'::jsonb),
    'coaches', coalesce((select jsonb_agg(jsonb_build_object('id', u, 'name', public.notif_person(u), 'orgs', orgs) order by public.notif_person(u))
                           from (select user_id as u, jsonb_agg(distinct org_id) as orgs from public.org_members where role in ('coach', 'club_admin') group by user_id) m), '[]'::jsonb),
    'players', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'name', coalesce(t.data ->> 'name', '—'),
                           'orgs', coalesce((select jsonb_agg(cp.org_id) from public.club_players cp where cp.player_id = t.id), '[]'::jsonb)) order by t.data ->> 'name')
                           from public.docs t where t.collection = 'trainees'), '[]'::jsonb));
end;
$$;
revoke execute on function public.admin_notifications(jsonb), public.admin_notif_filters() from public, anon;
grant execute on function public.admin_notifications(jsonb), public.admin_notif_filters() to authenticated;
revoke execute on function public.notify(uuid, text, text, text, text, text, text) from public, anon, authenticated;
