-- Subscriptions (packages of sessions), recorded by hand for now; online payment can come later.
--   • package_prices: per club (coach_key = '') and per coach (coach_key = coach's id): price for individual and
--     group sessions, and validity in days, for 1, 4, 8, 12 … sessions. SAR, VAT included.
--   • subscriptions: one row per package a player buys from one coach (one package per coach at a time is the
--     normal case; older ones stay as history). Price can be overridden for the player, with a reason.
--   • club_players.makeup_eligible: may the player get a make-up session after an approved cancellation
--     (empty = the club's default, settings.newPlayersMakeupEligible, normally yes).
--   • Who manages: sys admins, club admins, and the club's default coach when settings.defaultCoachManagesSubs.
--   • Usage is worked out from the sessions themselves (package_usage):
--       completed or past session → used · future session → booked · coach cancelled / player excused → not counted
--       player's cancellation approved → counted only when it was "charged" (player not eligible for make-up)
--     Sessions are matched to the player's packages with that coach oldest first; a session after a package's
--     end date can't use it; sessions with no room left are "without a package" and go to the next package.
------------------------------------------------------------------------------------------
create table if not exists public.package_prices (
  org_id        text not null references public.orgs(id) on delete cascade,
  coach_key     text not null default '',
  sessions      int  not null check (sessions between 1 and 200),
  single_price  numeric(10,2),
  group_price   numeric(10,2),
  validity_days int check (validity_days is null or validity_days between 1 and 3650),
  updated_at    timestamptz not null default now(),
  primary key (org_id, coach_key, sessions)
);
alter table public.package_prices enable row level security;
revoke all on public.package_prices from anon, authenticated;

create table if not exists public.subscriptions (
  id           uuid primary key default gen_random_uuid(),
  org_id       text not null references public.orgs(id) on delete cascade,
  coach_id     uuid not null,
  player_id    text not null,
  kind         text not null default 'single' check (kind in ('single', 'group')),
  sessions     int  not null check (sessions between 1 and 200),
  start_date   date not null,
  end_date     date,
  list_price   numeric(10,2),
  price        numeric(10,2) not null default 0,
  price_reason text,
  pay_status   text not null default 'unpaid' check (pay_status in ('paid', 'partial', 'unpaid')),
  paid_amount  numeric(10,2),
  pay_method   text,
  notes        text,
  created_by   uuid,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create index if not exists subscriptions_player_idx on public.subscriptions (player_id, coach_id, start_date);
create index if not exists subscriptions_org_idx on public.subscriptions (org_id, created_at);
alter table public.subscriptions enable row level security;
revoke all on public.subscriptions from anon, authenticated;

alter table public.club_players add column if not exists makeup_eligible boolean;

------------------------------------------------------------------------------------------
-- Permissions
------------------------------------------------------------------------------------------
create or replace function public.can_manage_subs(p_org text)
returns boolean language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and (public.is_sysadmin() or public.is_club_admin(p_org)
    or exists (select 1 from public.orgs o where o.id = p_org
                and o.settings ->> 'defaultCoach' = auth.uid()::text
                and coalesce((o.settings ->> 'defaultCoachManagesSubs')::boolean, false)
                and exists (select 1 from public.org_members m where m.org_id = o.id and m.user_id = auth.uid() and m.role = 'coach')));
$$;

-- Club settings: + defaultCoachManagesSubs, newPlayersMakeupEligible
create or replace function public.set_club_settings(p_org text, p_settings jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare clean jsonb := '{}'::jsonb; res jsonb; dc text; k text;
begin
  if not (public.is_sysadmin() or public.is_club_admin(p_org)) then
    raise exception 'Only club admins can change club settings' using errcode = '42501';
  end if;
  foreach k in array array['suggestPlanned', 'defaultCoachManagesSubs', 'newPlayersMakeupEligible'] loop
    if jsonb_typeof(p_settings -> k) = 'boolean' then clean := clean || jsonb_build_object(k, p_settings -> k); end if;
  end loop;
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

------------------------------------------------------------------------------------------
-- Price list
------------------------------------------------------------------------------------------
create or replace function public.price_list(p_org text)
returns jsonb language sql stable security definer set search_path = public as $$
  select case when public.is_sysadmin() or public.is_member(p_org) then
    coalesce((select jsonb_agg(jsonb_build_object('coach', coach_key, 'sessions', sessions, 'single', single_price, 'group', group_price, 'validity', validity_days)
                               order by coach_key, sessions) from public.package_prices where org_id = p_org), '[]'::jsonb)
  else '[]'::jsonb end;
$$;

-- Replace the price list of the club (p_coach null) or of one coach; rows: [{sessions, single, group, validity}]
create or replace function public.set_price_list(p_org text, p_coach uuid, p_rows jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r jsonb; key text := coalesce(p_coach::text, '');
begin
  if not public.can_manage_subs(p_org) then raise exception 'You cannot change the prices of this club' using errcode = '42501'; end if;
  if p_coach is not null and not exists (select 1 from public.org_members where org_id = p_org and user_id = p_coach and role = 'coach') then
    raise exception 'Not a coach of this club' using errcode = '22023';
  end if;
  delete from public.package_prices where org_id = p_org and coach_key = key;
  for r in select * from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) loop
    continue when coalesce((r ->> 'sessions')::int, 0) < 1;
    continue when r ->> 'single' is null and r ->> 'group' is null;
    insert into public.package_prices (org_id, coach_key, sessions, single_price, group_price, validity_days)
    values (p_org, key, (r ->> 'sessions')::int, nullif(r ->> 'single', '')::numeric, nullif(r ->> 'group', '')::numeric, nullif(r ->> 'validity', '')::int)
    on conflict (org_id, coach_key, sessions) do update set single_price = excluded.single_price, group_price = excluded.group_price,
      validity_days = excluded.validity_days, updated_at = now();
  end loop;
  return public.price_list(p_org);
end;
$$;

------------------------------------------------------------------------------------------
-- Make-up eligibility (per player, per club)
------------------------------------------------------------------------------------------
create or replace function public.makeup_eligible(p_org text, p_player text)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select makeup_eligible from public.club_players where org_id = p_org and player_id = p_player),
                  (select coalesce((settings ->> 'newPlayersMakeupEligible')::boolean, true) from public.orgs where id = p_org), true);
$$;

create or replace function public.set_makeup_eligible(p_org text, p_player text, p_value boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.can_manage_subs(p_org) then raise exception 'You cannot change make-up eligibility' using errcode = '42501'; end if;
  update public.club_players set makeup_eligible = p_value where org_id = p_org and player_id = p_player;
  if not found then raise exception 'This player is not in the club' using errcode = 'P0002'; end if;
end;
$$;

------------------------------------------------------------------------------------------
-- Recording packages
------------------------------------------------------------------------------------------
create or replace function public.save_subscription(p jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid := nullif(p ->> 'id', '')::uuid; v_org text := p ->> 'org'; old public.subscriptions; v_coach uuid := nullif(p ->> 'coach', '')::uuid;
  v_sessions int := (p ->> 'sessions')::int; v_start date := nullif(p ->> 'start', '')::date; v_end date := nullif(p ->> 'end', '')::date;
begin
  if v_id is not null then
    select * into old from public.subscriptions where id = v_id;
    if old.id is null then raise exception 'Package not found' using errcode = 'P0002'; end if;
    v_org := old.org_id;
  end if;
  if not public.can_manage_subs(v_org) then raise exception 'You cannot record packages in this club' using errcode = '42501'; end if;
  if v_coach is null or not exists (select 1 from public.org_members where org_id = v_org and user_id = v_coach and role = 'coach') then
    raise exception 'Choose a coach of this club' using errcode = '22023';
  end if;
  if not exists (select 1 from public.club_players where org_id = v_org and player_id = p ->> 'player') then
    raise exception 'This player is not in the club' using errcode = '22023';
  end if;
  if v_sessions is null or v_sessions < 1 then raise exception 'Enter the number of sessions' using errcode = '22023'; end if;
  if v_start is null then raise exception 'Enter the start date' using errcode = '22023'; end if;
  if v_end is not null and v_end < v_start then raise exception 'The end date is before the start date' using errcode = '22023'; end if;
  if coalesce((p ->> 'price')::numeric, -1) < 0 then raise exception 'Enter the price' using errcode = '22023'; end if;
  if v_id is null then
    insert into public.subscriptions (org_id, coach_id, player_id, kind, sessions, start_date, end_date, list_price, price, price_reason,
                                      pay_status, paid_amount, pay_method, notes, created_by)
    values (v_org, v_coach, p ->> 'player', coalesce(nullif(p ->> 'kind', ''), 'single'), v_sessions, v_start, v_end,
            nullif(p ->> 'listPrice', '')::numeric, (p ->> 'price')::numeric, nullif(trim(coalesce(p ->> 'reason', '')), ''),
            coalesce(nullif(p ->> 'payStatus', ''), 'unpaid'), nullif(p ->> 'paid', '')::numeric, nullif(p ->> 'method', ''), nullif(p ->> 'notes', ''), auth.uid())
    returning id into v_id;
  else
    update public.subscriptions set coach_id = v_coach, kind = coalesce(nullif(p ->> 'kind', ''), kind), sessions = v_sessions, start_date = v_start, end_date = v_end,
      list_price = nullif(p ->> 'listPrice', '')::numeric, price = (p ->> 'price')::numeric, price_reason = nullif(trim(coalesce(p ->> 'reason', '')), ''),
      pay_status = coalesce(nullif(p ->> 'payStatus', ''), pay_status), paid_amount = nullif(p ->> 'paid', '')::numeric,
      pay_method = nullif(p ->> 'method', ''), notes = nullif(p ->> 'notes', ''), updated_at = now()
    where id = v_id;
  end if;
  return v_id;
end;
$$;

create or replace function public.delete_subscription(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_org text;
begin
  select org_id into v_org from public.subscriptions where id = p_id;
  if v_org is null then raise exception 'Package not found' using errcode = 'P0002'; end if;
  if not public.can_manage_subs(v_org) then raise exception 'You cannot delete packages in this club' using errcode = '42501'; end if;
  delete from public.subscriptions where id = p_id;
end;
$$;

------------------------------------------------------------------------------------------
-- Usage: packages of a player with what has been used, booked and is left
------------------------------------------------------------------------------------------
create or replace function public.package_usage(p_player text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  me uuid := auth.uid(); puid text; pair record; u record; pk jsonb; pks jsonb[]; i int; placed boolean;
  out_pk jsonb := '[]'::jsonb; out_un jsonb := '[]'::jsonb; elig jsonb := '{}'::jsonb; un_n int; un_dates jsonb; today date := (now() at time zone 'Asia/Riyadh')::date;
begin
  if me is null then return null; end if;
  select data ->> 'linkedUserId' into puid from public.docs where collection = 'trainees' and id = p_player;
  -- each club + coach the player has sessions or packages with, that this person may see
  for pair in
    select distinct x.org_id, x.coach_id from (
      select s.org_id, s.coach_id from public.subscriptions s where s.player_id = p_player
      union select d.club_id, d.coach_id from public.docs d
       where d.collection = 'sessions' and d.coach_id is not null and d.club_id is not null and d.data -> 'traineeIds' ? p_player) x
    where public.is_sysadmin() or public.can_manage_subs(x.org_id) or x.coach_id = me or puid = me::text
  loop
    pks := array(select jsonb_build_object('id', s.id, 'org_id', s.org_id, 'coach_id', s.coach_id, 'kind', s.kind, 'sessions', s.sessions,
                   'start_date', s.start_date, 'end_date', s.end_date, 'list_price', s.list_price, 'price', s.price, 'price_reason', s.price_reason,
                   'pay_status', s.pay_status, 'paid_amount', s.paid_amount, 'pay_method', s.pay_method, 'notes', s.notes, 'created_at', s.created_at,
                   'created_by_name', public.notif_person(s.created_by), 'coach_name', public.notif_person(s.coach_id), 'org_name', o.name,
                   'used', 0, 'booked', 0, 'charged', 0)
                 from public.subscriptions s left join public.orgs o on o.id = s.org_id
                where s.player_id = p_player and s.org_id = pair.org_id and s.coach_id = pair.coach_id
                order by s.start_date, s.created_at);
    un_n := 0; un_dates := '[]'::jsonb;
    for u in
      select d.id, d.data ->> 'date' as dt, d.data ->> 'time' as tm, d.data ->> 'status' as st,
             public.session_at(d.data) as at, d.data -> 'excused' ? p_player as excused,
             (select r.data from public.docs r where r.collection = 'requests' and r.id = d.id || ':' || coalesce(puid, '-') and r.data ->> 'status' = 'approved') as req
        from public.docs d
       where d.collection = 'sessions' and d.club_id = pair.org_id and d.coach_id = pair.coach_id and d.data -> 'traineeIds' ? p_player
         and coalesce(d.data ->> 'date', '') ~ '^\d{4}-\d{2}-\d{2}$'
       order by d.data ->> 'date', d.data ->> 'time'
    loop
      -- does this session count for the player?
      if u.req is not null then
        continue when not coalesce((u.req ->> 'charged')::boolean, false);
      elsif coalesce(u.st, 'planned') = 'cancelled' or coalesce(u.excused, false) then
        continue;
      end if;
      placed := false;
      if pks is not null then
        for i in 1 .. coalesce(array_length(pks, 1), 0) loop
          pk := pks[i];
          continue when (pk ->> 'used')::int + (pk ->> 'booked')::int >= (pk ->> 'sessions')::int;
          continue when pk ->> 'end_date' is not null and u.dt::date > (pk ->> 'end_date')::date;
          if u.req is not null or coalesce(u.st, 'planned') = 'done' or (u.at is not null and u.at < now()) then
            pks[i] := pk || jsonb_build_object('used', (pk ->> 'used')::int + 1, 'charged', (pk ->> 'charged')::int + case when u.req is not null then 1 else 0 end);
          else
            pks[i] := pk || jsonb_build_object('booked', (pk ->> 'booked')::int + 1);
          end if;
          placed := true; exit;
        end loop;
      end if;
      if not placed then un_n := un_n + 1; un_dates := un_dates || jsonb_build_array(jsonb_build_object('id', u.id, 'date', u.dt, 'time', u.tm)); end if;
    end loop;
    if pks is not null then
      for i in 1 .. coalesce(array_length(pks, 1), 0) loop
        pk := pks[i];
        out_pk := out_pk || jsonb_build_array(pk || jsonb_build_object(
          'remaining', (pk ->> 'sessions')::int - (pk ->> 'used')::int,
          'unbooked', (pk ->> 'sessions')::int - (pk ->> 'used')::int - (pk ->> 'booked')::int,
          'state', case when (pk ->> 'used')::int >= (pk ->> 'sessions')::int then 'finished'
                        when pk ->> 'end_date' is not null and (pk ->> 'end_date')::date < today then 'expired'
                        when (pk ->> 'start_date')::date > today then 'upcoming' else 'active' end));
      end loop;
    end if;
    if un_n > 0 then
      out_un := out_un || jsonb_build_array(jsonb_build_object('org_id', pair.org_id, 'coach_id', pair.coach_id, 'coach_name', public.notif_person(pair.coach_id),
                                                               'count', un_n, 'sessions', un_dates));
    end if;
  end loop;
  select coalesce(jsonb_object_agg(cp.org_id, public.makeup_eligible(cp.org_id, p_player)), '{}'::jsonb) into elig
    from public.club_players cp where cp.player_id = p_player;
  return jsonb_build_object('packages', out_pk, 'unpackaged', out_un, 'eligible', elig);
end;
$$;

-- Club overview for those who manage subscriptions: every package and players with unpackaged sessions
create or replace function public.subs_overview(p_org text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare r record; u jsonb; pk jsonb; pkgs jsonb := '[]'::jsonb; unp jsonb := '[]'::jsonb; month_start date := date_trunc('month', (now() at time zone 'Asia/Riyadh'))::date;
begin
  if not public.can_manage_subs(p_org) then raise exception 'You cannot see the subscriptions of this club' using errcode = '42501'; end if;
  for r in select cp.player_id, coalesce(d.data ->> 'name', '—') as name from public.club_players cp
             left join public.docs d on d.collection = 'trainees' and d.id = cp.player_id where cp.org_id = p_org loop
    u := public.package_usage(r.player_id);
    for pk in select * from jsonb_array_elements(coalesce(u -> 'packages', '[]'::jsonb)) loop
      continue when pk ->> 'org_id' <> p_org;
      pkgs := pkgs || jsonb_build_array(pk || jsonb_build_object('player_id', r.player_id, 'player_name', r.name));
    end loop;
    for pk in select * from jsonb_array_elements(coalesce(u -> 'unpackaged', '[]'::jsonb)) loop
      continue when pk ->> 'org_id' <> p_org;
      unp := unp || jsonb_build_array(pk || jsonb_build_object('player_id', r.player_id, 'player_name', r.name));
    end loop;
  end loop;
  return jsonb_build_object('packages', pkgs, 'unpackaged', unp,
    'revenue', jsonb_build_object('month', to_char(month_start, 'YYYY-MM'),
       'total', coalesce((select sum(price) from public.subscriptions where org_id = p_org and created_at >= month_start), 0),
       'byCoach', coalesce((select jsonb_agg(jsonb_build_object('coach_id', coach_id, 'coach_name', public.notif_person(coach_id), 'total', t) order by t desc)
                             from (select coach_id, sum(price) t from public.subscriptions where org_id = p_org and created_at >= month_start group by coach_id) z), '[]'::jsonb)));
end;
$$;

revoke execute on function public.can_manage_subs(text), public.price_list(text), public.set_price_list(text, uuid, jsonb), public.makeup_eligible(text, text),
  public.set_makeup_eligible(text, text, boolean), public.save_subscription(jsonb), public.delete_subscription(uuid), public.package_usage(text),
  public.subs_overview(text) from public, anon;
grant execute on function public.can_manage_subs(text), public.price_list(text), public.set_price_list(text, uuid, jsonb), public.makeup_eligible(text, text),
  public.set_makeup_eligible(text, text, boolean), public.save_subscription(jsonb), public.delete_subscription(uuid), public.package_usage(text),
  public.subs_overview(text) to authenticated;
