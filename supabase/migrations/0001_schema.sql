-- Padel360 · migration 0001 · applied by .github/workflows/deploy.yml (or paste into Supabase → SQL Editor)
-- Mirrors the storage of the original Claude app: one table of JSON documents
-- grouped by collection, with the same access rules:
--   coaches (emails listed in public.staff) read and write everything;
--   a signed-in player reads only progress/<own id>, and reads/writes
--   requests/<own id> and claims/<own id>.

create table if not exists public.docs (
  collection text not null,
  id         text not null,
  data       jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  primary key (collection, id)
);

create table if not exists public.staff (
  email text primary key,
  added_at timestamptz not null default now()
);

create table if not exists public.profiles (
  id    uuid primary key references auth.users(id) on delete cascade,
  email text,
  created_at timestamptz not null default now()
);

-- Is the signed-in user a coach?
create or replace function public.is_staff()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.staff
    where lower(email) = lower(coalesce(auth.jwt() ->> 'email', ''))
  );
$$;
grant execute on function public.is_staff() to authenticated;

-- Keep a profile row (id + email) for every account, so the coach can see who is linked.
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email) values (new.id, new.email)
  on conflict (id) do update set email = excluded.email;
  return new;
end;
$$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert or update of email on auth.users
  for each row execute function public.handle_new_user();
insert into public.profiles (id, email) select id, email from auth.users
on conflict (id) do update set email = excluded.email;

-- Deep merge used by "update": nested objects merge, everything else replaces.
create or replace function public.jsonb_deep_merge(a jsonb, b jsonb)
returns jsonb language sql immutable as $$
  select case
    when jsonb_typeof(a) = 'object' and jsonb_typeof(b) = 'object' then (
      select coalesce(jsonb_object_agg(k,
        case when a ? k and b ? k then public.jsonb_deep_merge(a -> k, b -> k)
             when b ? k then b -> k else a -> k end), '{}'::jsonb)
      from (select jsonb_object_keys(a) as k union select jsonb_object_keys(b)) keys)
    else b end;
$$;

-- update(): merge a patch into an existing document; fails if it doesn't exist.
-- Runs with the caller's rights, so the row rules below still apply.
create or replace function public.doc_merge(p_collection text, p_id text, p_patch jsonb)
returns void language plpgsql security invoker set search_path = public as $$
begin
  update public.docs
     set data = public.jsonb_deep_merge(data, p_patch), updated_at = now()
   where collection = p_collection and id = p_id;
  if not found then
    raise exception 'document %/% does not exist', p_collection, p_id using errcode = 'P0002';
  end if;
end;
$$;
grant execute on function public.doc_merge(text, text, jsonb) to authenticated;

-- Row-level security
alter table public.docs     enable row level security;
alter table public.staff    enable row level security;
alter table public.profiles enable row level security;

drop policy if exists docs_staff_all   on public.docs;
drop policy if exists docs_player_read on public.docs;
drop policy if exists docs_player_ins  on public.docs;
drop policy if exists docs_player_upd  on public.docs;
drop policy if exists docs_player_del  on public.docs;

create policy docs_staff_all on public.docs for all to authenticated
  using (public.is_staff()) with check (public.is_staff());

create policy docs_player_read on public.docs for select to authenticated
  using (collection in ('progress','requests','claims') and id = auth.uid()::text);

create policy docs_player_ins on public.docs for insert to authenticated
  with check (collection in ('requests','claims') and id = auth.uid()::text);

create policy docs_player_upd on public.docs for update to authenticated
  using (collection in ('requests','claims') and id = auth.uid()::text)
  with check (collection in ('requests','claims') and id = auth.uid()::text);

create policy docs_player_del on public.docs for delete to authenticated
  using (collection in ('requests','claims') and id = auth.uid()::text);

drop policy if exists staff_read on public.staff;
create policy staff_read on public.staff for select to authenticated using (public.is_staff());

drop policy if exists profiles_read on public.profiles;
create policy profiles_read on public.profiles for select to authenticated
  using (id = auth.uid() or public.is_staff());

-- Live updates
alter table public.docs replica identity full;
do $$ begin
  if not exists (select 1 from pg_publication_tables
                 where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'docs') then
    alter publication supabase_realtime add table public.docs;
  end if;
end $$;
