-- Players withdraw and resend cancellation requests.
\set ON_ERROR_STOP 1
create or replace function pg_temp.ok(c boolean, msg text) returns void language plpgsql as $$
begin if c is not true then raise exception 'FAILED: %', msg; end if; raise notice 'ok: %', msg; end $$;
-- a player linked to a profile, booked into a session
insert into auth.users (id, email) values ('00000000-0000-4000-8000-0000000000e1', 'withdraw.me@example.com');
insert into public.docs (collection, id, data) values
  ('trainees', 'pw1', '{"id":"pw1","name":"W Player","linkedUserId":"00000000-0000-4000-8000-0000000000e1"}'),
  ('sessions', 'sw1', jsonb_build_object('id','sw1','date','2027-02-01','time','18:00','status','planned','traineeIds',jsonb_build_array('pw1'),
     'clubId',(select id from public.orgs order by id limit 1),'coachId',(select user_id from public.org_members where role='coach' limit 1)));
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-0000000000e1', false);
set role authenticated;
select public.request_cancel('sw1', 'Travel');
select pg_temp.ok((select data ->> 'status' from public.docs where collection = 'requests' and id = 'sw1:00000000-0000-4000-8000-0000000000e1') = 'pending', 'request sent');
select pg_temp.ok(public.withdraw_request('sw1'), 'request withdrawn');
select pg_temp.ok(not exists (select 1 from public.docs where collection = 'requests' and id like 'sw1:%'), 'the request is gone');
select public.request_cancel('sw1', 'Sick');
select public.request_cancel('sw1', 'Sick, resent');
select pg_temp.ok((select data ->> 'reason' from public.docs where collection = 'requests' and id = 'sw1:00000000-0000-4000-8000-0000000000e1') = 'Sick, resent', 'a new request and a resend work');
reset role;
update public.docs set data = data || '{"status":"declined"}' where collection = 'requests' and id = 'sw1:00000000-0000-4000-8000-0000000000e1';
set role authenticated;
select pg_temp.ok(not public.withdraw_request('sw1'), 'a decided request cannot be withdrawn');
reset role;
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-0000000000e9', false);
set role authenticated;
select pg_temp.ok(not public.withdraw_request('sw1'), 'nobody else can withdraw it');
reset role;
