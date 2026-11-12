-- CoachMohsen · migration 0010 · join links: every coach (and every club) has a personal link. Whoever signs in through it becomes a player
-- of that club and of that coach straight away, named from their account (Google gives the full name).
-- Coaches fill in the rest of the player's details later.

create table if not exists public.join_codes (
  code       text primary key,
  org_id     text not null references public.orgs(id) on delete cascade,
  coach_id   uuid,                    -- null: a club link (player joins the club without a coach)
  created_by uuid,
  created_at timestamptz not null default now()
);
create unique index if not exists join_codes_owner on public.join_codes (org_id, coalesce(coach_id, '00000000-0000-0000-0000-000000000000'::uuid));
alter table public.join_codes enable row level security;  -- reached only through the functions below

-- The account's name: what the person typed, else what Google (or Apple) gave, else the start of the email.
create or replace function public.account_name(p_user uuid)
returns text language sql stable security definer set search_path = public, auth as $$
  select coalesce(nullif(trim(p.display_name), ''), nullif(trim(p.full_name), ''),
                  nullif(trim(u.raw_user_meta_data ->> 'full_name'), ''), nullif(trim(u.raw_user_meta_data ->> 'name'), ''),
                  split_part(coalesce(p.email, u.email), '@', 1))
    from auth.users u left join public.profiles p on p.id = u.id where u.id = p_user;
$$;

-- Keep the profile's full name filled from the sign-in provider when it is still empty
-- (new accounts, and accounts that later sign in with Google for the first time).
create or replace function public.fill_name_from_provider()
returns trigger language plpgsql security definer set search_path = public as $$
declare v text := nullif(trim(coalesce(new.raw_user_meta_data ->> 'full_name', new.raw_user_meta_data ->> 'name', '')), '');
begin
  if v is not null then
    update public.profiles set full_name = v where id = new.id and nullif(trim(coalesce(full_name, '')), '') is null;
    update public.docs set data = data || jsonb_build_object('name', v), updated_at = now()
     where collection = 'trainees' and data ->> 'linkedUserId' = new.id::text and nullif(trim(coalesce(data ->> 'name', '')), '') is null;
  end if;
  return new;
end;
$$;
drop trigger if exists on_auth_user_meta_changed on auth.users;
create trigger on_auth_user_meta_changed after update of raw_user_meta_data on auth.users
  for each row execute function public.fill_name_from_provider();

-- Fill names for accounts that already exist.
update public.profiles p set full_name = nullif(trim(coalesce(u.raw_user_meta_data ->> 'full_name', u.raw_user_meta_data ->> 'name', '')), '')
  from auth.users u where u.id = p.id and nullif(trim(coalesce(p.full_name, '')), '') is null
   and nullif(trim(coalesce(u.raw_user_meta_data ->> 'full_name', u.raw_user_meta_data ->> 'name', '')), '') is not null;

-- My link for a club: coaches get their own coach link; club admins who do not coach get the club link.
create or replace function public.my_join_code(p_org text, p_renew boolean default false)
returns text language plpgsql security definer set search_path = public as $$
declare v_coach uuid; v_code text;
begin
  if public.is_coach_in(p_org) then v_coach := auth.uid();
  elsif public.is_club_admin(p_org) then v_coach := null;
  else raise exception 'only coaches and club admins have invite links' using errcode = '42501'; end if;
  select code into v_code from public.join_codes where org_id = p_org and coach_id is not distinct from v_coach;
  if v_code is not null and not p_renew then return v_code; end if;
  if v_code is not null then delete from public.join_codes where code = v_code; end if;
  v_code := lower(substr(translate(encode(extensions.gen_random_bytes(9), 'base64'), '+/=', 'xyz'), 1, 10));
  insert into public.join_codes (code, org_id, coach_id, created_by) values (v_code, p_org, v_coach, auth.uid());
  return v_code;
end;
$$;

-- What the invite shows before signing in: the club and the coach, nothing else.
create or replace function public.join_info(p_code text)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('club', o.name, 'coach', case when j.coach_id is null then null else public.display_name(j.coach_id) end)
    from public.join_codes j join public.orgs o on o.id = j.org_id where j.code = lower(trim(p_code));
$$;

-- Signed in through a link: become a player of that club (and coach). Re-using a link does nothing new.
create or replace function public.join_with_code(p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare j record; v_uid uuid := auth.uid(); v_pid text; v_name text; v_new boolean := false;
begin
  if v_uid is null then raise exception 'sign in first' using errcode = '42501'; end if;
  select * into j from public.join_codes where code = lower(trim(p_code));
  if not found then raise exception 'JOIN_INVALID: this invite link is no longer valid' using errcode = 'P0001'; end if;
  select id into v_pid from public.docs where collection = 'trainees' and data ->> 'linkedUserId' = v_uid::text limit 1;
  if v_pid is null then
    v_name := public.account_name(v_uid); v_new := true;
    v_pid := 'p' || substr(md5(random()::text || clock_timestamp()::text), 1, 12);
    insert into public.docs (collection, id, data) values ('trainees', v_pid, jsonb_strip_nulls(jsonb_build_object(
      'id', v_pid, 'name', v_name, 'phone', (select phone from public.profiles where id = v_uid),
      'startDate', to_char(current_date, 'YYYY-MM-DD'), 'linkedUserId', v_uid::text)));
  end if;
  insert into public.club_players (org_id, player_id) values (j.org_id, v_pid) on conflict do nothing;
  if j.coach_id is not null and exists (select 1 from public.org_members where org_id = j.org_id and user_id = j.coach_id and role = 'coach') then
    insert into public.enrollments (org_id, player_id, coach_id) values (j.org_id, v_pid, j.coach_id) on conflict do nothing;
  end if;
  return jsonb_build_object('playerId', v_pid, 'newPlayer', v_new, 'club', (select name from public.orgs where id = j.org_id),
                            'coach', case when j.coach_id is null then null else public.display_name(j.coach_id) end);
end;
$$;

grant execute on function public.my_join_code(text, boolean), public.join_with_code(text) to authenticated;
grant execute on function public.join_info(text) to anon, authenticated;
revoke execute on function public.my_join_code(text, boolean), public.join_with_code(text), public.account_name(uuid) from anon, public;
