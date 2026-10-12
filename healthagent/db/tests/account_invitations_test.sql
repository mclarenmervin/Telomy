-- Account invitation and clinician-verification invariants.
-- Runs transactionally and leaves no identities or application rows behind.

\set owner_a  '\'c0b00000-0000-4000-8000-000000000001\''
\set owner_b  '\'c0b00000-0000-4000-8000-000000000002\''
\set doctor   '\'c0b00000-0000-4000-8000-000000000003\''
\set patient  '\'c0b00000-0000-4000-8000-000000000004\''
\set existing '\'c0b00000-0000-4000-8000-000000000005\''
\set admin    '\'c0b00000-0000-4000-8000-000000000006\''

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
        'authenticated', 'invite-owner-a@example.com', '', now(), now()),
       (:owner_b, '00000000-0000-0000-0000-000000000000', 'authenticated',
        'authenticated', 'invite-owner-b@example.com', '', now(), now()),
       (:doctor, '00000000-0000-0000-0000-000000000000', 'authenticated',
        'authenticated', 'invite-doctor@example.com', '', now(), now()),
       (:patient, '00000000-0000-0000-0000-000000000000', 'authenticated',
        'authenticated', 'invite-patient@example.com', '', now(), now()),
       (:existing, '00000000-0000-0000-0000-000000000000', 'authenticated',
        'authenticated', 'existing-person@example.com', '', now(), now()),
       (:admin, '00000000-0000-0000-8000-000000000000', 'authenticated',
        'authenticated', 'invite-admin@example.com', '', now(), now());

select set_config('telomy.granting_role', 'yes', true);
update profiles set app_role = 'centre' where id in (:owner_a, :owner_b);
update profiles set app_role = 'doctor' where id = :doctor;
update profiles set app_role = 'admin' where id = :admin;
select set_config('telomy.granting_role', '', true);

select create_centre('Invitation Centre A', :admin) as centre_a \gset
select create_centre('Invitation Centre B', :admin) as centre_b \gset

insert into centre_memberships
  (centre_id, user_id, member_kind, status, invited_by, accepted_at)
values
  (:'centre_a', :owner_a, 'owner', 'active', :admin, now()),
  (:'centre_b', :owner_b, 'owner', 'active', :admin, now()),
  (:'centre_a', :doctor, 'doctor', 'active', :admin, now());

select create_account_invitation(
  '  New.Patient@Example.COM ', 'member', :'centre_a', :owner_a,
  null, 'invite-patient-once'
) as normalized_invitation \gset

select create_account_invitation(
  'new.patient@example.com', 'member', :'centre_a', :owner_a,
  null, 'a-network-retry'
) as retried_invitation \gset

select pg_temp.asserts(
  :'normalized_invitation' = :'retried_invitation',
  'normalization and active-intent idempotency return one invitation'
);

select pg_temp.asserts(
  (select email = 'new.patient@example.com'
          and expires_at between created_at + interval '23 hours 59 minutes'
                             and created_at + interval '24 hours 1 minute'
     from account_invitations where id = :'normalized_invitation'),
  'an invitation stores normalized email and expires in 24 hours'
);

select create_account_invitation(
  'existing-person@example.com', 'member', :'centre_a', :owner_a,
  null, 'existing-user'
) as existing_invitation \gset

select pg_temp.asserts(
  (select invited_user_id = :existing from account_invitations
    where id = :'existing_invitation'),
  'an existing auth identity is linked rather than duplicated'
);

select pg_temp.refuses(
  format(
    'select create_account_invitation(%L, %L, %L, %L, null, %L)',
    'wrong-centre@example.com', 'member', :'centre_b',
    'c0b00000-0000-4000-8000-000000000001', 'wrong-centre'
  ),
  'a Centre Owner cannot invite into another centre'
);

select pg_temp.refuses(
  format(
    'select create_account_invitation(%L, %L, %L, %L, null, %L)',
    'doctor-invites-doctor@example.com', 'doctor', :'centre_a',
    'c0b00000-0000-4000-8000-000000000003', 'doctor-role'
  ),
  'a Doctor cannot invite another Doctor'
);

select pg_temp.refuses(
  format(
    'select create_account_invitation(%L, %L, %L, %L, null, %L)',
    'patient-invites@example.com', 'member', :'centre_a',
    'c0b00000-0000-4000-8000-000000000004', 'patient-invite'
  ),
  'a Patient cannot invite anyone'
);

select pg_temp.refuses(
  format(
    'select record_clinician_verification(%L, %L, %L, %L, %L, %L, now() + interval ''1 year'')',
    'c0b00000-0000-4000-8000-000000000001',
    'c0b00000-0000-4000-8000-000000000003', 'verified', 'looks valid',
    'REG-C0B', 'Medical Council'
  ),
  'only Super Admin verifies a Doctor'
);

select record_clinician_verification(
  :admin, :doctor, 'verified', 'registration confirmed',
  'REG-C0B', 'Medical Council', now() + interval '1 year',
  array['longevity medicine']
) as verified_decision \gset

select pg_temp.asserts(
  doctor_is_verified(:doctor),
  'a verified unexpired Doctor is currently eligible'
);

select pg_temp.refuses(
  format('update clinician_verifications set decision_reason = %L where id = %L',
         'rewritten', :'verified_decision'),
  'a verification decision cannot be rewritten'
);

select pg_temp.refuses(
  format('delete from clinician_verifications where id = %L',
         :'verified_decision'),
  'a verification decision cannot be deleted'
);

select create_account_invitation(
  'doctor-created-patient@example.com', 'member', :'centre_a', :doctor,
  :doctor, 'doctor-created-patient'
);

select pg_temp.asserts(
  (select count(*) from account_invitations
    where invited_by = :doctor and intended_role = 'member') = 1,
  'an active Doctor may invite a Patient into their centre'
);

select create_account_invitation(
  'expired@example.com', 'member', :'centre_a', :owner_a,
  null, 'expired'
) as expired_invitation \gset
update account_invitations
set expires_at = now() - interval '1 minute'
where id = :'expired_invitation';

select pg_temp.refuses(
  format('select accept_account_invitation(%L, %L)', :'expired_invitation',
         'c0b00000-0000-4000-8000-000000000004'),
  'an expired invitation cannot be accepted'
);

select create_account_invitation(
  'revoked@example.com', 'member', :'centre_a', :owner_a,
  null, 'revoked'
) as revoked_invitation \gset
update account_invitations
set status = 'revoked', revoked_at = now()
where id = :'revoked_invitation';

select pg_temp.refuses(
  format('select accept_account_invitation(%L, %L)', :'revoked_invitation',
         'c0b00000-0000-4000-8000-000000000004'),
  'a revoked invitation cannot be accepted'
);

select record_clinician_verification(
  :admin, :doctor, 'expired', 'licence expired'
);

select pg_temp.asserts(
  not doctor_is_verified(:doctor)
  and (select status from clinicians where user_id = :doctor) = 'suspended',
  'a later expiry decision removes Doctor eligibility immediately'
);

select pg_temp.asserts(
  (select count(*) from information_schema.columns
   where table_schema = 'public' and table_name = 'account_invitations'
     and column_name in ('password', 'token', 'magic_link', 'reset_token')) = 0,
  'application invitation data stores no password or provider token'
);

rollback;
