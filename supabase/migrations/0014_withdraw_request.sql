-- CoachMohsen · migration 0014
-- A player withdraws their own pending cancellation request; they can send a new one afterwards.
create or replace function public.withdraw_request(p_session text)
returns boolean language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if auth.uid() is null then raise exception 'sign in first' using errcode = '42501'; end if;
  delete from public.docs
   where collection = 'requests' and id = p_session || ':' || auth.uid()::text
     and owner_uid = auth.uid() and data ->> 'status' = 'pending';
  get diagnostics n = row_count;
  return n > 0;
end;
$$;
grant execute on function public.withdraw_request(text) to authenticated;
revoke execute on function public.withdraw_request(text) from anon, public;
