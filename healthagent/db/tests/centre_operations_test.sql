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

select set_clinical_access_consent(
  :patient_a, :'centre_a', :patient_a, true, 'clinical_care'
) as active_consent_a \gset
select pg_temp.asserts(
  centre_can_read_clinical(:owner_a, :'centre_a', :patient_a),
  'an unexpired patient consent admits the centre owner'
);
select pg_temp.refuses(
  format(
    'update clinical_access_consents set expires_at = expires_at + interval %L where id = %L',
    '1 year', :'active_consent_a'
  ),
  'a granted consent expiry cannot be rewritten'
);

insert into clinical_access_consents (
  patient_id, centre_id, purpose, granted_by, granted_at,
  expires_at, provenance
) values (
  :patient_b, :'centre_b', 'clinical_care', :patient_b,
  now() - interval '2 years', now() - interval '1 year',
  '{"source":"expiry_fixture"}'::jsonb
) returning id as expired_consent_b, granted_at as expired_granted_at \gset
select pg_temp.asserts(
  not centre_can_read_clinical(:owner_b, :'centre_b', :patient_b),
  'expiration removes the patient from centre clinical visibility'
);

select set_clinical_access_consent(
  :patient_b, :'centre_b', :patient_b, true, 'clinical_care'
) as renewed_consent_b \gset
select pg_temp.asserts(
  :'renewed_consent_b' <> :'expired_consent_b'
  and (select count(*) from clinical_access_consents
       where patient_id = :patient_b and centre_id = :'centre_b') = 2
  and (select granted_at = :'expired_granted_at'::timestamptz
       from clinical_access_consents where id = :'expired_consent_b')
  and centre_can_read_clinical(:owner_b, :'centre_b', :patient_b),
  'renewal appends a new grant without rewriting the prior grant'
);

select set_clinical_access_consent(
  :patient_b, :'centre_b', :patient_b, false, 'clinical_care'
);
select pg_temp.asserts(
  not centre_can_read_clinical(:owner_b, :'centre_b', :patient_b),
  'revocation removes the patient on the next authorization check'
);

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

-- 2030-01-07 is a Monday. Use a fixed centre-local date so the availability
-- assertions do not depend on the database server's timezone.
select create_centre_booking(
  :owner_a, :'centre_a', :patient_a, :'service_a', :'room_a',
  '2030-01-07 10:00 Asia/Kolkata'::timestamptz
) as booking_a \gset
select create_centre_booking(
  :owner_b, :'centre_b', :patient_b, :'service_b', :'room_b',
  '2030-01-07 11:00 Asia/Kolkata'::timestamptz
) as booking_b \gset

select pg_temp.refuses(
  format(
    'select create_centre_booking(%L,%L,%L,%L,%L,%L::timestamptz)',
    :owner_a, :'centre_a', :patient_a, :'service_a', :'room_a',
    '2030-01-07 17:00 Asia/Kolkata'
  ),
  'booking outside configured availability is rejected'
);

select create_centre_service(
  :owner_a, :'centre_a', 'Unlinked Service', null, 30, 99900, 'INR'
) as unlinked_service \gset
select pg_temp.refuses(
  format(
    'select create_centre_booking(%L,%L,%L,%L,%L,%L::timestamptz)',
    :owner_a, :'centre_a', :patient_a, :'unlinked_service', :'room_a',
    '2030-01-07 12:00 Asia/Kolkata'
  ),
  'booking an incompatible room and service is rejected'
);
select pg_temp.refuses(
  format(
    'select create_centre_booking(%L,%L,%L,%L,%L,%L::timestamptz)',
    :owner_a, :'centre_a', :patient_b, :'service_a', :'room_a',
    '2030-01-07 12:00 Asia/Kolkata'
  ),
  'booking a patient from another centre is rejected'
);
select pg_temp.refuses(
  format(
    'select create_centre_booking(%L,%L,%L,%L,%L,%L::timestamptz)',
    :owner_a, :'centre_a', :patient_a, :'service_a', :'room_a',
    '2030-01-07 10:15 Asia/Kolkata'
  ),
  'overlapping room booking is rejected'
);

select create_centre_room(:owner_a, :'centre_a', 'Retired Room') as retired_room \gset
select add_centre_room_hours(
  :owner_a, :'centre_a', :'retired_room', 1, '09:00', '17:00', current_date, null
) as retired_room_hours \gset
select link_centre_room_service(
  :owner_a, :'centre_a', :'retired_room', :'service_a'
) as retired_room_link \gset
select set_centre_room_status(
  :owner_a, :'centre_a', :'retired_room', 'inactive'
);
select pg_temp.refuses(
  format(
    'select create_centre_booking(%L,%L,%L,%L,%L,%L::timestamptz)',
    :owner_a, :'centre_a', :patient_a, :'service_a', :'retired_room',
    '2030-01-07 12:00 Asia/Kolkata'
  ),
  'booking an inactive room is rejected'
);

