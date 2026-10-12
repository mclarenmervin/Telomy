-- Doctor assignment, patient consent, Super Admin read and audit invariants.

\set owner_a    '\'c0c00000-0000-4000-8000-000000000001\''
\set owner_b    '\'c0c00000-0000-4000-8000-000000000002\''
\set doctor_a   '\'c0c00000-0000-4000-8000-000000000003\''
\set doctor_b   '\'c0c00000-0000-4000-8000-000000000004\''
\set unverified '\'c0c00000-0000-4000-8000-000000000005\''
\set patient_a  '\'c0c00000-0000-4000-8000-000000000006\''
\set patient_b  '\'c0c00000-0000-4000-8000-000000000007\''
\set admin      '\'c0c00000-0000-4000-8000-000000000008\''

\set owner_a_jwt '{"sub":"c0c00000-0000-4000-8000-000000000001","role":"authenticated"}'
\set admin_jwt   '{"sub":"c0c00000-0000-4000-8000-000000000008","role":"authenticated"}'

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

create or replace function pg_temp.affects(statement text, expected bigint, label text)
returns void language plpgsql as $$
declare changed bigint;
begin
  execute statement;
  get diagnostics changed = row_count;
  if changed = expected then raise notice 'PASS: %', label;
  else raise exception 'FAIL: % (affected %, expected %)', label, changed, expected;
  end if;
end $$;

insert into auth.users (id, instance_id, aud, role, email,
                        encrypted_password, created_at, updated_at)
values (:owner_a, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'access-owner-a@example.com', '', now(), now()),
       (:owner_b, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'access-owner-b@example.com', '', now(), now()),
       (:doctor_a, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'access-doctor-a@example.com', '', now(), now()),
       (:doctor_b, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'access-doctor-b@example.com', '', now(), now()),
       (:unverified, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'access-unverified@example.com', '', now(), now()),
       (:patient_a, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'access-patient-a@example.com', '', now(), now()),
       (:patient_b, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'access-patient-b@example.com', '', now(), now()),
       (:admin, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'access-admin@example.com', '', now(), now());

select set_config('telomy.granting_role', 'yes', true);
update profiles set app_role = 'centre' where id in (:owner_a, :owner_b);
update profiles set app_role = 'doctor' where id in (:doctor_a, :doctor_b, :unverified);
update profiles set app_role = 'admin' where id = :admin;
select set_config('telomy.granting_role', '', true);

select create_centre('Access Centre A', :admin) as centre_a \gset
select create_centre('Access Centre B', :admin) as centre_b \gset

insert into centre_memberships
  (centre_id, user_id, member_kind, status, invited_by, accepted_at)
values
  (:'centre_a', :owner_a, 'owner', 'active', :admin, now()),
  (:'centre_b', :owner_b, 'owner', 'active', :admin, now()),
  (:'centre_a', :doctor_a, 'doctor', 'active', :admin, now()),
  (:'centre_a', :doctor_b, 'doctor', 'active', :admin, now()),
  (:'centre_a', :unverified, 'doctor', 'active', :admin, now()),
  (:'centre_a', :patient_a, 'patient', 'active', :owner_a, now()),
  (:'centre_b', :patient_b, 'patient', 'active', :owner_b, now());

select record_clinician_verification(:admin, :doctor_a, 'verified', 'verified',
  'REG-C0C-A', 'Medical Council', now() + interval '1 year');
select record_clinician_verification(:admin, :doctor_b, 'verified', 'verified',
  'REG-C0C-B', 'Medical Council', now() + interval '1 year');

select assign_patient_doctor(
  :owner_a, :'centre_a', :patient_a, :doctor_a, true
) as assignment_a \gset
select assign_patient_doctor(
  :owner_a, :'centre_a', :patient_a, :doctor_b, false
) as assignment_b \gset

select pg_temp.asserts(
  doctor_can_read_patient(:doctor_a, :'centre_a', :patient_a)
  and doctor_can_read_patient(:doctor_b, :'centre_a', :patient_a),
  'multiple assigned verified Doctors can read one Patient'
);

select pg_temp.asserts(
  not doctor_can_read_patient(:doctor_a, :'centre_a', :patient_b),
  'a valid Doctor cannot browse an unassigned Patient'
);

select pg_temp.asserts(
  not doctor_can_read_patient(:unverified, :'centre_a', :patient_a),
  'an unverified Doctor cannot read a Patient'
);

select set_primary_doctor(
  :owner_a, :'centre_a', :patient_a, :doctor_b
) as primary_b \gset

select pg_temp.asserts(
  (select count(*) from patient_doctor_assignments
    where centre_id = :'centre_a' and patient_id = :patient_a
      and is_primary and ended_at is null) = 1
  and (select doctor_id from patient_doctor_assignments
       where centre_id = :'centre_a' and patient_id = :patient_a
         and is_primary and ended_at is null) = :doctor_b,
  'reassignment leaves exactly one active primary Doctor'
);

select pg_temp.asserts(
  not doctor_can_read_patient(:doctor_a, :'centre_a', :patient_a)
  and doctor_can_read_patient(:doctor_b, :'centre_a', :patient_a),
  'ending the old primary assignment removes access immediately'
);

select pg_temp.asserts(
  (select count(*) from patient_doctor_assignments
    where centre_id = :'centre_a' and patient_id = :patient_a
      and ended_at is not null) = 2,
  'primary replacement retains the prior primary and promoted assignment history'
);

select set_clinical_access_consent(
  :patient_a, :'centre_a', :patient_a, true, 'clinical_care'
) as consent_id \gset

select pg_temp.asserts(
  centre_can_read_clinical(:owner_a, :'centre_a', :patient_a),
  'Centre Owner clinical access begins only after Patient consent'
);

select set_clinical_access_consent(
  :patient_a, :'centre_a', :patient_a, false, 'clinical_care'
);

select pg_temp.asserts(
  not centre_can_read_clinical(:owner_a, :'centre_a', :patient_a),
  'revoked consent removes Centre Owner clinical access immediately'
);

select pg_temp.asserts(
  admin_can_read_patient(:admin, :patient_a),
  'Super Admin may read any Patient through an audited gateway path'
);

select record_access_event(
  :admin, 'patient_clinical_read', :patient_a, :'centre_a',
  'patient_record', :patient_a::text, 'support review',
  'request-c0c-1', 'allowed'
) as audit_id \gset

select pg_temp.refuses(
  format('update access_audit set action = %L where id = %L',
         'hidden', :'audit_id'),
  'access audit is append-only'
);
select pg_temp.refuses(
  format('delete from access_audit where id = %L', :'audit_id'),
  'access audit cannot be deleted'
);

set local role authenticated;
set local request.jwt.claims = :'owner_a_jwt';
select pg_temp.asserts(
  (select count(*) from patient_doctor_assignments) = 0,
  'Centre Owner receives no direct cross-user assignment rows'
);
reset role;
reset request.jwt.claims;

insert into clinical_drafts
  (user_id, kind, title, body, model_version)
values (:patient_a, 'observation', 'Protected draft', 'Original body', 'test-v1')
returning id as protected_draft \gset

set local role authenticated;
set local request.jwt.claims = :'admin_jwt';
select pg_temp.affects(
  format('update clinical_drafts set body = %L where id = %L',
         'Admin rewrite', :'protected_draft'),
  0,
  'Super Admin cannot alter clinical content through RLS'
);
reset role;
reset request.jwt.claims;

rollback;
