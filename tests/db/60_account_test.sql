-- My account: name, display name, phone, photo path, email follow-up.
do $$ declare v uuid; begin
  select id into v from auth.users where email = 'player@coachmohsen.dev';
  perform set_config('request.jwt.claim.sub', v::text, false);
end $$;
set role authenticated;
select public.update_my_profile('Demo Player Full', 'DP', '+966 50 123 4567');
do $$ begin
  if (select display_name || '|' || full_name || '|' || phone from public.profiles where id = auth.uid()) <> 'DP|Demo Player Full|+966 50 123 4567' then raise exception 'profile not saved'; end if;
  if public.display_name(auth.uid()) <> 'DP' then raise exception 'display name not used'; end if;
  if (select data ->> 'phone' from public.docs where collection = 'trainees' and id = 'demo-player') <> '+966 50 123 4567' then raise exception 'player profile phone not synced'; end if;
  raise notice 'ok: profile saved and player profile follows';
  begin perform public.update_my_profile('x', 'y', 'call me'); raise exception 'bad phone accepted'; exception when sqlstate '22023' then raise notice 'ok: bad phone rejected'; end;
  perform public.set_my_avatar(auth.uid()::text || '/1.jpg');
  if (select avatar_path from public.profiles where id = auth.uid()) <> auth.uid()::text || '/1.jpg' then raise exception 'avatar'; end if;
  begin perform public.set_my_avatar('someone-else/1.jpg'); raise exception 'foreign avatar accepted'; exception when sqlstate '42501' then raise notice 'ok: only own photo'; end;
  perform public.set_my_avatar(null);
  if (select avatar_path from public.profiles where id = auth.uid()) is not null then raise exception 'avatar not removed'; end if;
  raise notice 'ok: photo set and removed';
end $$;
reset role;
update auth.users set email = 'player2@coachmohsen.dev' where email = 'player@coachmohsen.dev';
do $$ begin if not exists (select 1 from public.profiles where email = 'player2@coachmohsen.dev') then raise exception 'email not followed'; end if; raise notice 'ok: profile email follows a confirmed change'; end $$;
update auth.users set email = 'player@coachmohsen.dev' where email = 'player2@coachmohsen.dev';
