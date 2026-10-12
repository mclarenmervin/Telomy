-- What 022_app_role.sql has to guarantee.
--
-- This file is the phase, not a check on it. F9 exists because the prototype
-- kept the role in `AsyncStorage` and every endpoint trusted it, and the
-- difference between that and this is entirely in what a database refuses.
--
-- The assertions are grouped by the thing that would be a leak:
--
--   * nobody grants themselves a role, enforced twice -- once in the column
--     privileges, which stop the phone, and once in a trigger, which stops us;
--   * a JWT claim grants nothing. The column is the fact and the claim is a
--     cache, so a token minted while somebody was an admin confers nothing
--     once the column says otherwise;
--   * `app_role` and `clinic_members.role` are different axes, so a platform
--     role admits no clinical row by itself;
--   * an admin reads every operational row and no member's health rows, which
--     is the boundary the programme's own risk table asks for.
--
-- Every assertion authenticates and reads. A schema assertion would pass for
-- four of the policy holes F3 through F6 each shipped.
--
-- Runs inside a transaction that always rolls back.
--
--   psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f db/tests/app_role_test.sql

\set member  '\'a0a0a0a0-0000-4000-8000-000000000001\''
\set doctor  '\'a0a0a0a0-0000-4000-8000-000000000002\''
\set centre  '\'a0a0a0a0-0000-4000-8000-000000000003\''
\set admin   '\'a0a0a0a0-0000-4000-8000-000000000004\''
\set other   '\'a0a0a0a0-0000-4000-8000-000000000005\''

\set member_jwt '{"sub":"a0a0a0a0-0000-4000-8000-000000000001","role":"authenticated"}'
\set doctor_jwt '{"sub":"a0a0a0a0-0000-4000-8000-000000000002","role":"authenticated"}'
\set centre_jwt '{"sub":"a0a0a0a0-0000-4000-8000-000000000003","role":"authenticated"}'
\set admin_jwt  '{"sub":"a0a0a0a0-0000-4000-8000-000000000004","role":"authenticated"}'

-- The forged one. `app_role` in the claims says admin; the column will say
-- member. This is bite 1 of the handoff, spelled as a token.
\set forged_jwt '{"sub":"a0a0a0a0-0000-4000-8000-000000000001","role":"authenticated","app_role":"admin"}'

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
values (:member, '00000000-0000-0000-0000-000000000000', 'authenticated',
        'authenticated', 'role-member@example.com', '', now(), now()),
       (:doctor, '00000000-0000-0000-0000-000000000000', 'authenticated',
        'authenticated', 'role-doctor@example.com', '', now(), now()),
       (:centre, '00000000-0000-0000-0000-000000000000', 'authenticated',
        'authenticated', 'role-centre@example.com', '', now(), now()),
       (:admin, '00000000-0000-0000-0000-000000000000', 'authenticated',
        'authenticated', 'role-admin@example.com', '', now(), now()),
       (:other, '00000000-0000-0000-0000-000000000000', 'authenticated',
        'authenticated', 'role-other@example.com', '', now(), now());

-- `handle_new_user` already made a profile for each, every one of them a
-- member. Setting the other three roles is the bootstrap problem: there is no
-- admin yet, so `grant_app_role` has nobody to authorise it, and the only way
-- in is the explicit opt-out the trigger looks for.
--
-- That GUC is the whole bootstrap and it is deliberately narrow. PostgREST
-- does not run arbitrary SQL, so neither the phone nor our own service-role
-- code can set it; it takes a psql session or a migration, which is to say
-- somebody with database access and a reason.
select set_config('telomy.granting_role', 'yes', true);
update profiles set app_role = 'doctor' where id = :doctor;
update profiles set app_role = 'centre' where id = :centre;
update profiles set app_role = 'admin'  where id = :admin;
select set_config('telomy.granting_role', '', true);

select pg_temp.refuses(
  format('update profiles set app_role = %L where id = %L',
         'admin', 'a0a0a0a0-0000-4000-8000-000000000005'),
  'a bare UPDATE is refused even for the table owner, so a role change '
  'without a trail takes a deliberate opt-out rather than a typo'
);


-- ── The column ──────────────────────────────────────────────────────────────

