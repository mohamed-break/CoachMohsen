-- CoachMohsen · migration 0011
-- Users page: register any signed-up account as a player in one tap. The profile is named from the
-- account (Google name when there is one) and joins the club; coaches are assigned later.

-- Which accounts already have a player profile (any club), for the Users page.
create or replace function public.linked_players()
returns table (user_id uuid, player_id text, player_name text)
language sql stable security definer set search_path = public as $$
  select (d.data ->> 'linkedUserId')::uuid, d.id, d.data ->> 'name'
    from public.docs d
   where public.is_sysadmin() and d.collection = 'trainees'
     and coalesce(d.data ->> 'linkedUserId', '') ~ '^[0-9a-f-]{36}$';
$$;

create or replace function public.register_user_as_player(p_org text, p_user uuid)
returns text language plpgsql security definer set search_path = public as $$
declare v_pid text;
begin
  if not public.is_sysadmin() then raise exception 'only a sys admin can register players here' using errcode = '42501'; end if;
  if not exists (select 1 from public.orgs where id = p_org) then raise exception 'unknown club' using errcode = '22023'; end if;
  if not exists (select 1 from auth.users where id = p_user) then raise exception 'unknown account' using errcode = '22023'; end if;
  select id into v_pid from public.docs where collection = 'trainees' and data ->> 'linkedUserId' = p_user::text limit 1;
  if v_pid is null then
    v_pid := 'p' || substr(md5(random()::text || clock_timestamp()::text), 1, 12);
    insert into public.docs (collection, id, data) values ('trainees', v_pid, jsonb_strip_nulls(jsonb_build_object(
      'id', v_pid, 'name', public.account_name(p_user), 'phone', (select phone from public.profiles where id = p_user),
      'startDate', to_char(current_date, 'YYYY-MM-DD'), 'linkedUserId', p_user::text)));
  end if;
  insert into public.club_players (org_id, player_id) values (p_org, v_pid) on conflict do nothing;
  return v_pid;
end;
$$;

grant execute on function public.linked_players(), public.register_user_as_player(text, uuid) to authenticated;
revoke execute on function public.linked_players(), public.register_user_as_player(text, uuid) from anon, public;
