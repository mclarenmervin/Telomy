\set owner    '\'c0d00000-0000-4000-8000-000000000001\''
\set doctor   '\'c0d00000-0000-4000-8000-000000000002\''
\set other    '\'c0d00000-0000-4000-8000-000000000003\''
\set patient  '\'c0d00000-0000-4000-8000-000000000004\''
\set admin    '\'c0d00000-0000-4000-8000-000000000005\''

begin;

create or replace function pg_temp.asserts(ok boolean, label text)
returns void language plpgsql as $$ begin
  if ok then raise notice 'PASS: %', label;
  else raise exception 'FAIL: %', label; end if;
end $$;
create or replace function pg_temp.refuses(statement text, label text)
returns void language plpgsql as $$ begin
  begin execute statement;
  exception when others then raise notice 'PASS: %', label; return; end;
  raise exception 'FAIL: %', label;
end $$;

insert into auth.users (id, instance_id, aud, role, email, encrypted_password, created_at, updated_at)
values (:owner, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'workspace-owner@example.com', '', now(), now()),
       (:doctor, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'workspace-doctor@example.com', '', now(), now()),
       (:other, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'workspace-other@example.com', '', now(), now()),
       (:patient, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'workspace-patient@example.com', '', now(), now()),
       (:admin, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'workspace-admin@example.com', '', now(), now());
select set_config('telomy.granting_role', 'yes', true);
update profiles set app_role = 'centre' where id = :owner;
update profiles set app_role = 'doctor' where id in (:doctor, :other);
update profiles set app_role = 'admin' where id = :admin;
select set_config('telomy.granting_role', '', true);

select create_centre('Doctor Workspace Centre', :admin) as centre \gset
insert into centres (name, created_by) values ('Unused', :admin);
insert into centre_memberships (centre_id, user_id, member_kind, status, invited_by, accepted_at)
values (:'centre', :owner, 'owner', 'active', :admin, now()),
       (:'centre', :doctor, 'doctor', 'active', :admin, now()),
       (:'centre', :other, 'doctor', 'active', :admin, now()),
       (:'centre', :patient, 'patient', 'active', :owner, now());
select record_clinician_verification(:admin, :doctor, 'verified', 'verified',
  'REG-C0D', 'Medical Council', now() + interval '1 year');
select record_clinician_verification(:admin, :other, 'verified', 'verified',
  'REG-C0D-OTHER', 'Medical Council', now() + interval '1 year');
insert into clinics (name) values ('Signing Clinic') returning id as clinic \gset
insert into clinic_members (clinic_id, user_id, role) values (:'clinic', :doctor, 'clinician');
insert into centre_clinics (centre_id, clinic_id, linked_by) values (:'centre', :'clinic', :admin);
select assign_patient_doctor(:owner, :'centre', :patient, :doctor, true);

select append_clinician_note(:doctor, :'centre', :patient, 'Initial note') as note_one \gset
select append_clinician_note(:doctor, :'centre', :patient, 'Corrected note', :'note_one') as note_two \gset
select pg_temp.asserts(
  (select body from clinician_notes where id = :'note_one') = 'Initial note'
  and (select supersedes_id from clinician_notes where id = :'note_two') = :'note_one',
  'a correction appends and points at the unchanged original'
);
select pg_temp.refuses(
  format('select append_clinician_note(%L, %L, %L, %L)', :other, :'centre', :patient, 'Browse note'),
  'an unassigned Doctor cannot append a note'
);
select pg_temp.refuses(
  format('update clinician_notes set body = %L where id = %L', 'rewrite', :'note_one'),
  'a note body cannot be rewritten'
);
select withdraw_clinician_note(:doctor, :'note_two', 'entered against wrong visit');
select pg_temp.asserts(
  (select body = 'Corrected note' and withdrawal_reason = 'entered against wrong visit'
   from clinician_notes where id = :'note_two'),
  'withdrawal retains note text and records the reason'
);

select create_monthly_report_version(
  :doctor, :'centre', :patient, date '2026-09-01', date '2026-09-30',
  timestamptz '2026-10-01 00:00:00+00', '[{"source":"scores"}]', 'Version one'
) as report_one \gset
select create_monthly_report_version(
  :doctor, :'centre', :patient, date '2026-09-01', date '2026-09-30',
  timestamptz '2026-10-02 00:00:00+00', '[{"source":"scores"}]', 'Version two'
) as report_two \gset
select pg_temp.asserts(
  (select version from monthly_reports where id = :'report_two') = 2
  and (select supersedes_id from monthly_reports where id = :'report_two') = :'report_one',
  'regeneration creates a new linked report version'
);
select pg_temp.refuses(
  format('select sign_monthly_report(%L, %L, %L)', :doctor, :'report_two', '   '),
  'a monthly report cannot be signed without a note'
);
select sign_monthly_report(:doctor, :'report_two', 'Reviewed against source values');
select pg_temp.asserts(
  (select signed_body_sha256 = encode(sha256(convert_to(
      body || E'\n\nClinician note: ' || reviewer_note, 'UTF8')), 'hex')
   from monthly_reports where id = :'report_two'),
  'the signature binds the exact report body and clinician note'
);
select pg_temp.refuses(
  format('update monthly_reports set body = %L where id = %L', 'one character changed', :'report_two'),
  'signed report content cannot be edited'
);
select pg_temp.refuses(
  format('delete from monthly_reports where id = %L', :'report_two'),
  'signed reports cannot be deleted'
);

rollback;
