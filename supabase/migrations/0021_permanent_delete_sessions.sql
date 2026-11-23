-- Permanent delete of scheduled sessions, with a log that only sys admins see, and restore.
--   • sys admins and club admins can delete permanently; coaches only when a club admin allowed them
--     (org_members.can_delete_sessions), and only their own sessions
--   • purge_session(): copies the session, its cancellation requests, the coach's private remarks and its
--     notifications into private.deleted_sessions, then removes them all — players are not told
--   • sessions can no longer be deleted any other way (except by sys admins)
--   • restore_session(): sys admins put a deleted session (and its requests/remarks) back, quietly
------------------------------------------------------------------------------------------
alter table public.org_members add column if not exists can_delete_sessions boolean not null default false;
alter table public.notifications add column if not exists session_id text;
create index if not exists notifications_session_idx on public.notifications (session_id) where session_id is not null;

create table if not exists private.deleted_sessions (
  id          bigint generated always as identity primary key,
  session_id  text not null,
  club_id     text,
  coach_id    uuid,
  data        jsonb not null,
  related     jsonb not null default '{}'::jsonb,
  deleted_by  uuid,
  deleted_at  timestamptz not null default now(),
  restored_by uuid,
  restored_at timestamptz
);

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
  insert into public.notifications (user_id, kind, link, title_en, body_en, title_ar, body_ar, org_id, venue, coach_id, player_id, session_id)
  values (p_user, p_kind, coalesce(p_link, ''), p_title_en, coalesce(p_body_en, ''), p_title_ar, coalesce(p_body_ar, ''),
          nullif(c ->> 'org', ''), nullif(c ->> 'venue', ''),
          case when c ->> 'coach' ~* '^[0-9a-f-]{36}$' then (c ->> 'coach')::uuid end, pl, nullif(c ->> 'session', ''));
end;
$$;

create or replace function public.notif_sessions()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  actor uuid := auth.uid();
  n jsonb; o jsonb; sid text; coach uuid; pid text; u uuid; cname text;
  active_new text[]; ids_old text[]; fut boolean;
begin
  if coalesce(current_setting('app.quiet', true), '') = '1' then return null; end if;  -- permanent delete / restore: no messages
  if TG_OP = 'DELETE' then
    if old.collection <> 'sessions' then return null; end if;
  elsif new.collection <> 'sessions' then return null; end if;

  n := case when TG_OP <> 'DELETE' then new.data end;
  o := case when TG_OP <> 'INSERT' then old.data end;
  sid := coalesce(new.id, old.id);
  coach := coalesce(case when TG_OP <> 'DELETE' then new.coach_id end, old.coach_id);
  cname := public.notif_person(coach);
  perform set_config('notif.ctx', (jsonb_build_object('org', coalesce(case when TG_OP <> 'DELETE' then new.club_id end, old.club_id), 'venue', coalesce(n, o) ->> 'location', 'coach', coach, 'players', coalesce(coalesce(n, o) -> 'traineeIds', '[]'::jsonb), 'session', sid))::text, true);

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
  if TG_OP = 'UPDATE' and n ->> 'status' = 'cancelled' and coalesce(o ->> 'status', 'planned') <> 'cancelled' and fut
     and coalesce(n ->> 'notifyPlayers', 'true') <> 'false' then
    foreach pid in array active_new loop
      u := public.player_uid(pid);
      continue when u is null or u is not distinct from actor;
      continue when exists (select 1 from public.docs where collection = 'requests' and id = sid || ':' || u::text and data ->> 'status' = 'approved');
      perform public.notify(u, 'cancelled', '', 'Session cancelled',
                            concat_ws(' · ', cname, public.notif_session_line(n, 'en'), nullif(trim(coalesce(n ->> 'cancelReason', '')), '')),
                            'تم إلغاء الحصة',
                            concat_ws(' · ', cname, public.notif_session_line(n, 'ar'), nullif(trim(coalesce(n ->> 'cancelReason', '')), '')));
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
  if coalesce(current_setting('app.quiet', true), '') = '1' then return null; end if;  -- permanent delete / restore: no messages
  if TG_OP = 'DELETE' then
    if old.collection <> 'requests' then return null; end if;
  elsif new.collection <> 'requests' then return null; end if;
  n := case when TG_OP <> 'DELETE' then new.data end;
  o := case when TG_OP <> 'INSERT' then old.data end;
  sd := coalesce(n, o);
  coach := case when sd ->> 'coachId' ~* '^[0-9a-f-]{36}$' then (sd ->> 'coachId')::uuid end;
  pname := public.player_name(sd ->> 'playerId');
  reason := nullif(trim(coalesce(sd ->> 'reason', '')), '');
  perform set_config('notif.ctx', (jsonb_build_object('org', coalesce(case when TG_OP <> 'DELETE' then new.club_id end, old.club_id), 'coach', coach, 'players', jsonb_build_array(sd ->> 'playerId'), 'session', sd ->> 'sessionId', 'venue', (select s.data ->> 'location' from public.docs s where s.collection = 'sessions' and s.id = sd ->> 'sessionId')))::text, true);

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
    perform set_config('notif.ctx', (jsonb_build_object('org', r.club_id, 'venue', r.data ->> 'location', 'coach', r.coach_id, 'players', coalesce(r.data -> 'traineeIds', '[]'::jsonb), 'session', r.id))::text, true);
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