select pg_temp.asserts(
  (select app_role from profiles where id = :member) = 'member',
  'a new account is a member, because the default is the safe role'
);

select pg_temp.asserts(
  (select app_role from profiles where id = :other) = 'member',
  'and so is an account nobody has touched'
);

select pg_temp.refuses(
  format('update profiles set app_role = %L where id = %L',
         'superuser', 'a0a0a0a0-0000-4000-8000-000000000005'),
  'a role nobody designed is refused by the constraint'
);

-- 013's constraint, asserted here so that a later migration widening
-- `clinic_members.role` to carry a platform role fails this file rather than
-- a code review.
select pg_temp.asserts(
  (select pg_get_constraintdef(oid) from pg_constraint
    where conname = 'clinic_member_role_known')
    = 'CHECK ((role = ANY (ARRAY[''patient''::text, ''clinician''::text, ''admin''::text])))',
  'clinic_members.role still means membership inside one clinic, unchanged'
);


-- ── Nobody grants themselves a role ─────────────────────────────────────────
--
-- Twice. The column privilege is what stops the phone; the trigger is what
-- stops anything holding a wider grant, including us.

set local role authenticated;
set local request.jwt.claims = :'member_jwt';

-- RLS admits the row and the UPDATE policy allows it, so this is not refused
-- by a policy -- it is refused because `app_role` is not a column this role
-- may write. Asserted on the row as well, because a privilege error and a
-- silent no-op read the same way from the app.
select pg_temp.refuses(
  format('update profiles set app_role = %L where id = %L',
         'admin', 'a0a0a0a0-0000-4000-8000-000000000001'),
  'a member cannot write their own app_role'
);

select pg_temp.asserts(
  (select app_role from profiles where id = :member) = 'member',
  'and the row still says member'
);

-- The name is a column they MAY write, so this proves the revoke above was
-- surgical rather than a blanket one that broke editing a profile.
update profiles set full_name = 'Renamed' where id = :member;

select pg_temp.asserts(
  (select full_name from profiles where id = :member) = 'Renamed',
  'a member can still edit their own name'
);

reset role;

-- The trigger, independent of the grant: still the owner, but acting as the
-- member. `auth.uid()` reads the claims, not the database role, so this is
-- the shape of our own service code elevating the user it is acting for.
set local request.jwt.claims = :'member_jwt';

select pg_temp.refuses(
  format('update profiles set app_role = %L where id = %L',
         'admin', 'a0a0a0a0-0000-4000-8000-000000000001'),
  'nobody grants themselves a role, whatever privileges they hold'
);

-- And the same actor may still be granted a role by somebody else, so the
-- trigger refuses self-elevation and not role changes in general.
select pg_temp.refuses(
  format('update profiles set app_role = %L where id = %L',
         'doctor', 'a0a0a0a0-0000-4000-8000-000000000005'),
  'a member cannot grant anybody else a role either'
);

reset request.jwt.claims;


-- ── The one path that does grant a role ─────────────────────────────────────

select grant_app_role(:other, 'doctor', :admin, 'onboarding a clinician');

select pg_temp.asserts(
  (select app_role from profiles where id = :other) = 'doctor',
  'an admin grants a role through grant_app_role'
);

select pg_temp.asserts(
  (select count(*) from admin_actions
    where action = 'role_granted' and subject_id = :other::text
      and detail->>'from' = 'member' and detail->>'to' = 'doctor'
      and detail->>'reason' = 'onboarding a clinician') = 1,
  'and the grant and its record are one statement, with what it changed from'
);

-- The trail is the point, so re-granting what somebody already has must not
-- file an action claiming something changed.
select grant_app_role(:other, 'doctor', :admin, 'again');
select pg_temp.asserts(
  (select count(*) from admin_actions where subject_id = :other::text) = 1,
  're-granting a role somebody already has files nothing'
);

select pg_temp.refuses(
  format('select grant_app_role(%L, %L, %L)',
         'a0a0a0a0-0000-4000-8000-000000000005', 'admin',
         'a0a0a0a0-0000-4000-8000-000000000001'),
  'a member cannot grant a role through the sanctioned path either'
);

