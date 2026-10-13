-- F11 centre operations: tenant isolation, immutable history and safe config.
-- Run after migrations through 028. The whole fixture rolls back.

\set owner_a   '\'f1100000-0000-4000-8000-000000000001\''
\set owner_b   '\'f1100000-0000-4000-8000-000000000002\''
\set doctor_a  '\'f1100000-0000-4000-8000-000000000003\''
\set doctor_b  '\'f1100000-0000-4000-8000-000000000004\''
\set patient_a '\'f1100000-0000-4000-8000-000000000005\''
\set patient_b '\'f1100000-0000-4000-8000-000000000006\''
\set admin     '\'f1100000-0000-4000-8000-000000000007\''

\set owner_a_jwt '{"sub":"f1100000-0000-4000-8000-000000000001","role":"authenticated"}'
\set owner_b_jwt '{"sub":"f1100000-0000-4000-8000-000000000002","role":"authenticated"}'
\set admin_jwt   '{"sub":"f1100000-0000-4000-8000-000000000007","role":"authenticated"}'

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
  begin execute statement;
  exception when others then raise notice 'PASS: %', label; return; end;
  raise exception 'FAIL: % (the statement was accepted)', label;
end $$;

insert into auth.users (id, instance_id, aud, role, email,
                        encrypted_password, created_at, updated_at)
values
  (:owner_a, '00000000-0000-0000-0000-000000000000', 'authenticated',
   'authenticated', 'f11-owner-a@example.com', '', now(), now()),
  (:owner_b, '00000000-0000-0000-0000-000000000000', 'authenticated',
   'authenticated', 'f11-owner-b@example.com', '', now(), now()),
  (:doctor_a, '00000000-0000-0000-0000-000000000000', 'authenticated',
   'authenticated', 'f11-doctor-a@example.com', '', now(), now()),
  (:doctor_b, '00000000-0000-0000-0000-000000000000', 'authenticated',
   'authenticated', 'f11-doctor-b@example.com', '', now(), now()),
  (:patient_a, '00000000-0000-0000-0000-000000000000', 'authenticated',
   'authenticated', 'f11-patient-a@example.com', '', now(), now()),
  (:patient_b, '00000000-0000-0000-0000-000000000000', 'authenticated',
   'authenticated', 'f11-patient-b@example.com', '', now(), now()),
  (:admin, '00000000-0000-0000-0000-000000000000', 'authenticated',
   'authenticated', 'f11-admin@example.com', '', now(), now());

select set_config('telomy.granting_role', 'yes', true);
update profiles set app_role = 'centre' where id in (:owner_a, :owner_b);
update profiles set app_role = 'doctor' where id in (:doctor_a, :doctor_b);
update profiles set app_role = 'admin' where id = :admin;
select set_config('telomy.granting_role', '', true);

select create_centre('F11 Centre A', :admin) as centre_a \gset
select create_centre('F11 Centre B', :admin) as centre_b \gset

insert into centre_memberships
  (centre_id, user_id, member_kind, status, invited_by, accepted_at)
values
  (:'centre_a', :owner_a, 'owner', 'active', :admin, now()),
  (:'centre_b', :owner_b, 'owner', 'active', :admin, now()),
  (:'centre_a', :doctor_a, 'doctor', 'active', :owner_a, now()),
  (:'centre_b', :doctor_b, 'doctor', 'active', :owner_b, now()),
  (:'centre_a', :patient_a, 'patient', 'active', :owner_a, now()),
  (:'centre_b', :patient_b, 'patient', 'active', :owner_b, now());

update centres
set timezone_name = 'Asia/Kolkata', currency_code = 'INR'
where id in (:'centre_a', :'centre_b');

select create_centre_room(:owner_a, :'centre_a', 'Therapy Suite') as room_a \gset
select create_centre_room(:owner_b, :'centre_b', 'Therapy Suite') as room_b \gset

select add_centre_room_hours(
  :owner_a, :'centre_a', :'room_a', 1, '09:00', '17:00', current_date, null
) as hours_a \gset
select add_centre_room_hours(
  :owner_b, :'centre_b', :'room_b', 1, '09:00', '17:00', current_date, null
) as hours_b \gset

select pg_temp.refuses(
  format(
    'select add_centre_room_hours(%L,%L,%L,1,%L,%L,current_date,null)',
    :owner_a, :'centre_a', :'room_a', '16:30', '18:00'
  ),
  'overlapping room hours are rejected'
);

select create_centre_service(
  :owner_a, :'centre_a', 'Red Light', 'Non-clinical session', 45, 149900, 'INR'
) as service_a \gset
select create_centre_service(
  :owner_b, :'centre_b', 'Red Light', 'Non-clinical session', 45, 159900, 'INR'
) as service_b \gset

select pg_temp.asserts(
  (select count(*) from centre_services where name = 'Red Light') = 2,
  'the same service name is allowed in different centres'
);

select pg_temp.refuses(
  format(
    'select create_centre_service(%L,%L,%L,null,30,10000,%L)',
    :owner_a, :'centre_a', 'RED LIGHT', 'INR'
  ),
  'an active service name is unique inside one centre'
);

select link_centre_room_service(
  :owner_a, :'centre_a', :'room_a', :'service_a'
) as link_a \gset
select link_centre_room_service(
  :owner_b, :'centre_b', :'room_b', :'service_b'
) as link_b \gset

