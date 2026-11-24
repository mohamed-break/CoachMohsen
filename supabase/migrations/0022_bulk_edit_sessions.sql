-- Bulk edit of sessions from the player page.
-- Each session updated by a bulk edit carries a new bulkEdit marker; its own "changed"/"cancelled" notices are
-- skipped, and the app then calls bulk_session_notice() once so each player gets one combined message
-- (and a coach who was given sessions gets one message too).
create or replace function public.notif_sessions()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  actor uuid := auth.uid();
  n jsonb; o jsonb; sid text; coach uuid; pid text; u uuid; cname text;
  active_new text[]; ids_old text[]; fut boolean; bulk boolean := false;
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
  -- part of a bulk edit: the app sends one combined notice afterwards (bulk_session_notice)
  bulk := TG_OP = 'UPDATE' and nullif(n ->> 'bulkEdit', '') is not null and (n ->> 'bulkEdit') is distinct from (o ->> 'bulkEdit');
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
    if TG_OP = 'UPDATE' and not bulk and coalesce(o ->> 'status', 'planned') = 'planned'
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
  if TG_OP = 'UPDATE' and not bulk and n ->> 'status' = 'cancelled' and coalesce(o ->> 'status', 'planned') <> 'cancelled' and fut
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

create or replace function public.bulk_session_notice(p_ids text[], p_kind text, p_notify_players boolean default true)
returns integer language plpgsql security definer set search_path = public as $$
declare actor uuid := auth.uid(); r record; u uuid; cnt int := 0; s record; n int;
begin
  if actor is null then raise exception 'sign in first' using errcode = '42501'; end if;
  -- the caller must be allowed to manage every one of these sessions
  for s in select d.id, d.club_id, d.coach_id from public.docs d where d.collection = 'sessions' and d.id = any(p_ids) loop
    if not (public.is_sysadmin() or public.is_club_admin(s.club_id) or s.coach_id = actor) then
      raise exception 'not allowed' using errcode = '42501';
    end if;
  end loop;
  if coalesce(p_notify_players, true) then
    for r in
      select public.player_uid(p.pid) as uid, p.pid,
             array_agg(d.data order by d.data ->> 'date', d.data ->> 'time') as sess,
             (array_agg(d.club_id))[1] as club, (array_agg(d.coach_id))[1] as coach
        from public.docs d
        cross join lateral (select jsonb_array_elements_text(coalesce(d.data -> 'traineeIds', '[]')) pid
                            except select jsonb_array_elements_text(coalesce(d.data -> 'excused', '[]'))) p
       where d.collection = 'sessions' and d.id = any(p_ids) and public.session_at(d.data) > now()
       group by p.pid
    loop
      continue when r.uid is null or r.uid = actor;
      n := array_length(r.sess, 1);
      perform set_config('notif.ctx', jsonb_build_object('org', r.club, 'coach', r.coach, 'players', jsonb_build_array(r.pid))::text, true);
      perform public.notify(r.uid, case when p_kind = 'cancelled' then 'cancelled' else 'changed' end, '',
        case when p_kind = 'cancelled' then case when n = 1 then 'Session cancelled' else n || ' sessions cancelled' end
             else case when n = 1 then 'Session changed' else n || ' sessions changed' end end,
        left((select string_agg(public.notif_session_line(x, 'en'), ' | ') from unnest(r.sess) x), 400),
        case when p_kind = 'cancelled' then case when n = 1 then 'تم إلغاء الحصة' else 'تم إلغاء ' || n || ' حصص' end
             else case when n = 1 then 'تم تعديل الحصة' else 'تم تعديل ' || n || ' حصص' end end,
        left((select string_agg(public.notif_session_line(x, 'ar'), ' | ') from unnest(r.sess) x), 400));
      cnt := cnt + 1;
    end loop;
  end if;
  -- coaches who were given these sessions by someone else
  for r in select d.coach_id, count(*) as k, (array_agg(d.club_id))[1] as club,
                  string_agg(public.notif_session_line(d.data, 'en'), ' | ' order by d.data ->> 'date') as l_en,
                  string_agg(public.notif_session_line(d.data, 'ar'), ' | ' order by d.data ->> 'date') as l_ar
             from public.docs d where d.collection = 'sessions' and d.id = any(p_ids) and d.coach_id is not null and d.coach_id <> actor
              and p_kind = 'coach' group by d.coach_id loop
    perform set_config('notif.ctx', jsonb_build_object('org', r.club, 'coach', r.coach_id)::text, true);
    perform public.notify(r.coach_id, 'booked_for_coach', 'week',
      case when r.k = 1 then 'A session was assigned to you' else r.k || ' sessions were assigned to you' end, left(r.l_en, 400),
      case when r.k = 1 then 'تم إسناد حصة إليك' else 'تم إسناد ' || r.k || ' حصص إليك' end, left(r.l_ar, 400));
    cnt := cnt + 1;
  end loop;
  return cnt;
end;
$$;
revoke execute on function public.bulk_session_notice(text[], text, boolean) from public, anon;
grant execute on function public.bulk_session_notice(text[], text, boolean) to authenticated;
