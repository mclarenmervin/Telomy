-- Centre tenancy must remain a separate axis from both platform role and
-- clinical signing membership. This file authenticates as real users so a
-- policy that looks correct but leaks a row still fails the test.
--
-- Run after migrations through 024:
--   psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f db/tests/centres_test.sql

\set owner_a  '\'c0a00000-0000-4000-8000-000000000001\''
\set owner_b  '\'c0a00000-0000-4000-8000-000000000002\''
\set doctor   '\'c0a00000-0000-4000-8000-000000000003\''
\set patient  '\'c0a00000-0000-4000-8000-000000000004\''
\set admin    '\'c0a00000-0000-4000-8000-000000000005\''

\set owner_a_jwt '{"sub":"c0a00000-0000-4000-8000-000000000001","role":"authenticated"}'
\set doctor_jwt  '{"sub":"c0a00000-0000-4000-8000-000000000003","role":"authenticated"}'

begin;

create or replace function pg_temp.asserts(ok boolean, label text)
returns void language plpgsql as $$
begin
  if ok then raise notice 'PASS: %', label;
  else raise exception 'FAIL: %', label; end if;
end $$;

create or replace function pg_temp.refuses(statement text, label text)
returns void language plpgsql as $$
begin
  begin
    execute statement;
  exception when others then
    raise notice 'PASS: %', label;
    return;
  end;
  raise exception 'FAIL: % (the statement was accepted)', label;
end $$;

insert into auth.users (id, instance_id, aud, role, email,
                        encrypted_password, created_at, updated_at)
values (:owner_a, '00000000-0000-0000-0000-000000000000', 'authenticated',
        'authenticated', 'centre-a-owner@example.com', '', now(), now()),
       (:owner_b, '00000000-0000-0000-0000-000000000000', 'authenticated',
        'authenticated', 'centre-b-owner@example.com', '', now(), now()),
       (:doctor, '00000000-0000-0000-0000-000000000000', 'authenticated',
        'authenticated', 'multi-centre-doctor@example.com', '', now(), now()),
       (:patient, '00000000-0000-0000-0000-000000000000', 'authenticated',
        'authenticated', 'centre-patient@example.com', '', now(), now()),
       (:admin, '00000000-0000-0000-0000-000000000000', 'authenticated',
        'authenticated', 'centre-admin@example.com', '', now(), now());

select set_config('telomy.granting_role', 'yes', true);
update profiles set app_role = 'centre' where id in (:owner_a, :owner_b);
update profiles set app_role = 'doctor' where id = :doctor;
update profiles set app_role = 'admin' where id = :admin;
select set_config('telomy.granting_role', '', true);

select pg_temp.refuses(
  format('select create_centre(%L, %L)', 'Forbidden Centre',
         'c0a00000-0000-4000-8000-000000000001'),
  'a Centre Owner cannot create another centre'
);

select create_centre('Centre A', :admin) as centre_a \gset
select create_centre('Centre B', :admin) as centre_b \gset

insert into centre_memberships
  (centre_id, user_id, member_kind, status, invited_by, accepted_at)
values
  (:'centre_a', :owner_a, 'owner', 'active', :admin, now()),
  (:'centre_b', :owner_b, 'owner', 'active', :admin, now()),
  (:'centre_a', :doctor, 'doctor', 'active', :owner_a, now()),
  (:'centre_b', :doctor, 'doctor', 'active', :owner_b, now()),
  (:'centre_a', :patient, 'patient', 'active', :owner_a, now());

select pg_temp.asserts(
  centre_owner_may_manage(:owner_a, :'centre_a'),
  'Centre A owner manages Centre A'
);

select pg_temp.asserts(
  not centre_owner_may_manage(:owner_a, :'centre_b'),
  'Centre A owner cannot manage Centre B'
);

select pg_temp.asserts(
  active_centre_membership(:doctor, :'centre_a', 'doctor')
  and active_centre_membership(:doctor, :'centre_b', 'doctor'),
  'one doctor may be active in two centres'
);

set local role authenticated;
set local request.jwt.claims = :'owner_a_jwt';

select pg_temp.asserts(
  (select count(*) from centres) = 1,
  'Centre A owner reads only their centre'
);

select pg_temp.asserts(
  (select count(*) from centre_memberships
    where centre_id = :'centre_b') = 0,
  'Centre A owner reads zero Centre B memberships'
);

select pg_temp.asserts(
  (select count(*) from centre_memberships
    where centre_id = :'centre_a') = 3,
  'Centre A owner reads their complete roster'
);

reset role;
reset request.jwt.claims;

update centre_memberships
set status = 'suspended', suspended_at = now()
where centre_id = :'centre_a' and user_id = :doctor
  and member_kind = 'doctor';

select pg_temp.asserts(
  not active_centre_membership(:doctor, :'centre_a', 'doctor')
  and active_centre_membership(:doctor, :'centre_b', 'doctor'),
  'suspension removes access immediately in one centre only'
);

select pg_temp.refuses(
  format('delete from centre_memberships where centre_id = %L and user_id = %L',
         :'centre_a', 'c0a00000-0000-4000-8000-000000000003'),
  'membership history is ended rather than deleted'
);

select pg_temp.refuses(
  format('update centre_memberships set centre_id = %L where centre_id = %L and user_id = %L',
         :'centre_b', :'centre_a', 'c0a00000-0000-4000-8000-000000000004'),
  'membership identity fields cannot be rewritten'
);

set local role authenticated;
set local request.jwt.claims = :'doctor_jwt';

select pg_temp.asserts(
  (select count(*) from centre_memberships where user_id = :doctor) = 2,
  'a doctor reads their own memberships in both centres'
);

select pg_temp.asserts(
  (select count(*) from centre_memberships where user_id <> :doctor) = 0,
  'a doctor cannot browse either centre roster'
);

rollback;
