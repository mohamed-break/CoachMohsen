-- Players page: each person's own order of players (drag and drop), per club.
-- Stored on the person's profile as {"<club id>": ["player id", ...]}.
alter table public.profiles add column if not exists player_order jsonb not null default '{}'::jsonb;

create or replace function public.my_player_order()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce((select player_order from public.profiles where id = auth.uid()), '{}'::jsonb);
$$;

create or replace function public.set_player_order(p_org text, p_ids text[])
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'sign in first' using errcode = '42501'; end if;
  if coalesce(p_org, '') = '' then raise exception 'club required' using errcode = '22023'; end if;
  if coalesce(array_length(p_ids, 1), 0) = 0 then
    update public.profiles set player_order = player_order - p_org where id = auth.uid();   -- back to A–Z
  else
    update public.profiles set player_order = player_order || jsonb_build_object(p_org, to_jsonb(p_ids[1:3000])) where id = auth.uid();
  end if;
end;
$$;
revoke execute on function public.my_player_order(), public.set_player_order(text, text[]) from public, anon;
grant execute on function public.my_player_order(), public.set_player_order(text, text[]) to authenticated;