select pg_temp.refuses(
  format('select grant_app_role(%L, %L, %L)',
         'a0a0a0a0-0000-4000-8000-000000000004', 'admin',
         'a0a0a0a0-0000-4000-8000-000000000004'),
  'and an admin cannot grant themselves anything'
);

-- Revoking is the same path and says so in the trail, because "this person
-- stopped being a clinician in March" is a question an audit asks.
select grant_app_role(:other, 'member', :admin, 'left the network');
select pg_temp.asserts(
  (select count(*) from admin_actions
    where action = 'role_revoked' and subject_id = :other::text) = 1,
  'dropping back to member is recorded as a revocation, not as a grant'
);


-- ── A stale claim grants nothing ────────────────────────────────────────────
--
-- Bite 1. The claim says admin; the column says member.

set local role authenticated;
set local request.jwt.claims = :'forged_jwt';

select pg_temp.asserts(
  app_role_of(auth.uid()) = 'member',
  'the role comes from the column, not from the token that claims it'
);

select pg_temp.asserts(
  (select count(*) from admin_actions) = 0,
  'a forged admin claim reads zero admin actions'
);

select pg_temp.asserts(
  (select count(*) from profiles) = 1,
  'and still sees exactly one profile: their own'
);

reset role;


-- ── The two axes stay two ───────────────────────────────────────────────────

insert into clinics (id, name)
values ('a0a0a0a0-0000-4000-8000-0000000000c1', 'Role Test Clinic');

-- app_role says doctor. There is no `clinicians` row and no clinic
-- membership, which is what the clinical surface actually reads.
set local role authenticated;
set local request.jwt.claims = :'doctor_jwt';

select pg_temp.asserts(
  (select count(*) from clinical_drafts) = 0,
  'app_role = doctor admits no clinical draft by itself'
);

select pg_temp.asserts(
  not clinician_may_sign(:doctor),
  'and confers no right to sign'
);

reset role;

-- The mirror: a clinic membership and a registration, with app_role left at
-- member. 013's policies read the registration, so they still work -- which
-- is the property that keeps F9 from having to touch them.
insert into clinic_members (clinic_id, user_id, role)
values ('a0a0a0a0-0000-4000-8000-0000000000c1', :other, 'clinician');
insert into clinicians (user_id, full_name, registration_number,
                        licence_expires_at)
values (:other, 'Dr Role Test', 'ROLE/0001', now() + interval '1 year');

select pg_temp.asserts(
  clinician_may_sign(:other),
  'a clinician with app_role = member may still sign, because the axes are '
  'separate and 013 was not rewritten'
);


-- ── Admin actions are append-only and admin-visible ─────────────────────────
--
-- Three actions exist by now, all filed by `grant_app_role` above, and two of
-- them are about the admin's own doing. Counted against that rather than
-- against a literal, so the section does not break the next time something
-- above it files an action.

set local role authenticated;
set local request.jwt.claims = :'admin_jwt';

select pg_temp.asserts(
  (select count(*) from admin_actions where actor_id = :admin) = 2,
  'an admin sees admin actions, including the ones performed by themselves'
);

select pg_temp.refuses(
  'update admin_actions set action = ''nothing_happened''',
  'an admin cannot edit the record of what they did'
);

select pg_temp.refuses(
  'delete from admin_actions',
  'nor delete it'
);

-- An admin records their own actions and cannot write one in somebody else's
-- name, which is the whole value of the table in a dispute.
select pg_temp.refuses(
  format('insert into admin_actions (actor_id, action) values (%L, %L)',
         'a0a0a0a0-0000-4000-8000-000000000002', 'role_granted'),
  'an admin cannot file an action against another admin''s name'
);

insert into admin_actions (actor_id, action, subject_kind, subject_id)
values (:admin, 'signoff_recorded', 'catalog_entry', 'albumin');

select pg_temp.asserts(
  (select count(*) from admin_actions where actor_id = :admin) = 3,
  'and can record their own'
);

reset role;

-- Each of the other three reads zero.
set local role authenticated;
set local request.jwt.claims = :'member_jwt';
select pg_temp.asserts(
  (select count(*) from admin_actions) = 0,
  'a member reads zero admin actions'
);
select pg_temp.refuses(
  format('insert into admin_actions (actor_id, action) values (%L, %L)',
         'a0a0a0a0-0000-4000-8000-000000000001', 'role_granted'),
  'and cannot write one'
);
reset role;

