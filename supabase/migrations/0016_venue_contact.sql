-- Venue address, Google Maps location and contact number.
-- The details live on each venue record (address, mapsUrl, phone); only club admins and sys admins can
-- change venues (see 0013). Players can't read venue records directly, so my_venues() gives them the
-- venues of the clubs they play in — for "Directions" and "Call" next to their sessions.
create or replace function public.my_venues()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', d.id, 'clubId', d.club_id, 'name', d.data ->> 'name',
           'address', coalesce(d.data ->> 'address', ''), 'mapsUrl', coalesce(d.data ->> 'mapsUrl', ''),
           'phone', coalesce(d.data ->> 'phone', ''), 'courts', coalesce(d.data -> 'courts', '[]'::jsonb))
         order by d.data ->> 'name'), '[]'::jsonb)
    from public.docs d
   where d.collection = 'venues'
     and auth.uid() is not null
     and (public.is_member(d.club_id)
          or d.club_id in (select cp.org_id from public.club_players cp
                             join public.docs t on t.collection = 'trainees' and t.id = cp.player_id
                            where t.data ->> 'linkedUserId' = auth.uid()::text));
$$;
revoke execute on function public.my_venues() from public, anon;
grant execute on function public.my_venues() to authenticated;
