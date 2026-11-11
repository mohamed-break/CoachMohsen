-- Padel 360 · migration 0005 · clubs, club admins, coaches, shared players
--   Sys admin  → creates clubs, names club admins, sees everything
--   Club admin → adds coaches and players to the club, assigns players to coaches,
--                sees everything in the club except coaches' private remarks and logs
--   Coach      → sees only players assigned to them and their own sessions
--   Player     → sees a 360 view of all coaches and clubs (player_360)
-- A player profile (name, phone, level, hand, side, account link) is shared; everything
-- a coach records (sessions, ratings, feedback, fixed slots, remarks, log) belongs to that coach.

------------------------------------------------------------------------------------------
-- 0. Safety copy of everything this migration changes (restore: supabase/rollback/restore_v1.sql)
------------------------------------------------------------------------------------------
create schema if not exists backup_v1;
revoke all on schema backup_v1 from public;
create table if not exists backup_v1.docs        as select * from public.docs;
create table if not exists backup_v1.user_roles  as select * from public.user_roles;

------------------------------------------------------------------------------------------
-- 1. Clubs, members, players in clubs, coach assignments
------------------------------------------------------------------------------------------
create table if not exists public.orgs (
  id           text primary key,
  name         text not null,
  is_freelance boolean not null default false,
  created_at   timestamptz not null default now()
);
create table if not exists public.org_members (
  org_id     text not null references public.orgs(id) on delete cascade,
  user_id    uuid not null references auth.users(id) on delete cascade,
  role       text not null check (role in ('club_admin', 'coach')),
  created_at timestamptz not null default now(),
  primary key (org_id, user_id, role)
);
create table if not exists public.club_players (
  org_id     text not null references public.orgs(id) on delete cascade,
  player_id  text not null,
  created_at timestamptz not null default now(),
  primary key (org_id, player_id)
);
create table if not exists public.enrollments (
  org_id     text not null references public.orgs(id) on delete cascade,
  player_id  text not null,
  coach_id   uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (org_id, player_id, coach_id)
);
alter table public.orgs         enable row level security;
alter table public.org_members  enable row level security;
alter table public.club_players enable row level security;
alter table public.enrollments  enable row level security;

alter table public.profiles add column if not exists full_name text;

------------------------------------------------------------------------------------------
-- 2. Who-is-who helpers (security definer so policies can call them without recursion)
------------------------------------------------------------------------------------------
create or replace function public.is_member(p_org text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.org_members where org_id = p_org and user_id = auth.uid());
$$;
create or replace function public.is_club_admin(p_org text)
returns boolean language sql stable security definer set search_path = public as $$
  select public.is_sysadmin() or exists (select 1 from public.org_members
    where org_id = p_org and user_id = auth.uid() and role = 'club_admin');
$$;
create or replace function public.is_coach_in(p_org text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.org_members where org_id = p_org and user_id = auth.uid() and role = 'coach');
$$;
-- "staff" = sys admin or member of any club (coach view of the app)
create or replace function public.is_staff()
returns boolean language sql stable security definer set search_path = public as $$
  select public.is_sysadmin() or exists (select 1 from public.org_members where user_id = auth.uid());
$$;
create or replace function public.can_see_player(p_player text)
returns boolean language sql stable security definer set search_path = public as $$
  select public.is_sysadmin()
      or exists (select 1 from public.enrollments e where e.player_id = p_player and e.coach_id = auth.uid())
      or exists (select 1 from public.club_players c join public.org_members m
                   on m.org_id = c.org_id and m.user_id = auth.uid() and m.role = 'club_admin'
                 where c.player_id = p_player);
$$;
create or replace function public.my_role()
returns text language sql stable security definer set search_path = public as $$
  select case when public.is_sysadmin() then 'sysadmin'
              when exists (select 1 from public.org_members where user_id = auth.uid()) then 'coach'
              else 'player' end;
$$;
create or replace function public.display_name(p_user uuid)
returns text language sql stable security definer set search_path = public as $$
  select coalesce(nullif(p.full_name, ''), split_part(p.email, '@', 1), '') from public.profiles p where p.id = p_user;
$$;
grant execute on function public.is_member(text), public.is_club_admin(text), public.is_coach_in(text),
  public.is_staff(), public.can_see_player(text), public.my_role(), public.display_name(uuid) to authenticated;