select create_centre_service(
  :owner_a, :'centre_a', 'Retired Service', null, 30, 129900, 'INR'
) as retired_service \gset
select link_centre_room_service(
  :owner_a, :'centre_a', :'room_a', :'retired_service'
) as retired_service_link \gset
select set_centre_service_status(
  :owner_a, :'centre_a', :'retired_service', 'inactive'
);
select pg_temp.refuses(
  format(
    'select create_centre_booking(%L,%L,%L,%L,%L,%L::timestamptz)',
    :owner_a, :'centre_a', :patient_a, :'retired_service', :'room_a',
    '2030-01-07 12:00 Asia/Kolkata'
  ),
  'booking an inactive service is rejected'
);

update centre_services
set name = 'Red Light Updated', duration_minutes = 60,
    indicative_price_minor = 179900, updated_by = :owner_a
where id = :'service_a';
select pg_temp.asserts(
  (select service_name_snapshot = 'Red Light'
          and duration_minutes_snapshot = 45
          and indicative_price_minor_snapshot = 149900
   from centre_bookings where id = :'booking_a'),
  'booking service, duration, and indicative price snapshots are immutable'
);

-- Restore the configured values for the remaining booking-state fixtures.
update centre_services
set name = 'Red Light', duration_minutes = 45,
    indicative_price_minor = 149900, updated_by = :owner_a
where id = :'service_a';

-- Valid transition paths.
select create_centre_booking(
  :owner_a, :'centre_a', :patient_a, :'service_a', :'room_a',
  '2030-01-07 11:00 Asia/Kolkata'::timestamptz
) as checkin_complete_booking \gset
select transition_centre_booking(
  :owner_a, :'centre_a', :'checkin_complete_booking', 'check_in', 0, null
);
select transition_centre_booking(
  :owner_a, :'centre_a', :'checkin_complete_booking', 'complete', 1, null
);
select pg_temp.asserts(
  (select status = 'completed' and version = 2
   from centre_bookings where id = :'checkin_complete_booking'),
  'booked to checked-in to completed is accepted'
);
select pg_temp.refuses(
  format(
    'select transition_centre_booking(%L,%L,%L,%L,2,null)',
    :owner_a, :'centre_a', :'checkin_complete_booking', 'cancel'
  ),
  'completed bookings reject further transitions'
);

select create_centre_booking(
  :owner_a, :'centre_a', :patient_a, :'service_a', :'room_a',
  '2030-01-07 12:00 Asia/Kolkata'::timestamptz
) as booked_cancel_booking \gset
select transition_centre_booking(
  :owner_a, :'centre_a', :'booked_cancel_booking', 'cancel', 0, null
);
select pg_temp.asserts(
  (select status = 'cancelled' and version = 1
   from centre_bookings where id = :'booked_cancel_booking'),
  'booked to cancelled is accepted'
);
select pg_temp.refuses(
  format(
    'select transition_centre_booking(%L,%L,%L,%L,1,null)',
    :owner_a, :'centre_a', :'booked_cancel_booking', 'check_in'
  ),
  'cancelled bookings reject further transitions'
);

select create_centre_booking(
  :owner_a, :'centre_a', :patient_a, :'service_a', :'room_a',
  '2030-01-07 13:00 Asia/Kolkata'::timestamptz
) as checkedin_cancel_booking \gset
select transition_centre_booking(
  :owner_a, :'centre_a', :'checkedin_cancel_booking', 'check_in', 0, null
);
select pg_temp.refuses(
  format(
    'select transition_centre_booking(%L,%L,%L,%L,1,null)',
    :owner_a, :'centre_a', :'checkedin_cancel_booking', 'cancel'
  ),
  'cancelling after check-in requires a reason'
);
select transition_centre_booking(
  :owner_a, :'centre_a', :'checkedin_cancel_booking', 'cancel', 1,
  'Patient requested cancellation'
);
select pg_temp.asserts(
  (select status = 'cancelled' and cancellation_reason is not null
   from centre_bookings where id = :'checkedin_cancel_booking'),
  'checked-in to cancelled is accepted with a reason'
);

