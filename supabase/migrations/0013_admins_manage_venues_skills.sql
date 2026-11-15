-- CoachMohsen · migration 0013
-- Venues (with their courts) and skills belong to a club and are managed only by that club's admins
-- and sys admins. Coaches still read them and pick them when booking.
create or replace function public.doc_can_write(p_collection text, p_id text, p_club text, p_coach uuid, p_owner uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select public.is_sysadmin()
    or (p_collection = 'trainees'  and public.can_see_player(p_id))
    or (p_collection in ('sessions', 'blocks') and p_club is not null
        and ((p_coach = auth.uid() and public.is_coach_in(p_club)) or public.is_club_admin(p_club)))
    or (p_collection in ('coachplayer', 'coachnotes', 'sessremarks') and p_coach = auth.uid())
    or (p_collection in ('skills', 'venues') and p_club is not null and public.is_club_admin(p_club))
    or (p_collection = 'requests' and (p_coach = auth.uid() or public.is_club_admin(p_club)));
$$;