-- Profiles keep a display name too (Google and Apple give one).
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email, full_name)
  values (new.id, new.email, coalesce(new.raw_user_meta_data ->> 'full_name', new.raw_user_meta_data ->> 'name'))
  on conflict (id) do update set email = excluded.email,
    full_name = coalesce(excluded.full_name, public.profiles.full_name);
  if exists (select 1 from public.app_settings
             where key = 'sysadmin_email' and lower(value) = lower(new.email)) then
    insert into public.user_roles (user_id, role) values (new.id, 'sysadmin')
    on conflict (user_id) do update set role = 'sysadmin';
  end if;
  return new;
end;
$$;
update public.profiles p set full_name = coalesce(u.raw_user_meta_data ->> 'full_name', u.raw_user_meta_data ->> 'name')
  from auth.users u where u.id = p.id and p.full_name is null;

-- Read access to the club tables
drop policy if exists orgs_read on public.orgs;
create policy orgs_read on public.orgs for select to authenticated using (public.is_sysadmin() or public.is_member(id));
drop policy if exists org_members_read on public.org_members;
create policy org_members_read on public.org_members for select to authenticated
  using (user_id = auth.uid() or public.is_club_admin(org_id));
drop policy if exists club_players_read on public.club_players;
create policy club_players_read on public.club_players for select to authenticated
  using (public.is_club_admin(org_id) or exists (select 1 from public.enrollments e
         where e.org_id = club_players.org_id and e.player_id = club_players.player_id and e.coach_id = auth.uid()));
drop policy if exists enrollments_read on public.enrollments;
create policy enrollments_read on public.enrollments for select to authenticated
  using (coach_id = auth.uid() or public.is_club_admin(org_id));

------------------------------------------------------------------------------------------
-- 3. Documents: who owns each row
------------------------------------------------------------------------------------------
alter table public.docs add column if not exists club_id   text;
alter table public.docs add column if not exists coach_id  uuid;
alter table public.docs add column if not exists owner_uid uuid;
create index if not exists docs_club_idx  on public.docs (collection, club_id);
create index if not exists docs_coach_idx on public.docs (collection, coach_id);

-- The ownership columns always follow the document's own fields.
create or replace function public.docs_set_owner()
returns trigger language plpgsql as $$
begin
  new.club_id   := nullif(new.data ->> 'clubId', '');
  new.coach_id  := nullif(new.data ->> 'coachId', '')::uuid;
  new.owner_uid := nullif(new.data ->> 'playerUid', '')::uuid;
  return new;
end;
$$;
drop trigger if exists docs_owner on public.docs;
create trigger docs_owner before insert or update on public.docs
  for each row execute function public.docs_set_owner();

