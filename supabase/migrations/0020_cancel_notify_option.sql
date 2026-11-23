-- Cancelling a session: the coach or club admin chooses whether the players are told.
-- The app saves notifyPlayers = false on the session when they choose not to; the cancellation
-- notice also carries the reason when one was given.
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
