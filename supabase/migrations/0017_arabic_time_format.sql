-- Arabic notifications show times as "06:00 م" (12-hour), kept left-to-right so the hours stay on the left —
-- the same as the Arabic interface. English keeps 24-hour "18:00".
create or replace function public.notif_tm(p_time text, p_lang text)
returns text language plpgsql immutable as $$
declare h int; m text;
begin
  if p_lang <> 'ar' or coalesce(p_time, '') !~ '^\d{1,2}:\d{2}' then return coalesce(p_time, ''); end if;
  h := split_part(p_time, ':', 1)::int % 24; m := substr(split_part(p_time, ':', 2), 1, 2);
  return chr(8294) || lpad(((h + 11) % 12 + 1)::text, 2, '0') || ':' || m || ' ' || case when h >= 12 then 'م' else 'ص' end || chr(8297);
end;
$$;

create or replace function public.notif_when(d jsonb, p_lang text)
returns text language plpgsql stable as $$
declare dt date; tm text := coalesce(nullif(d ->> 'time', ''), '');
  ar_days text[] := array['الأحد','الاثنين','الثلاثاء','الأربعاء','الخميس','الجمعة','السبت'];
begin
  if coalesce(d ->> 'date', '') !~ '^\d{4}-\d{2}-\d{2}$' then return tm; end if;
  dt := (d ->> 'date')::date;
  if p_lang = 'ar' then return trim(ar_days[extract(dow from dt)::int + 1] || ' ' || to_char(dt, 'DD/MM') || ' · ' || public.notif_tm(tm, 'ar'), ' ·'); end if;
  return trim(to_char(dt, 'Dy DD Mon') || ' · ' || tm, ' ·');
exception when others then return coalesce(d ->> 'date', '');
end;
$$;

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
                       from jsonb_array_elements_text(coalesce(s.data -> 'traineeIds', '[]')) x), ''), ' · ' order by s.data ->> 'time') as line,
                    string_agg(public.notif_tm(coalesce(s.data ->> 'time', ''), 'ar') || ' ' || coalesce((select string_agg(public.player_name(x), '، ')
                       from jsonb_array_elements_text(coalesce(s.data -> 'traineeIds', '[]')) x), ''), ' · ' order by s.data ->> 'time') as line_ar
               from public.docs s
              where s.collection = 'sessions' and s.coach_id is not null and coalesce(s.data ->> 'status', 'planned') = 'planned'
                and s.data ->> 'date' = to_char(local_now::date, 'YYYY-MM-DD')
              group by s.coach_id loop
      continue when not public.notif_once('sum:' || c.coach_id || ':' || to_char(local_now::date, 'YYYY-MM-DD'));
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