set local role authenticated;
set local request.jwt.claims = :'doctor_jwt';
select pg_temp.asserts(
  (select count(*) from admin_actions) = 0,
  'a doctor reads zero admin actions'
);
reset role;

set local role authenticated;
set local request.jwt.claims = :'centre_jwt';
select pg_temp.asserts(
  (select count(*) from admin_actions) = 0,
  'a centre reads zero admin actions'
);
reset role;


-- ── What an admin may read, and what they may not ───────────────────────────
--
-- The operational half: an admin reads every account, because onboarding a
-- clinician and honouring an erasure request both start there.

set local role authenticated;
set local request.jwt.claims = :'admin_jwt';

select pg_temp.asserts(
  (select count(*) from profiles) >= 5,
  'an admin reads every account, which is how a clinician gets onboarded'
);

-- Counted on the test's own registration rather than on the table, because
-- the live database already holds dev_clinical_demo.sql's one fixture
-- clinician and a literal here would break the day a second real one exists.
select pg_temp.asserts(
  (select count(*) from clinicians where user_id = :other) = 1,
  'and every licence, which is how a lapse gets noticed before a refusal does'
);

-- An admin cannot grant a role by writing the column either. The surface does
-- it through a function that files an admin action; a bare UPDATE from a
-- client would leave no trail.
select pg_temp.refuses(
  format('update profiles set app_role = %L where id = %L',
         'doctor', 'a0a0a0a0-0000-4000-8000-000000000005'),
  'not even an admin writes app_role straight from a client'
);

-- Asserted on the row as well, and not only with `refuses`. There is no
-- UPDATE policy admitting somebody else's profile, so if the column grant
-- ever came back this statement would change nothing and report success --
-- which `refuses` reads as acceptance and 021's test records as the trap.
select pg_temp.asserts(
  (select app_role from profiles where id = :other) = 'member',
  'and the row it tried to write is untouched'
);

reset role;


-- The health half. These are the rows the programme's risk table calls the
-- God-account problem, and the answer is that no policy admits them.

insert into health_measurements
  (id, user_id, measurement_type, value, unit, recorded_at, source)
values (gen_random_uuid(), :member, 'resting_heart_rate', 58, 'bpm', now(),
        'wearable');

insert into chat_turns (user_id, asked, answered, route, model)
values (:member, 'how did I sleep?', 'Seven hours.', 'answered', 'm');

insert into clinical_drafts
  (user_id, kind, title, body, model_version, routing_flags)
values (:member, 'observation', 'A draft', 'Something unreviewed.', 'v1',
        '{"clinician_queue"}');

set local role authenticated;
set local request.jwt.claims = :'admin_jwt';

select pg_temp.asserts(
  (select count(*) from health_measurements) = 0,
  'an admin reads zero of a member''s measurements'
);

select pg_temp.asserts(
  (select count(*) from chat_turns) = 0,
  'zero of their conversations with Sinc'
);

select pg_temp.asserts(
  (select count(*) from clinical_drafts) = 0,
  'and zero unreviewed drafts -- the queue is a clinician''s surface, and '
  'draft bodies are the most sensitive rows in the schema'
);

select pg_temp.asserts(
  (select count(*) from insights) = 0,
  'zero delivered insights'
);

select pg_temp.asserts(
  (select count(*) from genetic_variants) = 0,
  'and zero genotypes'
);

reset role;


-- ── A member reaches none of the other three surfaces ───────────────────────

set local role authenticated;
set local request.jwt.claims = :'member_jwt';

select pg_temp.asserts(
  (select count(*) from clinical_drafts) = 0,
  'a member cannot read the draft written about them, which is 013''s rule '
  'and still holds now that a role column exists to be tempted by'
);

select pg_temp.asserts(
  (select count(*) from clinicians) = 0,
  'a member reads no clinician''s registration'
);

select pg_temp.asserts(
  (select count(*) from health_measurements) = 1,
  'and reads their own measurements, so the policies above are not simply off'
);

reset role;

rollback;