create or replace function public.can_purge_session(p_club text, p_coach uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and (public.is_sysadmin() or public.is_club_admin(p_club)
    or exists (select 1 from public.org_members m where m.org_id = p_club and m.user_id = auth.uid() and m.role = 'coach'
                and m.can_delete_sessions and auth.uid() = p_coach));
$$;

-- Only the permanent delete may remove a session (sys admins excepted)
create or replace function public.guard_session_delete()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if old.collection = 'sessions' and auth.uid() is not null and coalesce(current_setting('app.quiet', true), '') <> '1'
     and not public.is_sysadmin() then
    raise exception 'Use "Delete permanently" to delete a session' using errcode = '42501';
  end if;
  return old;
end;
$$;
drop trigger if exists docs_guard_session_delete on public.docs;
create trigger docs_guard_session_delete before delete on public.docs for each row execute function public.guard_session_delete();

create or replace function public.purge_session(p_id text)
returns bigint language plpgsql security definer set search_path = public, private as $$
declare s public.docs; rel jsonb; lid bigint;
begin
  select * into s from public.docs where collection = 'sessions' and id = p_id;
  if s.id is null then raise exception 'Session not found' using errcode = 'P0002'; end if;
  if not public.can_purge_session(coalesce(s.club_id, s.data ->> 'clubId'), coalesce(s.coach_id, case when s.data ->> 'coachId' ~* '^[0-9a-f-]{36}$' then (s.data ->> 'coachId')::uuid end)) then
    raise exception 'You are not allowed to delete sessions permanently' using errcode = '42501';
  end if;
  rel := jsonb_build_object(
    'requests', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'data', data, 'club_id', club_id, 'coach_id', coach_id, 'owner_uid', owner_uid)) from public.docs where collection = 'requests' and data ->> 'sessionId' = p_id), '[]'::jsonb),
    'sessremarks', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'data', data, 'club_id', club_id, 'coach_id', coach_id, 'owner_uid', owner_uid)) from public.docs where collection = 'sessremarks' and id = p_id), '[]'::jsonb),
    'owner_uid', s.owner_uid,
    'notifications', coalesce((select jsonb_agg(to_jsonb(n) - 'id') from public.notifications n where n.session_id = p_id), '[]'::jsonb));
  insert into private.deleted_sessions (session_id, club_id, coach_id, data, related, deleted_by)
  values (p_id, s.club_id, s.coach_id, s.data, rel, auth.uid()) returning id into lid;
  perform set_config('app.quiet', '1', true);
  delete from public.docs where collection = 'requests' and data ->> 'sessionId' = p_id;
  delete from public.docs where collection = 'sessremarks' and id = p_id;
  delete from public.notifications where session_id = p_id;
  delete from public.docs where collection = 'sessions' and id = p_id;
  perform set_config('app.quiet', '0', true);
  return lid;
end;
$$;

create or replace function public.restore_session(p_log bigint)
returns text language plpgsql security definer set search_path = public, private as $$
declare l private.deleted_sessions; r jsonb;
begin
  if not public.is_sysadmin() then raise exception 'Only sys admins can restore sessions' using errcode = '42501'; end if;
  select * into l from private.deleted_sessions where id = p_log;
  if l.id is null then raise exception 'Not found' using errcode = 'P0002'; end if;
  if l.restored_at is not null then raise exception 'This session was already restored' using errcode = '22023'; end if;
  if exists (select 1 from public.docs where collection = 'sessions' and id = l.session_id) then
    raise exception 'A session with this id already exists' using errcode = '23505';
  end if;
  perform set_config('app.quiet', '1', true);
  insert into public.docs (collection, id, data) values ('sessions', l.session_id, l.data);  -- the court check still applies
  update public.docs set club_id = l.club_id, coach_id = l.coach_id, owner_uid = nullif(l.related ->> 'owner_uid', '')::uuid where collection = 'sessions' and id = l.session_id;
  for r in select * from jsonb_array_elements(coalesce(l.related -> 'requests', '[]'::jsonb)) loop
    insert into public.docs (collection, id, data) values ('requests', r ->> 'id', r -> 'data') on conflict do nothing;
    update public.docs set club_id = r ->> 'club_id', coach_id = nullif(r ->> 'coach_id', '')::uuid, owner_uid = nullif(r ->> 'owner_uid', '')::uuid
     where collection = 'requests' and id = r ->> 'id';
  end loop;
  for r in select * from jsonb_array_elements(coalesce(l.related -> 'sessremarks', '[]'::jsonb)) loop
    insert into public.docs (collection, id, data) values ('sessremarks', r ->> 'id', r -> 'data') on conflict do nothing;
    update public.docs set club_id = r ->> 'club_id', coach_id = nullif(r ->> 'coach_id', '')::uuid, owner_uid = nullif(r ->> 'owner_uid', '')::uuid
     where collection = 'sessremarks' and id = r ->> 'id';
  end loop;
  perform set_config('app.quiet', '0', true);
  update private.deleted_sessions set restored_at = now(), restored_by = auth.uid() where id = p_log;
  return l.session_id;