create or replace function public.doc_can_read(p_collection text, p_id text, p_club text, p_coach uuid, p_owner uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select public.is_sysadmin()
    or (p_collection = 'trainees'  and public.can_see_player(p_id))
    or (p_collection in ('sessions', 'blocks') and (p_coach = auth.uid() or public.is_club_admin(p_club)))
    or (p_collection in ('coachplayer', 'coachnotes', 'sessremarks') and p_coach = auth.uid())
    or (p_collection in ('skills', 'venues') and public.is_member(p_club))
    or (p_collection = 'requests' and (p_owner = auth.uid() or p_coach = auth.uid() or public.is_club_admin(p_club)));
$$;
create or replace function public.doc_can_write(p_collection text, p_id text, p_club text, p_coach uuid, p_owner uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select public.is_sysadmin()
    or (p_collection = 'trainees'  and public.can_see_player(p_id))
    or (p_collection in ('sessions', 'blocks') and p_club is not null
        and ((p_coach = auth.uid() and public.is_coach_in(p_club)) or public.is_club_admin(p_club)))
    or (p_collection in ('coachplayer', 'coachnotes', 'sessremarks') and p_coach = auth.uid())
    or (p_collection in ('skills', 'venues') and public.is_member(p_club))
    or (p_collection = 'requests' and (p_coach = auth.uid() or public.is_club_admin(p_club)));
$$;
grant execute on function public.doc_can_read(text, text, text, uuid, uuid), public.doc_can_write(text, text, text, uuid, uuid) to authenticated;

drop policy if exists docs_staff_all   on public.docs;
drop policy if exists docs_player_read on public.docs;
drop policy if exists docs_player_ins  on public.docs;
drop policy if exists docs_player_upd  on public.docs;
drop policy if exists docs_player_del  on public.docs;
drop policy if exists docs_read  on public.docs;
drop policy if exists docs_ins   on public.docs;
drop policy if exists docs_upd   on public.docs;
drop policy if exists docs_del   on public.docs;
create policy docs_read on public.docs for select to authenticated
  using (public.doc_can_read(collection, id, club_id, coach_id, owner_uid));
create policy docs_ins on public.docs for insert to authenticated
  with check (public.doc_can_write(collection, id, club_id, coach_id, owner_uid));
create policy docs_upd on public.docs for update to authenticated
  using (public.doc_can_write(collection, id, club_id, coach_id, owner_uid))
  with check (public.doc_can_write(collection, id, club_id, coach_id, owner_uid));
create policy docs_del on public.docs for delete to authenticated
  using (public.doc_can_write(collection, id, club_id, coach_id, owner_uid));

------------------------------------------------------------------------------------------
-- 4. Actions (each checks the caller's rights itself)
------------------------------------------------------------------------------------------
-- Who am I, and in which clubs?
create or replace function public.my_context()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'uid', auth.uid(),
    'sysadmin', public.is_sysadmin(),
    'memberships', coalesce((select jsonb_agg(jsonb_build_object('org', m.org_id, 'name', o.name, 'freelance', o.is_freelance, 'role', m.role) order by o.name, m.role)
                             from public.org_members m join public.orgs o on o.id = m.org_id where m.user_id = auth.uid()), '[]'::jsonb),
    'orgs', case when public.is_sysadmin() then coalesce((select jsonb_agg(jsonb_build_object('org', id, 'name', name, 'freelance', is_freelance) order by name) from public.orgs), '[]'::jsonb) else '[]'::jsonb end);
$$;

-- Club admins (and sys admins) list a club's people.
create or replace function public.club_people(p_org text)
returns table (user_id uuid, email text, name text, role text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_club_admin(p_org) and not public.is_member(p_org) then
    raise exception 'not a member of this club' using errcode = '42501';
  end if;
  return query select m.user_id, p.email, public.display_name(m.user_id), m.role
    from public.org_members m join public.profiles p on p.id = m.user_id
   where m.org_id = p_org and (public.is_club_admin(p_org) or m.role = 'coach') order by 3;
end;
$$;

-- Sys admins create and rename clubs. A new club starts with a copy of the default skills.
create or replace function public.save_org(p_id text, p_name text, p_freelance boolean)
returns text language plpgsql security definer set search_path = public as $$
declare v_id text := coalesce(nullif(trim(p_id), ''), 'c' || substr(md5(random()::text || clock_timestamp()::text), 1, 10));
begin
  if not public.is_sysadmin() then raise exception 'only a sys admin can manage clubs' using errcode = '42501'; end if;
  if coalesce(trim(p_name), '') = '' then raise exception 'club name is required' using errcode = '22023'; end if;
  insert into public.orgs (id, name, is_freelance) values (v_id, trim(p_name), coalesce(p_freelance, false))
  on conflict (id) do update set name = excluded.name, is_freelance = excluded.is_freelance;
  if not exists (select 1 from public.docs where collection = 'skills' and club_id = v_id) then
    insert into public.docs (collection, id, data)
    select 'skills', v_id || '-' || coalesce(d.data ->> 'id', d.id),
           d.data || jsonb_build_object('id', v_id || '-' || coalesce(d.data ->> 'id', d.id), 'clubId', v_id)
      from public.docs d where d.collection = 'skills' and d.club_id = 'freelance' and v_id <> 'freelance'
    on conflict do nothing;
  end if;
  return v_id;
end;
$$;

create or replace function public.delete_org(p_org text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_sysadmin() then raise exception 'only a sys admin can delete clubs' using errcode = '42501'; end if;
  if p_org = 'freelance' then raise exception 'the freelance club cannot be deleted' using errcode = '42501'; end if;
  if exists (select 1 from public.docs where collection = 'sessions' and club_id = p_org) then
    raise exception 'this club still has sessions; hand them over first' using errcode = '42501';
  end if;
  delete from public.docs where club_id = p_org and collection in ('skills', 'venues', 'blocks');
  delete from public.orgs where id = p_org;
end;
$$;

-- Add someone to a club by their sign-in email. Sys admins add club admins and coaches;
-- club admins add coaches.
create or replace function public.add_member(p_org text, p_email text, p_role text)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_user uuid;
begin
  if p_role not in ('club_admin', 'coach') then raise exception 'unknown role %', p_role using errcode = '22023'; end if;
  if not (public.is_sysadmin() or (p_role = 'coach' and public.is_club_admin(p_org))) then
    raise exception 'not allowed to add % to this club', p_role using errcode = '42501';
  end if;
  select id into v_user from public.profiles where lower(email) = lower(trim(p_email)) limit 1;
  if v_user is null then raise exception 'No account uses this email yet. Ask them to create an account first.' using errcode = 'P0002'; end if;
  insert into public.org_members (org_id, user_id, role) values (p_org, v_user, p_role) on conflict do nothing;
  return v_user;
end;
$$;

create or replace function public.remove_member(p_org text, p_user uuid, p_role text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not (public.is_sysadmin() or (p_role = 'coach' and public.is_club_admin(p_org))) then
    raise exception 'not allowed to remove this member' using errcode = '42501';
  end if;
  delete from public.org_members where org_id = p_org and user_id = p_user and role = p_role;
  if p_role = 'coach' then delete from public.enrollments where org_id = p_org and coach_id = p_user; end if;
end;
$$;

-- Create a new player profile in a club. A coach creating it is assigned automatically.
create or replace function public.create_player(p_org text, p_data jsonb)
returns text language plpgsql security definer set search_path = public as $$
declare v_id text := 'p' || substr(md5(random()::text || clock_timestamp()::text), 1, 12);
begin
  if not (public.is_club_admin(p_org) or public.is_coach_in(p_org)) then
    raise exception 'not a coach or club admin of this club' using errcode = '42501';
  end if;
  insert into public.docs (collection, id, data)
  values ('trainees', v_id, (p_data - 'fixedSlots' - 'showFeedback' - 'coachRemarks' - 'goals' - 'notes' - 'clubId' - 'coachId')
          || jsonb_build_object('id', v_id, 'linkedUserId', coalesce(p_data ->> 'linkedUserId', '')));
  insert into public.club_players (org_id, player_id) values (p_org, v_id);
  if public.is_coach_in(p_org) then
    insert into public.enrollments (org_id, player_id, coach_id) values (p_org, v_id, auth.uid()) on conflict do nothing;
  end if;
  return v_id;
end;
$$;

-- Add an existing person to a club by the email they signed up with. Reuses their player
-- profile if they already have one anywhere, so all coaches share it.
create or replace function public.add_player_by_email(p_org text, p_email text)
returns text language plpgsql security definer set search_path = public as $$
declare v_user uuid; v_name text; v_id text;
begin
  if not (public.is_club_admin(p_org) or public.is_coach_in(p_org)) then
    raise exception 'not a coach or club admin of this club' using errcode = '42501';
  end if;
  select id, coalesce(nullif(full_name, ''), split_part(email, '@', 1)) into v_user, v_name
    from public.profiles where lower(email) = lower(trim(p_email)) limit 1;
  if v_user is null then raise exception 'No account uses this email yet. Ask the player to create an account first.' using errcode = 'P0002'; end if;
  select id into v_id from public.docs where collection = 'trainees' and data ->> 'linkedUserId' = v_user::text limit 1;
  if v_id is null then
    v_id := 'p' || substr(md5(random()::text || clock_timestamp()::text), 1, 12);
    insert into public.docs (collection, id, data)
    values ('trainees', v_id, jsonb_build_object('id', v_id, 'name', v_name, 'linkedUserId', v_user::text, 'startDate', to_char(now(), 'YYYY-MM-DD')));
  end if;
  insert into public.club_players (org_id, player_id) values (p_org, v_id) on conflict do nothing;
  if public.is_coach_in(p_org) then
    insert into public.enrollments (org_id, player_id, coach_id) values (p_org, v_id, auth.uid()) on conflict do nothing;
  end if;
  return v_id;
end;
$$;

-- Club admins assign or unassign a player's coaches within their club.
create or replace function public.set_player_coaches(p_org text, p_player text, p_coaches uuid[])
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_club_admin(p_org) then raise exception 'only a club admin can assign coaches' using errcode = '42501'; end if;
  if not exists (select 1 from public.club_players where org_id = p_org and player_id = p_player) then
    raise exception 'player is not in this club' using errcode = '42501';
  end if;
  delete from public.enrollments where org_id = p_org and player_id = p_player and not (coach_id = any(coalesce(p_coaches, '{}')));
  insert into public.enrollments (org_id, player_id, coach_id)
  select p_org, p_player, c from unnest(coalesce(p_coaches, '{}')) c
   where exists (select 1 from public.org_members m where m.org_id = p_org and m.user_id = c and m.role = 'coach')
  on conflict do nothing;
end;
$$;

-- Remove a player: a club admin removes them from the club, a coach stops coaching them.
-- The shared profile is deleted only when no club or coach keeps it.
create or replace function public.remove_player(p_org text, p_player text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if public.is_club_admin(p_org) then
    delete from public.enrollments where org_id = p_org and player_id = p_player;
    delete from public.club_players where org_id = p_org and player_id = p_player;
  elsif public.is_coach_in(p_org) then
    delete from public.enrollments where org_id = p_org and player_id = p_player and coach_id = auth.uid();
  else
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if not exists (select 1 from public.club_players where player_id = p_player)
     and not exists (select 1 from public.enrollments where player_id = p_player) then
    delete from public.docs where collection = 'trainees' and id = p_player;
  end if;
end;
$$;

-- Hand everything one coach recorded in a club over to another coach (e.g. moving legacy data).
create or replace function public.hand_over(p_org text, p_from uuid, p_to uuid)
returns integer language plpgsql security definer set search_path = public as $$
declare n integer := 0; k integer;
begin
  if not public.is_club_admin(p_org) then raise exception 'only a club admin can hand over' using errcode = '42501'; end if;
  if not exists (select 1 from public.org_members where org_id = p_org and user_id = p_to and role = 'coach') then
    raise exception 'the new coach is not a coach in this club' using errcode = '22023';
  end if;
  update public.docs set data = data || jsonb_build_object('coachId', p_to::text), updated_at = now()
   where collection in ('sessions', 'blocks', 'coachnotes', 'sessremarks', 'requests') and club_id = p_org and coach_id = p_from;
  get diagnostics k = row_count; n := n + k;
  -- per-coach player records are keyed player@coach
  insert into public.docs (collection, id, data)
  select 'coachplayer', (d.data ->> 'playerId') || '@' || p_to::text, d.data || jsonb_build_object('coachId', p_to::text)
    from public.docs d
   where d.collection = 'coachplayer' and d.coach_id = p_from
     and exists (select 1 from public.club_players c where c.org_id = p_org and c.player_id = d.data ->> 'playerId')
  on conflict (collection, id) do nothing;
  delete from public.docs d where d.collection = 'coachplayer' and d.coach_id = p_from
     and exists (select 1 from public.club_players c where c.org_id = p_org and c.player_id = d.data ->> 'playerId');
  insert into public.enrollments (org_id, player_id, coach_id)
  select org_id, player_id, p_to from public.enrollments where org_id = p_org and coach_id = p_from on conflict do nothing;
  delete from public.enrollments where org_id = p_org and coach_id = p_from;
  return n;
end;
$$;

-- A player asks to cancel one of their sessions.
create or replace function public.request_cancel(p_session text, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare s record; v_player text;
begin
  select id into v_player from public.docs where collection = 'trainees' and data ->> 'linkedUserId' = auth.uid()::text limit 1;
  select * into s from public.docs where collection = 'sessions' and id = p_session;
  if v_player is null or s is null or not (s.data -> 'traineeIds' ? v_player) then
    raise exception 'this is not one of your sessions' using errcode = '42501';
  end if;
  insert into public.docs (collection, id, data) values ('requests', p_session || ':' || auth.uid()::text,
    jsonb_build_object('sessionId', p_session, 'playerUid', auth.uid()::text, 'playerId', v_player,
      'coachId', s.data ->> 'coachId', 'clubId', s.data ->> 'clubId', 'status', 'pending',
      'reason', coalesce(p_reason, ''), 'date', s.data ->> 'date', 'time', s.data ->> 'time',
      'at', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'), 'seen', true))
  on conflict (collection, id) do update set data = excluded.data, updated_at = now();
end;
$$;

-- A player dismisses a notice.
create or replace function public.ack_request(p_id text)
returns void language sql security definer set search_path = public as $$
  update public.docs set data = data || '{"seen": true}'::jsonb, updated_at = now()
   where collection = 'requests' and id = p_id and owner_uid = auth.uid();
$$;

-- The player's 360 view: every session with every coach in every club. Coaches' private
-- remarks are never included; comments and overall feedback only where that coach allows it.
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
        'duration', ss.data -> 'duration', 'location', coalesce(ss.data ->> 'location', ''),
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

grant execute on function public.my_context(), public.club_people(text), public.save_org(text, text, boolean), public.delete_org(text),
  public.add_member(text, text, text), public.remove_member(text, uuid, text), public.create_player(text, jsonb),
  public.add_player_by_email(text, text), public.set_player_coaches(text, text, uuid[]), public.remove_player(text, text),
  public.hand_over(text, uuid, uuid), public.request_cancel(text, text), public.ack_request(text), public.player_360() to authenticated;
revoke execute on function public.my_context(), public.club_people(text), public.save_org(text, text, boolean), public.delete_org(text),
  public.add_member(text, text, text), public.remove_member(text, uuid, text), public.create_player(text, jsonb),
  public.add_player_by_email(text, text), public.set_player_coaches(text, text, uuid[]), public.remove_player(text, text),
  public.hand_over(text, uuid, uuid), public.request_cancel(text, text), public.ack_request(text), public.player_360() from anon, public;

-- Global roles are now only "sysadmin"; coaching happens through club membership.
create or replace function public.set_user_role(p_user uuid, p_role text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_sysadmin() then raise exception 'only a sys admin can change roles' using errcode = '42501'; end if;
  if p_user = auth.uid() then raise exception 'you cannot change your own role' using errcode = '42501'; end if;
  if p_role = 'sysadmin' then
    insert into public.user_roles (user_id, role, updated_at, updated_by) values (p_user, 'sysadmin', now(), auth.uid())
    on conflict (user_id) do update set role = 'sysadmin', updated_at = now(), updated_by = auth.uid();
  elsif p_role in ('player', 'coach') then
    delete from public.user_roles where user_id = p_user;
  else
    raise exception 'unknown role %', p_role using errcode = '22023';
  end if;
end;
$$;

-- Deleting an account also removes its requests (owned rows) — memberships and assignments cascade.
create or replace function public.delete_user(p_user uuid)
returns integer language plpgsql security definer set search_path = public, auth as $$
declare unlinked integer;
begin
  if not public.is_sysadmin() then raise exception 'only a sys admin can delete accounts' using errcode = '42501'; end if;
  if p_user = auth.uid() then raise exception 'you cannot delete your own account' using errcode = '42501'; end if;
  update public.docs set data = jsonb_set(data, '{linkedUserId}', '""'::jsonb), updated_at = now()
   where collection = 'trainees' and data ->> 'linkedUserId' = p_user::text;
  get diagnostics unlinked = row_count;
  delete from public.docs where collection = 'requests' and owner_uid = p_user;
  delete from public.user_roles where user_id = p_user;
  delete from public.profiles where id = p_user;
  delete from auth.users where id = p_user;
  return unlinked;
end;
$$;

-- Live updates for the club tables
do $$ declare t text; begin
  foreach t in array array['org_members', 'club_players', 'enrollments'] loop
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;

------------------------------------------------------------------------------------------
-- 5. Move today's data into the "Freelance coaches" club
------------------------------------------------------------------------------------------
do $$
declare v_coach uuid; r record; tid text; fb jsonb; rem jsonb; sk text; v jsonb;
begin
  insert into public.orgs (id, name, is_freelance) values ('freelance', 'Freelance coaches', true) on conflict do nothing;

  -- the owner's account (SYSADMIN_EMAIL) holds today's data as coach; else an existing coach; else the first sys admin
  select u.id into v_coach from auth.users u join public.app_settings s on s.key = 'sysadmin_email' and lower(s.value) = lower(u.email) limit 1;
  if v_coach is null then select r2.user_id into v_coach from public.user_roles r2 join auth.users u on u.id = r2.user_id where r2.role = 'coach' order by u.created_at limit 1; end if;
  if v_coach is null then select r2.user_id into v_coach from public.user_roles r2 join auth.users u on u.id = r2.user_id where r2.role = 'sysadmin' order by u.created_at limit 1; end if;

  -- memberships: existing coaches become coaches of the freelance club; sys admins its club admins
  insert into public.org_members (org_id, user_id, role) select 'freelance', user_id, 'coach' from public.user_roles where role = 'coach' on conflict do nothing;
  insert into public.org_members (org_id, user_id, role) select 'freelance', user_id, 'club_admin' from public.user_roles where role = 'sysadmin' on conflict do nothing;
  if v_coach is not null then insert into public.org_members (org_id, user_id, role) values ('freelance', v_coach, 'coach') on conflict do nothing; end if;
  delete from public.user_roles where role = 'coach';

  -- venues (the old "clubs" list) and skills belong to the club
  insert into public.docs (collection, id, data)
  select 'venues', id, data || '{"clubId": "freelance"}'::jsonb from public.docs where collection = 'clubs' on conflict do nothing;
  delete from public.docs where collection = 'clubs';
  update public.docs set data = data || '{"clubId": "freelance"}'::jsonb where collection = 'skills' and club_id is null;

  -- players: shared profile + per-coach record + club and coach assignment
  for r in select id, data from public.docs where collection = 'trainees' loop
    insert into public.club_players (org_id, player_id) values ('freelance', r.id) on conflict do nothing;
    if v_coach is not null then
      insert into public.enrollments (org_id, player_id, coach_id) values ('freelance', r.id, v_coach) on conflict do nothing;
      insert into public.docs (collection, id, data) values ('coachplayer', r.id || '@' || v_coach::text,
        jsonb_build_object('playerId', r.id, 'coachId', v_coach::text, 'clubId', 'freelance',
          'fixedSlots', coalesce(r.data -> 'fixedSlots', '[]'::jsonb), 'showFeedback', coalesce(r.data -> 'showFeedback', 'false'::jsonb),
          'coachRemarks', coalesce(r.data ->> 'coachRemarks', ''), 'goals', coalesce(r.data ->> 'goals', ''), 'notes', coalesce(r.data ->> 'notes', '')))
      on conflict do nothing;
    end if;
    update public.docs set data = data - 'fixedSlots' - 'showFeedback' - 'coachRemarks' - 'goals' - 'notes' - 'inviteCode'
     where collection = 'trainees' and id = r.id;
  end loop;

  -- sessions: owner + club; private remarks move to the coach-only "sessremarks" record
  for r in select id, data from public.docs where collection = 'sessions' and club_id is null loop
    fb := coalesce(r.data -> 'feedback', '{}'::jsonb); rem := '{}'::jsonb;
    for tid in select jsonb_object_keys(fb) loop
      v := fb -> tid;
      if coalesce(v ->> 'remarks', '') <> '' then rem := jsonb_set(rem, array[tid], coalesce(rem -> tid, '{}'::jsonb) || jsonb_build_object('remarks', v ->> 'remarks')); end if;
      for sk in select jsonb_object_keys(coalesce(v -> 'skills', '{}'::jsonb)) loop
        if coalesce(v -> 'skills' -> sk ->> 'remark', '') <> '' then
          rem := jsonb_set(rem, array[tid], coalesce(rem -> tid, '{}'::jsonb));
          rem := jsonb_set(rem, array[tid, 'skills'], coalesce(rem -> tid -> 'skills', '{}'::jsonb) || jsonb_build_object(sk, v -> 'skills' -> sk ->> 'remark'));
          v := jsonb_set(v, array['skills', sk], (v -> 'skills' -> sk) - 'remark');
        end if;
      end loop;
      fb := jsonb_set(fb, array[tid], v - 'remarks');
    end loop;
    update public.docs set data = jsonb_set(data, '{feedback}', fb) || jsonb_build_object('clubId', 'freelance', 'coachId', coalesce(v_coach::text, ''))
     where collection = 'sessions' and id = r.id;
    if rem <> '{}'::jsonb and v_coach is not null then
      insert into public.docs (collection, id, data) values ('sessremarks', r.id,
        jsonb_build_object('sessionId', r.id, 'coachId', v_coach::text, 'clubId', 'freelance', 'byTrainee', rem))
      on conflict (collection, id) do update set data = excluded.data;
    end if;
  end loop;

  update public.docs set data = data || jsonb_build_object('clubId', 'freelance', 'coachId', coalesce(v_coach::text, ''))
   where collection in ('blocks', 'coachnotes') and club_id is null;

  -- retired: per-player copies (now computed by player_360), old link requests and old notices
  delete from public.docs where collection in ('progress', 'claims', 'requests');
end $$;