-- Invalid edges and stale optimistic versions.
select create_centre_booking(
  :owner_a, :'centre_a', :patient_a, :'service_a', :'room_a',
  '2030-01-07 14:00 Asia/Kolkata'::timestamptz
) as invalid_edge_booking \gset
select pg_temp.refuses(
  format(
    'select transition_centre_booking(%L,%L,%L,%L,0,null)',
    :owner_a, :'centre_a', :'invalid_edge_booking', 'complete'
  ),
  'booked to completed is rejected'
);
select transition_centre_booking(
  :owner_a, :'centre_a', :'invalid_edge_booking', 'check_in', 0, null
);
select pg_temp.refuses(
  format(
    'select transition_centre_booking(%L,%L,%L,%L,1,null)',
    :owner_a, :'centre_a', :'invalid_edge_booking', 'mark_no_show'
  ),
  'checked-in to no-show is rejected'
);
select pg_temp.refuses(
  format(
    'select transition_centre_booking(%L,%L,%L,%L,0,%L)',
    :owner_a, :'centre_a', :'invalid_edge_booking', 'cancel', 'stale'
  ),
  'a stale expected booking version is rejected'
);

-- Use direct fixture inserts to put starts precisely around the grace boundary;
-- now() is transaction-stable, so these two assertions cannot drift mid-test.
insert into centre_bookings (
  centre_id, patient_id, service_id, room_id, scheduled_start, scheduled_end,
  status, service_name_snapshot, duration_minutes_snapshot,
  indicative_price_minor_snapshot, currency_code_snapshot, created_by
) values (
  :'centre_a', :patient_a, :'service_a', :'room_a',
  now() - interval '14 minutes 59 seconds', now() + interval '30 minutes 1 second',
  'booked', 'Red Light', 45, 149900, 'INR', :owner_a
) returning id as before_grace_booking \gset
insert into centre_booking_transitions (
  centre_id, booking_id, actor_id, from_status, to_status, command, expected_version
) values (
  :'centre_a', :'before_grace_booking', :owner_a, null, 'booked', 'create', 0
);
select pg_temp.refuses(
  format(
    'select transition_centre_booking(%L,%L,%L,%L,0,null)',
    :owner_a, :'centre_a', :'before_grace_booking', 'mark_no_show'
  ),
  'no-show is rejected immediately before the 15-minute boundary'
);

insert into centre_bookings (
  centre_id, patient_id, service_id, room_id, scheduled_start, scheduled_end,
  status, service_name_snapshot, duration_minutes_snapshot,
  indicative_price_minor_snapshot, currency_code_snapshot, created_by
) values (
  :'centre_a', :patient_a, :'service_a', :'room_a',
  now() - interval '15 minutes', now() + interval '30 minutes',
  'booked', 'Red Light', 45, 149900, 'INR', :owner_a
) returning id as at_grace_booking \gset
insert into centre_booking_transitions (
  centre_id, booking_id, actor_id, from_status, to_status, command, expected_version
) values (
  :'centre_a', :'at_grace_booking', :owner_a, null, 'booked', 'create', 0
);
select transition_centre_booking(
  :owner_a, :'centre_a', :'at_grace_booking', 'mark_no_show', 0, null
);
select pg_temp.asserts(
  (select status = 'no_show' from centre_bookings where id = :'at_grace_booking'),
  'no-show is accepted at the 15-minute boundary'
);

select pg_temp.refuses(
  format(
    'select transition_centre_booking(%L,%L,%L,%L,1,null)',
    :owner_a, :'centre_a', :'at_grace_booking', 'cancel'
  ),
  'no-show bookings reject further transitions'
);
select pg_temp.asserts(
  (select count(*) from centre_booking_transitions
   where booking_id = :'checkin_complete_booking') = 3,
  'every successful booking transition is appended to history'
);

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
  (select count(*) from centre_rooms) >= 1
  and (select count(*) from centre_room_hours) >= 1
  and (select count(*) from centre_services) >= 1
  and (select count(*) from centre_room_services) >= 1
  and (select count(*) from centre_bookings) >= 1
  and (select count(*) from centre_booking_transitions) >= 1
  and not exists (select 1 from centre_rooms where centre_id <> :'centre_a')
  and not exists (select 1 from centre_services where centre_id <> :'centre_a')
  and not exists (select 1 from centre_bookings where centre_id <> :'centre_a'),
  'Centre A owner sees only Centre A operational rows'
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
  (select count(distinct centre_id) from centre_rooms) = 2
  and (select count(distinct centre_id) from centre_bookings) = 2,
  'Super Admin can inspect both centres operationally'
);

rollback;