end;
$$;

-- Sys admins: the log of permanently deleted sessions (newest first)
create or replace function public.deleted_sessions_list(p_filters jsonb default '{}'::jsonb)
returns jsonb language plpgsql stable security definer set search_path = public, private as $$
declare f jsonb := coalesce(p_filters, '{}'::jsonb); res jsonb;
begin
  if not public.is_sysadmin() then raise exception 'Only sys admins can see deleted sessions' using errcode = '42501'; end if;
  select coalesce(jsonb_agg(x order by (x ->> 'id')::bigint desc), '[]'::jsonb) into res from (
    select jsonb_build_object('id', l.id, 'session_id', l.session_id, 'club_id', l.club_id, 'club_name', o.name,
      'coach_id', l.coach_id, 'coach_name', case when l.coach_id is not null then public.notif_person(l.coach_id) end,
      'date', l.data ->> 'date', 'time', l.data ->> 'time', 'duration', l.data ->> 'duration', 'status', l.data ->> 'status',
      'location', l.data ->> 'location', 'courtName', l.data ->> 'courtName', 'focus', l.data ->> 'focus',
      'players', (select coalesce(jsonb_agg(public.player_name(p)), '[]'::jsonb) from jsonb_array_elements_text(coalesce(l.data -> 'traineeIds', '[]'::jsonb)) p),
      'requests', jsonb_array_length(coalesce(l.related -> 'requests', '[]'::jsonb)),
      'notifications', jsonb_array_length(coalesce(l.related -> 'notifications', '[]'::jsonb)),
      'deleted_by_name', case when l.deleted_by is not null then public.notif_person(l.deleted_by) end, 'deleted_at', l.deleted_at,
      'restored_by_name', case when l.restored_by is not null then public.notif_person(l.restored_by) end, 'restored_at', l.restored_at) as x
      from private.deleted_sessions l left join public.orgs o on o.id = l.club_id
     where (nullif(f ->> 'org', '') is null or l.club_id = f ->> 'org')
       and (coalesce(f ->> 'state', '') = '' or (f ->> 'state' = 'deleted' and l.restored_at is null) or (f ->> 'state' = 'restored' and l.restored_at is not null))
     order by l.id desc limit 300) z;
  return res;
end;
$$;

-- Club admins allow (or stop) a coach deleting sessions permanently
create or replace function public.set_delete_permission(p_org text, p_user uuid, p_allow boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not (public.is_sysadmin() or public.is_club_admin(p_org)) then
    raise exception 'Only club admins can change this permission' using errcode = '42501';
  end if;
  update public.org_members set can_delete_sessions = coalesce(p_allow, false) where org_id = p_org and user_id = p_user and role = 'coach';
  if not found then raise exception 'Not a coach of this club' using errcode = '22023'; end if;
end;
$$;

-- Who may delete permanently in a club (coaches with permission), for members of that club
create or replace function public.delete_permissions(p_org text)
returns jsonb language sql stable security definer set search_path = public as $$
  select case when public.is_sysadmin() or public.is_member(p_org) or public.is_club_admin(p_org) then
    coalesce((select jsonb_agg(user_id) from public.org_members where org_id = p_org and role = 'coach' and can_delete_sessions), '[]'::jsonb)
  else '[]'::jsonb end;
$$;

revoke execute on function public.purge_session(text), public.restore_session(bigint), public.deleted_sessions_list(jsonb),
  public.set_delete_permission(text, uuid, boolean), public.delete_permissions(text), public.can_purge_session(text, uuid) from public, anon;
grant execute on function public.purge_session(text), public.restore_session(bigint), public.deleted_sessions_list(jsonb),
  public.set_delete_permission(text, uuid, boolean), public.delete_permissions(text), public.can_purge_session(text, uuid) to authenticated;