insert into centre_bookings (
  centre_id, patient_id, service_id, room_id, scheduled_start, scheduled_end,
  status, service_name_snapshot, duration_minutes_snapshot,
  indicative_price_minor_snapshot, currency_code_snapshot, created_by
) values
  (:'centre_a', :patient_a, :'service_a', :'room_a',
   date_trunc('day', now()) + interval '1 day 10 hours',
   date_trunc('day', now()) + interval '1 day 10 hours 45 minutes',
   'booked', 'Red Light', 45, 149900, 'INR', :owner_a)
returning id as booking_a \gset

insert into centre_bookings (
  centre_id, patient_id, service_id, room_id, scheduled_start, scheduled_end,
  status, service_name_snapshot, duration_minutes_snapshot,
  indicative_price_minor_snapshot, currency_code_snapshot, created_by
) values
  (:'centre_b', :patient_b, :'service_b', :'room_b',
   date_trunc('day', now()) + interval '1 day 11 hours',
   date_trunc('day', now()) + interval '1 day 11 hours 45 minutes',
   'booked', 'Red Light', 45, 159900, 'INR', :owner_b)
returning id as booking_b \gset

insert into centre_booking_transitions (
  centre_id, booking_id, actor_id, from_status, to_status, command,
  expected_version
) values
  (:'centre_a', :'booking_a', :owner_a, null, 'booked', 'create', 0),
  (:'centre_b', :'booking_b', :owner_b, null, 'booked', 'create', 0);

select pg_temp.asserts(
  not has_table_privilege('authenticated', 'centre_rooms', 'INSERT')
  and not has_table_privilege('authenticated', 'centre_rooms', 'UPDATE')
  and not has_table_privilege('authenticated', 'centre_rooms', 'DELETE')
  and not has_table_privilege('authenticated', 'centre_room_hours', 'INSERT')
  and not has_table_privilege('authenticated', 'centre_room_hours', 'UPDATE')
  and not has_table_privilege('authenticated', 'centre_room_hours', 'DELETE')
  and not has_table_privilege('authenticated', 'centre_services', 'INSERT')
  and not has_table_privilege('authenticated', 'centre_services', 'UPDATE')
  and not has_table_privilege('authenticated', 'centre_services', 'DELETE')
  and not has_table_privilege('authenticated', 'centre_room_services', 'INSERT')
  and not has_table_privilege('authenticated', 'centre_room_services', 'UPDATE')
  and not has_table_privilege('authenticated', 'centre_room_services', 'DELETE')
  and not has_table_privilege('authenticated', 'centre_bookings', 'INSERT')
  and not has_table_privilege('authenticated', 'centre_bookings', 'UPDATE')
  and not has_table_privilege('authenticated', 'centre_bookings', 'DELETE')
  and not has_table_privilege('authenticated', 'centre_booking_transitions', 'INSERT')
  and not has_table_privilege('authenticated', 'centre_booking_transitions', 'UPDATE')
  and not has_table_privilege('authenticated', 'centre_booking_transitions', 'DELETE'),
  'authenticated has no direct operational DML privilege'
);

set local role authenticated;
set local request.jwt.claims = :'owner_a_jwt';

select pg_temp.asserts(
  (select count(*) from centre_rooms) = 1
  and (select count(*) from centre_room_hours) = 1
  and (select count(*) from centre_services) = 1
  and (select count(*) from centre_room_services) = 1
  and (select count(*) from centre_bookings) = 1
  and (select count(*) from centre_booking_transitions) = 1,
  'Centre A owner sees exactly Centre A operational rows'
);

select pg_temp.asserts(
  (select count(*) from centre_rooms where centre_id = :'centre_b') = 0
  and (select count(*) from centre_services where centre_id = :'centre_b') = 0
  and (select count(*) from centre_bookings where centre_id = :'centre_b') = 0
  and (select count(*) from centre_booking_transitions where centre_id = :'centre_b') = 0,
  'Centre A owner sees zero Centre B rows and aggregates'
);

reset role;
reset request.jwt.claims;

set local role authenticated;
set local request.jwt.claims = :'owner_b_jwt';

select pg_temp.asserts(
  (select count(*) from centre_rooms) = 1
  and (select count(*) from centre_services) = 1
  and (select count(*) from centre_bookings) = 1
  and (select count(*) from centre_rooms where centre_id = :'centre_a') = 0,
  'Centre B owner sees only Centre B operational rows'
);

reset role;
reset request.jwt.claims;

select set_centre_room_status(:owner_a, :'centre_a', :'room_a', 'inactive');
select set_centre_service_status(:owner_a, :'centre_a', :'service_a', 'inactive');

select pg_temp.asserts(
  (select status from centre_rooms where id = :'room_a') = 'inactive'
  and (select status from centre_services where id = :'service_a') = 'inactive'
  and (select count(*) from centre_bookings where id = :'booking_a') = 1
  and (select service_name_snapshot from centre_bookings where id = :'booking_a') = 'Red Light',
  'retirement preserves booking history and snapshots'
);

select pg_temp.refuses(
  format('delete from centre_bookings where id = %L', :'booking_a'),
  'booking history cannot be deleted'
);
select pg_temp.refuses(
  format('update centre_bookings set centre_id = %L where id = %L',
         :'centre_b', :'booking_a'),
  'booking tenant identity cannot be rewritten'
);
select pg_temp.refuses(
  format('delete from centre_booking_transitions where booking_id = %L',
         :'booking_a'),
  'booking transition history is append-only'
);

set local role authenticated;
set local request.jwt.claims = :'admin_jwt';
select pg_temp.asserts(
  (select count(*) from centre_rooms) = 2
  and (select count(*) from centre_bookings) = 2,
  'Super Admin can inspect both centres operationally'
);

rollback;
