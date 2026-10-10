-- What 013_clinical_review.sql has to guarantee.
--
-- F5 is the clinician spine: drafts the agent writes, reviews a clinician
-- signs, insights the user finally sees. Three of its four properties cannot be
-- tested from Python at all, because every Python test path uses a fake or the
-- service role and the service role bypasses RLS by design:
--
--   * a user physically cannot read a draft about themselves — enforced by the
--     ABSENCE of a policy, not by a filter someone has to remember;
--   * a clinician whose licence has lapsed cannot sign what they claimed an
--     hour ago — checked at signing time, not at claim time;
--   * a one-character edit after signing makes the insight undeliverable —
--     a hash comparison, not a status check.
--
-- The fourth is the state machine, which is cheap to assert here and expensive
-- to reconstruct from application logs later.
--
-- Written BEFORE the migration, per the lesson F3 and F4 both paid for: a table
-- the phone or the console must read or write, with RLS enabled and the policy
-- missing, is invisible to every other kind of test. F3 shipped with no INSERT
-- policy on lab_uploads and nothing caught it until a real device hit 42501.
--
-- Runs inside a transaction that always rolls back.
--
--   psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f db/tests/clinical_review_test.sql

\set patient '\'a1a1a1a1-0000-4000-8000-000000000001\''
\set other   '\'a1a1a1a1-0000-4000-8000-000000000002\''
\set doctor  '\'b2b2b2b2-0000-4000-8000-000000000001\''
\set lapsed  '\'b2b2b2b2-0000-4000-8000-000000000002\''
\set ghost   '\'00000000-dead-4000-8000-000000000001\''

\set patient_jwt '{"sub":"a1a1a1a1-0000-4000-8000-000000000001","role":"authenticated"}'
\set other_jwt   '{"sub":"a1a1a1a1-0000-4000-8000-000000000002","role":"authenticated"}'
\set doctor_jwt  '{"sub":"b2b2b2b2-0000-4000-8000-000000000001","role":"authenticated"}'
\set lapsed_jwt  '{"sub":"b2b2b2b2-0000-4000-8000-000000000002","role":"authenticated"}'

begin;

-- ── Helpers ──────────────────────────────────────────────────────────────────
--
-- Same four as db/tests/biological_age_test.sql, for the same reason: a missing
-- table or a typo must read as a broken test, never as a passing one.

create or replace function pg_temp.refuses(stmt text, label text)
returns void language plpgsql as $$
declare
  state text;
begin
  begin
    execute stmt;
  exception
    when integrity_constraint_violation then
      raise notice 'PASS: %', label;
      return;
    when others then
      get stacked diagnostics state = returned_sqlstate;
      raise exception 'FAIL: % — refused for the wrong reason (SQLSTATE %)', label, state;
  end;
  raise exception 'FAIL: % — the database accepted it', label;
end $$;

create or replace function pg_temp.accepts(stmt text, label text)
returns void language plpgsql as $$
begin
  execute stmt;
  raise notice 'PASS: %', label;
exception
  when others then
    raise exception 'FAIL: % — the database refused it (%)', label, sqlerrm;
end $$;

-- An RLS denial is SQLSTATE 42501, not an integrity violation. Kept separate
-- because a constraint failure and a policy denial are different claims and a
-- test should say which one it expects.
create or replace function pg_temp.refuses_rls(stmt text, label text)
returns void language plpgsql as $$
declare
  state text;
begin
  begin
    execute stmt;
  exception
    when insufficient_privilege then
      raise notice 'PASS: %', label;
      return;
    when others then
      get stacked diagnostics state = returned_sqlstate;
      raise exception 'FAIL: % — refused for the wrong reason (SQLSTATE %)', label, state;
  end;
  raise exception 'FAIL: % — the policy allowed it', label;
end $$;

create or replace function pg_temp.asserts(ok boolean, label text)
returns void language plpgsql as $$
begin
  if ok then
    raise notice 'PASS: %', label;
  else
    raise exception 'FAIL: %', label;
  end if;
end $$;

-- How many rows does the current role actually see? A SELECT with no policy to
-- permit it does not raise — it returns nothing. So "cannot read" is a row
-- count, not an exception, and this is the only honest way to assert it.
-- An UPDATE or DELETE that a policy does not admit matches no rows and
-- succeeds trivially rather than raising 42501 — so "cannot change it" is also
-- a row count. The same trap biological_age_test.sql names for score_snapshots,
-- except there the right answer was to assert the policy's absence and here the
-- policy exists and must simply not admit this caller.
create or replace function pg_temp.affects(stmt text, expected bigint, label text)
returns void language plpgsql as $$
declare
  touched bigint;
begin
  execute stmt;
  get diagnostics touched = row_count;
  if touched = expected then
    raise notice 'PASS: %', label;
  else
    raise exception 'FAIL: % — changed % row(s), expected %', label, touched, expected;
  end if;
end $$;

create or replace function pg_temp.sees(stmt text, expected bigint, label text)
returns void language plpgsql as $$
declare
  found bigint;
begin
  execute format('select count(*) from (%s) q', stmt) into found;
  if found = expected then
    raise notice 'PASS: %', label;
  else
    raise exception 'FAIL: % — saw % row(s), expected %', label, found, expected;
  end if;
end $$;


-- ── Fixtures ─────────────────────────────────────────────────────────────────

insert into auth.users (id, email) values
  (:patient, 'f5-patient@example.com'),
  (:other,   'f5-other@example.com'),
  (:doctor,  'f5-doctor@example.com'),
  (:lapsed,  'f5-lapsed@example.com')
on conflict (id) do nothing;

insert into clinics (id, name)
values ('c0c0c0c0-0000-4000-8000-000000000001', 'Bonphul Test Clinic');

-- A clinic holds patients and clinicians both — 005's range-override policy
-- already reads clinic_members for the patient side — so the role is what tells
-- them apart, and without it a patient of the clinic could read its queue.
insert into clinic_members (clinic_id, user_id, role) values
  ('c0c0c0c0-0000-4000-8000-000000000001', :patient, 'patient'),
  ('c0c0c0c0-0000-4000-8000-000000000001', :doctor,  'clinician'),
  ('c0c0c0c0-0000-4000-8000-000000000001', :lapsed,  'clinician');

insert into clinicians
  (user_id, full_name, registration_number, licence_expires_at, status) values
  (:doctor, 'Dr A. Example', 'MCI-TEST-0001', now() + interval '1 year', 'active'),
  -- Licence already expired. They can still claim; they must not be able to sign.
  (:lapsed, 'Dr B. Lapsed',  'MCI-TEST-0002', now() - interval '1 day',  'active');


-- ── A draft is written by the agent, under the service role ──────────────────

select pg_temp.accepts(format($$
  insert into clinical_drafts
    (id, user_id, clinic_id, kind, title, body, evidence, model_version)
  values ('d0d0d0d0-0000-4000-8000-000000000001', %L,
          'c0c0c0c0-0000-4000-8000-000000000001', 'observation',
          'Your HbA1c has risen across three panels',
          'Across your last three panels HbA1c moved from 5.4%% to 5.9%%.',
          '[{"biomarker_id":"hba1c","value":5.9,"collected_at":"2026-09-01"}]'::jsonb,
          'insight-rules-v1')
$$, :patient), 'the agent can write a draft');

select pg_temp.refuses(format($$
  insert into clinical_drafts (user_id, clinic_id, kind, title, body, model_version)
  values (%L, 'c0c0c0c0-0000-4000-8000-000000000001', 'observation', 't', 'b', 'm')
$$, :ghost), 'a draft cannot be written for an account that does not exist');

-- Every draft starts at the beginning. A draft inserted straight into `signed`
-- would be a signature nobody gave.
select pg_temp.asserts(
  (select status from clinical_drafts
    where id = 'd0d0d0d0-0000-4000-8000-000000000001') = 'drafted',
  'a new draft starts as drafted');

select pg_temp.refuses(format($$
  insert into clinical_drafts
    (user_id, clinic_id, kind, title, body, model_version, status)
  values (%L, 'c0c0c0c0-0000-4000-8000-000000000001', 'observation', 't', 'b', 'm',
          'signed')
$$, :patient), 'a draft cannot be created already signed');


-- ── One draft per finding ────────────────────────────────────────────────────
--
-- 014. The nightly sweep runs every night; without a natural key it creates a
-- fresh row for the same finding each time, and a queue that grows while it is
-- being worked is a queue nobody works.

update clinical_drafts set dedupe_key = 'trend:hba1c:standard:2026-09-01'
 where id = 'd0d0d0d0-0000-4000-8000-000000000001';

select pg_temp.refuses(format($$
  insert into clinical_drafts
    (user_id, clinic_id, kind, title, body, model_version, dedupe_key)
  values (%L, 'c0c0c0c0-0000-4000-8000-000000000001', 'lab_finding',
          'Your HbA1c has risen across three panels', 'Again.',
          'marker-trend-v1', 'trend:hba1c:standard:2026-09-01')
$$, :patient), 'the same finding cannot be drafted twice for one user');

-- Scoped per user. Two people whose HbA1c both rose to 6.0 on the same day is
-- unremarkable, and suppressing the second would be a cross-tenant bug of the
-- quietest possible kind.
select pg_temp.accepts(format($$
  insert into clinical_drafts
    (user_id, clinic_id, kind, title, body, model_version, dedupe_key)
  values (%L, 'c0c0c0c0-0000-4000-8000-000000000001', 'lab_finding',
          'Your HbA1c has risen across three panels', 'Same finding, other person.',
          'marker-trend-v1', 'trend:hba1c:standard:2026-09-01')
$$, :other), 'another user with the identical finding gets their own draft');

-- A draft with no natural key -- one a clinician composes by hand -- must not
-- be blocked by the constraint, which is why the default is a fresh uuid
-- rather than null.
select pg_temp.accepts(format($$
  insert into clinical_drafts (user_id, kind, title, body, model_version)
  values (%L, 'observation', 'Composed by hand', 'No natural key.', 'manual')
$$, :patient), 'a draft with no natural key is not blocked by the dedupe key');

select pg_temp.accepts(format($$
  insert into clinical_drafts (user_id, kind, title, body, model_version)
  values (%L, 'observation', 'Composed by hand again', 'Still no key.', 'manual')
$$, :patient), 'nor is a second one');

delete from clinical_drafts where model_version = 'manual';
delete from clinical_drafts where user_id = :other;


-- ── THE enforcement: a user cannot read a draft about themselves ─────────────
--
-- Not a filter in a query someone has to remember — the absence of a policy.
-- An unreviewed draft may say something wrong, frightening or both, and the
-- entire purpose of this phase is that it reaches nobody until a clinician has
-- put their registration number against it.

set local role authenticated;
set local request.jwt.claims = :'patient_jwt';

select pg_temp.sees(
  'select 1 from clinical_drafts',
  0, 'the subject of a draft cannot read it');

select pg_temp.refuses_rls($$
  insert into clinical_drafts (user_id, clinic_id, kind, title, body, model_version)
  values (auth.uid(), 'c0c0c0c0-0000-4000-8000-000000000001', 'observation',
          'I am very well', 'Signed, me.', 'mine')
$$, 'a user cannot write themselves a draft');

-- The subject cannot push their own draft along the machine either. There is an
-- UPDATE policy on this table, so this is the case that proves it is gated on
-- being a clinician rather than on owning the row.
select pg_temp.affects($$
  update clinical_drafts set status = 'queued' where user_id = auth.uid()
$$, 0, 'the subject of a draft cannot advance it');

select pg_temp.affects($$
  delete from clinical_drafts where user_id = auth.uid()
$$, 0, 'the subject of a draft cannot delete it');

reset role;

-- Drafts are written by the agent and ended by a status, never by a delete, so
-- neither an INSERT nor a DELETE policy should exist at all. There IS an UPDATE
-- policy — a clinician has to be able to claim one — so this cannot simply
-- assert that no write policy exists, and the subject's inability to write has
-- to be shown rather than inferred. That is the next two cases.
select pg_temp.asserts(
  not exists (
    select 1 from pg_policies
     where tablename = 'clinical_drafts'
       and cmd in ('INSERT', 'DELETE', 'ALL')
  ),
  'no policy lets any user role create or delete a draft');

-- And the one that would undo all of it: a SELECT policy keyed on the draft's
-- own user_id. There IS a select policy here — the console needs one — so this
-- asserts what it must not be rather than that it is absent.
select pg_temp.asserts(
  not exists (
    select 1 from pg_policies
     where tablename = 'clinical_drafts' and cmd = 'SELECT'
       and qual like '%uid() = user_id%'
  ),
  'no select policy on drafts is keyed on the draft subject');


-- ── A clinician reads the queue, and only their own ──────────────────────────

set local role authenticated;
set local request.jwt.claims = :'doctor_jwt';

select pg_temp.sees(
  'select 1 from clinical_drafts',
  1, 'a clinician of the clinic can read its queue');

reset role;

-- A patient of the same clinic must not. This is why clinic_members needed a
-- role: 005 put patients and clinicians in one table, so "a member of the
-- clinic" would have handed every patient the whole queue.
set local role authenticated;
set local request.jwt.claims = :'patient_jwt';

select pg_temp.sees(
  'select 1 from clinical_drafts',
  0, 'a patient of the clinic cannot read its queue');

reset role;

-- A clinician who has left takes their access with them. clinic_members had no
-- way to express that, so leaving a clinic was indistinguishable from staying.
update clinic_members set left_at = now()
 where user_id = :doctor and clinic_id = 'c0c0c0c0-0000-4000-8000-000000000001';

set local role authenticated;
set local request.jwt.claims = :'doctor_jwt';

select pg_temp.sees(
  'select 1 from clinical_drafts',
  0, 'a clinician who has left the clinic cannot read its queue');

reset role;

update clinic_members set left_at = null
 where user_id = :doctor and clinic_id = 'c0c0c0c0-0000-4000-8000-000000000001';


-- ── The state machine ────────────────────────────────────────────────────────
--
--   drafted → queued → in_review → signed → delivered
--                         │  │                  │
--               revised ──┘  └→ rejected        └→ withdrawn
--
-- Enforced in the database because the clinician console is a separate repo
-- doing CRUD over Postgres. A state machine that lives only in our Python is
-- not a state machine that console obeys.

select pg_temp.accepts($$
  update clinical_drafts set status = 'queued'
   where id = 'd0d0d0d0-0000-4000-8000-000000000001'
$$, 'a draft can be queued for review');

select pg_temp.refuses($$
  update clinical_drafts set status = 'delivered'
   where id = 'd0d0d0d0-0000-4000-8000-000000000001'
$$, 'a queued draft cannot jump straight to delivered');

select pg_temp.refuses($$
  update clinical_drafts set status = 'signed'
   where id = 'd0d0d0d0-0000-4000-8000-000000000001'
$$, 'a queued draft cannot become signed without passing through review');

select pg_temp.accepts(format($$
  update clinical_drafts
     set status = 'in_review', claimed_by = %L, claimed_at = now()
   where id = 'd0d0d0d0-0000-4000-8000-000000000001'
$$, :doctor), 'a clinician can claim a queued draft');

-- A claim that goes stale returns to the queue rather than sitting forever.
-- The SLA sweep is what moves it; the machine has to permit the move.
select pg_temp.accepts($$
  update clinical_drafts
     set status = 'queued', claimed_by = null, claimed_at = null
   where id = 'd0d0d0d0-0000-4000-8000-000000000001'
$$, 'an expired claim returns the draft to the queue');

select pg_temp.accepts(format($$
  update clinical_drafts
     set status = 'in_review', claimed_by = %L, claimed_at = now()
   where id = 'd0d0d0d0-0000-4000-8000-000000000001'
$$, :doctor), 'and it can be claimed again');


-- ── Signing: the licence is checked now, not at claim time ───────────────────
--
-- A clinician whose registration lapses mid-review must not be able to sign
-- what they claimed an hour ago. Checked in a trigger rather than only in an
-- RLS policy, because the agent and the scheduler hold the service role and RLS
-- does not apply to them — a licence check that only binds the console is a
-- licence check with a service-role-shaped hole in it.

select pg_temp.asserts(
  clinician_may_sign(:doctor), 'a clinician in good standing may sign');

select pg_temp.asserts(
  not clinician_may_sign(:lapsed), 'a clinician whose licence has expired may not sign');

select pg_temp.asserts(
  not clinician_may_sign(:patient), 'a user who is not a clinician may not sign');

-- The lapsed clinician claims it, which is allowed — the licence check belongs
-- at signing, and a lapse between claim and signature is precisely the case.
select pg_temp.accepts(format($$
  update clinical_drafts
     set status = 'in_review', claimed_by = %L, claimed_at = now()
   where id = 'd0d0d0d0-0000-4000-8000-000000000001'
$$, :lapsed), 'a clinician with a lapsed licence can still claim a draft');

select pg_temp.refuses(format($$
  insert into clinical_reviews
    (draft_id, clinician_id, action, signed_body_sha256)
  values ('d0d0d0d0-0000-4000-8000-000000000001', %L, 'signed',
          encode(sha256(convert_to(
            (select body from clinical_drafts
              where id = 'd0d0d0d0-0000-4000-8000-000000000001'), 'UTF8')), 'hex'))
$$, :lapsed), 'a lapsed licence cannot sign a draft it claimed earlier');

-- Rejecting is not signing, and does not assert a licence we no longer hold.
-- A clinician who notices their own registration has lapsed must still be able
-- to hand the draft back rather than leaving it stuck in their name.
select pg_temp.accepts(format($$
  insert into clinical_reviews (draft_id, clinician_id, action, notes)
  values ('d0d0d0d0-0000-4000-8000-000000000001', %L, 'claimed', 'picking this up')
$$, :lapsed), 'a lapsed clinician can still record a claim');

select pg_temp.accepts(format($$
  update clinical_drafts
     set status = 'in_review', claimed_by = %L, claimed_at = now()
   where id = 'd0d0d0d0-0000-4000-8000-000000000001'
$$, :doctor), 'the draft returns to a clinician who can sign it');

-- A signature must be a signature OF something. The hash is what makes the
-- post-signature edit detectable, so a signed row without one is meaningless.
select pg_temp.refuses(format($$
  insert into clinical_reviews (draft_id, clinician_id, action)
  values ('d0d0d0d0-0000-4000-8000-000000000001', %L, 'signed')
$$, :doctor), 'a signature must carry the hash of what was signed');

-- And it must be the hash of what is actually there. Otherwise a console could
-- sign a hash of text it invented, and the gate would compare two numbers that
-- both came from the same lie.
select pg_temp.refuses(format($$
  insert into clinical_reviews (draft_id, clinician_id, action, signed_body_sha256)
  values ('d0d0d0d0-0000-4000-8000-000000000001', %L, 'signed',
          repeat('a', 64))
$$, :doctor), 'a signature over text the draft does not contain is refused');

select pg_temp.accepts(format($$
  insert into clinical_reviews
    (id, draft_id, clinician_id, action, signed_body_sha256, notes)
  values ('e0e0e0e0-0000-4000-8000-000000000001',
          'd0d0d0d0-0000-4000-8000-000000000001', %L, 'signed',
          encode(sha256(convert_to(
            (select body from clinical_drafts
              where id = 'd0d0d0d0-0000-4000-8000-000000000001'), 'UTF8')), 'hex'),
          'Agree with the trend; worth a repeat panel in three months.')
$$, :doctor), 'a clinician in good standing signs the draft');

select pg_temp.accepts($$
  update clinical_drafts set status = 'signed'
   where id = 'd0d0d0d0-0000-4000-8000-000000000001'
$$, 'the draft becomes signed');


-- ── A signature cannot be edited or removed ──────────────────────────────────
--
-- clinical_reviews is the audit trail. An editable audit trail is not one, and
-- "who said this was safe" is the question the whole phase exists to answer.

select pg_temp.refuses($$
  update clinical_reviews set notes = 'actually I never saw this'
   where id = 'e0e0e0e0-0000-4000-8000-000000000001'
$$, 'a recorded review cannot be edited');

select pg_temp.refuses($$
  delete from clinical_reviews where id = 'e0e0e0e0-0000-4000-8000-000000000001'
$$, 'a recorded review cannot be deleted');

select pg_temp.asserts(
  not exists (
    select 1 from pg_policies
     where tablename = 'clinical_reviews'
       and cmd in ('UPDATE', 'DELETE', 'ALL')
  ),
  'no policy lets any user role alter a review');


-- ── The delivery gate is a hash, not a status ────────────────────────────────
--
-- `review.signed_body_sha256 == sha256(delivery_body)`. A status check would
-- pass for a draft edited after signing; the hash cannot, which is the whole
-- reason it is a hash.

select pg_temp.accepts(format($$
  insert into insights
    (id, user_id, draft_id, review_id, kind, title, body, evidence,
     noticed_by, reviewed_by, reviewed_at)
  values ('f0f0f0f0-0000-4000-8000-000000000001', %L,
          'd0d0d0d0-0000-4000-8000-000000000001',
          'e0e0e0e0-0000-4000-8000-000000000001', 'observation',
          'Your HbA1c has risen across three panels',
          (select body from clinical_drafts
            where id = 'd0d0d0d0-0000-4000-8000-000000000001'),
          '[{"biomarker_id":"hba1c","value":5.9,"collected_at":"2026-09-01"}]'::jsonb,
          'agent', %L, now())
$$, :patient, :doctor), 'a body matching the signature is delivered');

-- The case the plan names explicitly: one character.
select pg_temp.refuses(format($$
  insert into insights
    (user_id, draft_id, review_id, kind, title, body, noticed_by,
     reviewed_by, reviewed_at)
  values (%L, 'd0d0d0d0-0000-4000-8000-000000000001',
          'e0e0e0e0-0000-4000-8000-000000000001', 'observation', 't',
          (select body || '.' from clinical_drafts
            where id = 'd0d0d0d0-0000-4000-8000-000000000001'),
          'agent', %L, now())
$$, :patient, :doctor), 'a one-character edit after signing cannot be delivered');

-- Editing the draft itself is allowed — that is what `revised` is for — but it
-- must invalidate the signature rather than inherit it.
select pg_temp.accepts($$
  update clinical_drafts
     set body = body || ' Consider a repeat panel.', status = 'revised'
   where id = 'd0d0d0d0-0000-4000-8000-000000000001'
$$, 'a signed draft can still be revised');

select pg_temp.refuses(format($$
  insert into insights
    (user_id, draft_id, review_id, kind, title, body, noticed_by,
     reviewed_by, reviewed_at)
  values (%L, 'd0d0d0d0-0000-4000-8000-000000000001',
          'e0e0e0e0-0000-4000-8000-000000000001', 'observation', 't',
          (select body from clinical_drafts
            where id = 'd0d0d0d0-0000-4000-8000-000000000001'),
          'agent', %L, now())
$$, :patient, :doctor), 'a revised body cannot ride the old signature');

-- A claim is not a signature. `clinical_reviews` holds every action a clinician
-- took, and reading the latest row without checking which kind it is would let
-- a claim deliver the draft it claimed.
select pg_temp.refuses(format($$
  insert into insights
    (user_id, draft_id, review_id, kind, title, body, noticed_by,
     reviewed_by, reviewed_at)
  values (%L, 'd0d0d0d0-0000-4000-8000-000000000001',
          (select id from clinical_reviews where action = 'claimed' limit 1),
          'observation', 't', 'anything', 'agent', %L, now())
$$, :patient, :lapsed), 'a claim cannot deliver the draft it claimed');

-- Supabase retries webhooks, and the sweep is not transactional with the
-- insert. Without the uniqueness the same sentence arrives twice, which is how
-- an alert stops being believed.
select pg_temp.refuses(format($$
  insert into insights
    (user_id, draft_id, review_id, kind, title, body, noticed_by,
     reviewed_by, reviewed_at)
  values (%L, 'd0d0d0d0-0000-4000-8000-000000000001',
          'e0e0e0e0-0000-4000-8000-000000000001', 'observation', 't',
          %L, 'agent', %L, now())
$$, :patient,
    'Across your last three panels HbA1c moved from 5.4% to 5.9%.',
    :doctor), 'one signature delivers one insight, however often it is retried');

-- An insight claiming a reviewer must point at the review that says so. A
-- reviewed_by with no signature row is the forgery the trail exists to prevent.
select pg_temp.refuses(format($$
  insert into insights
    (user_id, draft_id, kind, title, body, noticed_by, reviewed_by, reviewed_at)
  values (%L, 'd0d0d0d0-0000-4000-8000-000000000001', 'observation', 't',
          'Trust me.', 'agent', %L, now())
$$, :patient, :doctor), 'an insight cannot name a reviewer without a signature');


-- ── The SLA escape hatch, and the hole it must not open ──────────────────────
--
-- The plan's de-risk for "the clinician queue becomes the bottleneck and the
-- product feels dead": after N hours, deliver the autonomous observation-only
-- version and mark the draft expired. That is a delivery with no signature,
-- which is exactly what the gate above forbids — so the rule has to be narrow
-- and the narrowness has to be tested, or the escape hatch quietly eats the
-- gate it was built beside.
--
-- Narrow rule: no routing flags, no named reviewer. A draft carrying a
-- supplement or medication flag is the content a clinician is meant to sign and
-- can NEVER take this path.

-- Walked through the machine rather than inserted at the far end, because a
-- draft is only ever created as `drafted` — a status that asserts a human acted
-- must not be typeable on the way in.
insert into clinical_drafts
  (id, user_id, clinic_id, kind, title, body, model_version)
values ('d0d0d0d0-0000-4000-8000-000000000002', :patient,
        'c0c0c0c0-0000-4000-8000-000000000001', 'observation',
        'Your resting heart rate is trending down',
        'Your resting heart rate fell 4 bpm over the last month.',
        'insight-rules-v1');

update clinical_drafts set status = 'queued'
 where id = 'd0d0d0d0-0000-4000-8000-000000000002';
select pg_temp.accepts($$
  update clinical_drafts set status = 'expired'
   where id = 'd0d0d0d0-0000-4000-8000-000000000002'
$$, 'a draft nobody claimed in time expires');

select pg_temp.accepts(format($$
  insert into insights
    (user_id, draft_id, kind, title, body, noticed_by, delivery_route)
  values (%L, 'd0d0d0d0-0000-4000-8000-000000000002', 'observation',
          'Your resting heart rate is trending down',
          (select body from clinical_drafts
            where id = 'd0d0d0d0-0000-4000-8000-000000000002'),
          'agent', 'sla_expired')
$$, :patient), 'an unflagged observation can be delivered unreviewed after the SLA');

insert into clinical_drafts
  (id, user_id, clinic_id, kind, title, body, model_version, routing_flags)
values ('d0d0d0d0-0000-4000-8000-000000000003', :patient,
        'c0c0c0c0-0000-4000-8000-000000000001', 'supplement',
        'Magnesium before bed',
        'Magnesium glycinate 200mg before bed would help your sleep.',
        'supplement-rules-v1', array['supplement']);

update clinical_drafts set status = 'queued'
 where id = 'd0d0d0d0-0000-4000-8000-000000000003';
update clinical_drafts set status = 'expired'
 where id = 'd0d0d0d0-0000-4000-8000-000000000003';

select pg_temp.refuses(format($$
  insert into insights
    (user_id, draft_id, kind, title, body, noticed_by, delivery_route)
  values (%L, 'd0d0d0d0-0000-4000-8000-000000000003', 'supplement',
          'Magnesium before bed',
          (select body from clinical_drafts
            where id = 'd0d0d0d0-0000-4000-8000-000000000003'),
          'agent', 'sla_expired')
$$, :patient), 'a flagged draft can never be delivered unreviewed');


-- A withdrawal has to beat a signature that is still sitting there, valid, and
-- hashing correctly. `withdrawn` is reachable from `signed`, so this is the one
-- case where a passing hash check must still not deliver.
insert into clinical_drafts
  (id, user_id, clinic_id, kind, title, body, model_version)
values ('d0d0d0d0-0000-4000-8000-000000000004', :patient,
        'c0c0c0c0-0000-4000-8000-000000000001', 'observation',
        'Withdrawn before it was sent', 'Never mind.', 'insight-rules-v1');

update clinical_drafts set status = 'queued'
 where id = 'd0d0d0d0-0000-4000-8000-000000000004';
update clinical_drafts
   set status = 'in_review', claimed_by = :doctor, claimed_at = now()
 where id = 'd0d0d0d0-0000-4000-8000-000000000004';
insert into clinical_reviews
  (id, draft_id, clinician_id, action, signed_body_sha256)
values ('e0e0e0e0-0000-4000-8000-000000000004',
        'd0d0d0d0-0000-4000-8000-000000000004', :doctor, 'signed',
        encode(sha256(convert_to('Never mind.', 'UTF8')), 'hex'));
update clinical_drafts set status = 'signed'
 where id = 'd0d0d0d0-0000-4000-8000-000000000004';
update clinical_drafts set status = 'withdrawn'
 where id = 'd0d0d0d0-0000-4000-8000-000000000004';

select pg_temp.refuses(format($$
  insert into insights
    (user_id, draft_id, review_id, kind, title, body, noticed_by,
     reviewed_by, reviewed_at)
  values (%L, 'd0d0d0d0-0000-4000-8000-000000000004',
          'e0e0e0e0-0000-4000-8000-000000000004', 'observation',
          'Withdrawn before it was sent', 'Never mind.', 'agent', %L, now())
$$, :patient, :doctor), 'a withdrawn draft is not delivered on a valid signature');


-- ── What the user finally sees ───────────────────────────────────────────────

set local role authenticated;
set local request.jwt.claims = :'patient_jwt';

select pg_temp.sees(
  'select 1 from insights',
  2, 'the user reads the insights delivered to them');

reset role;
set local role authenticated;
set local request.jwt.claims = :'other_jwt';

select pg_temp.sees(
  'select 1 from insights',
  0, 'and nobody else''s');

reset role;

-- No insert policy at all: an insight the user wrote themselves would carry a
-- clinician's name on a sentence no clinician saw.
set local role authenticated;
set local request.jwt.claims = :'patient_jwt';

select pg_temp.refuses_rls($$
  insert into insights (user_id, kind, title, body, noticed_by)
  values (auth.uid(), 'observation', 'I am in perfect health', 'Signed, me.', 'agent')
$$, 'a user cannot write themselves an insight');

-- A signed insight the user disagrees with needs a dispute path, not just a
-- dismiss button. They may say so, and that is all they may do — the same
-- mechanism lab_escalations uses for acknowledgement, because RLS decides which
-- ROWS a policy admits and cannot restrict which COLUMNS an update touches.
select pg_temp.accepts($$
  update insights
     set disputed_at = now(), dispute_reason = 'My doctor already knows about this.'
   where id = 'f0f0f0f0-0000-4000-8000-000000000001'
$$, 'the user can dispute an insight');

select pg_temp.accepts($$
  update insights set dismissed_at = now()
   where id = 'f0f0f0f0-0000-4000-8000-000000000001'
$$, 'the user can dismiss an insight');

select pg_temp.refuses_rls($$
  update insights set body = 'My doctor says I am immortal.'
   where id = 'f0f0f0f0-0000-4000-8000-000000000001'
$$, 'the user cannot rewrite what a clinician signed');

select pg_temp.refuses_rls(format($$
  update insights set reviewed_by = %L
   where id = 'f0f0f0f0-0000-4000-8000-000000000001'
$$, :patient), 'the user cannot put a name against their own insight');

reset role;


-- ── Deleting an account takes the whole trail with it ────────────────────────
--
-- 006 shipped score_snapshots with no foreign key and every snapshot outlived
-- the account it described until 012 fixed it. `delete_own_account` deletes the
-- auth.users row and relies on cascades for everything else, so a missing FK
-- here is a silent DPDP failure — and a draft is the most sensitive row of the
-- three, because it is the one nobody has checked.

select pg_temp.asserts(
  (select count(*) from pg_constraint
    where conname in ('clinical_drafts_user_fkey', 'insights_user_fkey')
      and confdeltype = 'c') = 2,
  'drafts and insights cascade when the account is deleted');

-- A review cascades from its draft rather than from the clinician: a clinician
-- leaving must not erase the signatures that explain insights other people are
-- still looking at.
select pg_temp.asserts(
  exists (
    select 1 from pg_constraint
     where conname = 'clinical_reviews_draft_fkey' and confdeltype = 'c'
  ),
  'a review cascades from the draft it reviewed');

select pg_temp.asserts(
  exists (
    select 1 from pg_constraint
     where conname = 'clinical_reviews_clinician_fkey' and confdeltype <> 'c'
  ),
  'a review does not vanish when the clinician does');


-- ── F6: the supplement asymmetry, end to end ─────────────────────────────────
--
-- F5's drafts were all observation-only and therefore all eligible for the SLA
-- escape hatch. A supplement draft is the first one that is not, and the
-- asymmetry is the whole point of the phase, so it is tested from both sides
-- against a draft that looks like the ones the producer actually writes.
--
-- Note the flag. `app/clinical/supplement_drafts.py` does not choose it: it
-- runs the body through the guardrail's clinician profile and carries back
-- whatever that returns, which for a supplement recommendation is `medication`
-- rather than `supplement`. The gate must therefore key on *any* flag being
-- present and never on a flag it recognises -- otherwise a draft carrying a
-- flag nobody enumerated would take the unreviewed path.

insert into clinical_drafts
  (id, user_id, clinic_id, kind, title, body, evidence, model_version,
   source_kind, routing_flags, dedupe_key)
values ('d0d0d0d0-0000-4000-8000-000000000005', :patient,
        'c0c0c0c0-0000-4000-8000-000000000001', 'supplement',
        'Vitamin D (25-OH) is below the standard range',
        'Vitamin D (25-OH) was 14 ng/mL on 30 September 2026, below the '
        'standard range of 30–100 ng/mL. Vitamin D supplementation is the '
        'usual response to a level this low, at a dose and duration a '
        'clinician sets.',
        '[{"kind":"measurement","biomarker_id":"vitamin_d_25oh",'
        '"value_canonical":14,"unit_canonical":"ng/mL",'
        '"collected_at":"2026-09-30","context":"standard",'
        '"lab_name":"Thyrocare"}]'::jsonb,
        'supplement-rule-v1', 'biomarker_deficiency',
        array['medication'], 'f6:supplement:vitamin_d_repletion');

update clinical_drafts set status = 'queued'
 where id = 'd0d0d0d0-0000-4000-8000-000000000005';
update clinical_drafts set status = 'expired'
 where id = 'd0d0d0d0-0000-4000-8000-000000000005';

select pg_temp.refuses(format($$
  insert into insights
    (user_id, draft_id, kind, title, body, noticed_by, delivery_route)
  values (%L, 'd0d0d0d0-0000-4000-8000-000000000005', 'supplement',
          'Vitamin D (25-OH) is below the standard range',
          (select body from clinical_drafts
            where id = 'd0d0d0d0-0000-4000-8000-000000000005'),
          'agent', 'sla_expired')
$$, :patient),
  'a supplement draft the queue gave up on is stranded, not delivered');


-- The other side. The same draft, reviewed: back to a human, claimed, signed
-- over the exact body, and delivered. If this failed, the phase would have
-- built a queue nothing can ever leave.
update clinical_drafts set status = 'delivered'
 where id = 'd0d0d0d0-0000-4000-8000-000000000005';

insert into clinical_drafts
  (id, user_id, clinic_id, kind, title, body, model_version, source_kind,
   routing_flags, dedupe_key)
values ('d0d0d0d0-0000-4000-8000-000000000006', :patient,
        'c0c0c0c0-0000-4000-8000-000000000001', 'supplement',
        'Magnesium is below the standard range',
        'Magnesium was 1.4 mg/dL on 30 September 2026, below the standard '
        'range of 1.7–2.2 mg/dL. Magnesium supplementation is the usual '
        'response to a level below the reference range, once the cause of the '
        'loss has been considered. Also recorded: Spironolactone 25mg. '
        'Potassium-sparing diuretics retain magnesium, so supplementing on top '
        'of one risks hypermagnesaemia, particularly with any renal '
        'impairment.',
        'supplement-rule-v1', 'biomarker_deficiency',
        array['medication'], 'f6:supplement:magnesium_repletion');

update clinical_drafts set status = 'queued'
 where id = 'd0d0d0d0-0000-4000-8000-000000000006';
update clinical_drafts
   set status = 'in_review', claimed_by = :doctor, claimed_at = now()
 where id = 'd0d0d0d0-0000-4000-8000-000000000006';

insert into clinical_reviews
  (id, draft_id, clinician_id, action, signed_body_sha256, notes)
select 'e0e0e0e0-0000-4000-8000-000000000006', id, :doctor, 'signed',
       encode(sha256(convert_to(body, 'UTF8')), 'hex'),
       'Agree. Reviewing the spironolactone dose first.'
  from clinical_drafts where id = 'd0d0d0d0-0000-4000-8000-000000000006';

update clinical_drafts set status = 'signed'
 where id = 'd0d0d0d0-0000-4000-8000-000000000006';

select pg_temp.accepts(format($$
  insert into insights
    (user_id, draft_id, review_id, kind, title, body, evidence, noticed_by)
  select %L, d.id, 'e0e0e0e0-0000-4000-8000-000000000006', d.kind, d.title,
         d.body, d.evidence, 'agent'
    from clinical_drafts d
   where d.id = 'd0d0d0d0-0000-4000-8000-000000000006'
$$, :patient), 'a signed supplement recommendation is delivered');

-- Stamped by the trigger from the signature, never accepted from the caller.
-- A supplement insight is the one the user is most likely to act on, so "who
-- stands behind this" has to be on the row rather than resolved at read time.
select pg_temp.asserts(
  exists (
    select 1 from insights
     where draft_id = 'd0d0d0d0-0000-4000-8000-000000000006'
       and delivery_route = 'clinician_signed'
       and reviewed_by = :doctor
       and reviewer_name = 'Dr A. Example'
       and reviewer_registration is not null
  ),
  'the delivered supplement names the clinician who signed it');

-- The gate, on the row that was actually written: the stored hash of the
-- delivered body equals the hash the clinician signed.
select pg_temp.asserts(
  (select i.body_sha256 = r.signed_body_sha256
     from insights i
     join clinical_reviews r on r.id = i.review_id
    where i.draft_id = 'd0d0d0d0-0000-4000-8000-000000000006'),
  'the supplement the user reads is byte-identical to what was signed');

-- A supplement draft a clinician rejected must not then leak out by the SLA
-- path. `rejected` only moves to `withdrawn`, so this is the machine and the
-- gate agreeing rather than either alone.
insert into clinical_drafts
  (id, user_id, clinic_id, kind, title, body, model_version, routing_flags,
   dedupe_key)
values ('d0d0d0d0-0000-4000-8000-000000000007', :patient,
        'c0c0c0c0-0000-4000-8000-000000000001', 'supplement',
        'Ferritin is below the standard range',
        'Ferritin was 10 ng/mL on 30 September 2026, below the standard range '
        'of 15–200 ng/mL. Iron supplementation is the usual response to a '
        'ferritin this low, once the reason for the loss has been considered.',
        'supplement-rule-v1', array['medication'],
        'f6:supplement:iron_repletion');

update clinical_drafts set status = 'queued'
 where id = 'd0d0d0d0-0000-4000-8000-000000000007';
update clinical_drafts
   set status = 'in_review', claimed_by = :doctor, claimed_at = now()
 where id = 'd0d0d0d0-0000-4000-8000-000000000007';
insert into clinical_reviews (draft_id, clinician_id, action, notes)
values ('d0d0d0d0-0000-4000-8000-000000000007', :doctor, 'rejected',
        'Investigating the cause first; not a supplement question yet.');
update clinical_drafts set status = 'rejected'
 where id = 'd0d0d0d0-0000-4000-8000-000000000007';

select pg_temp.refuses($$
  update clinical_drafts set status = 'expired'
   where id = 'd0d0d0d0-0000-4000-8000-000000000007'
$$, 'a rejected supplement draft cannot be expired into the SLA path');


rollback;
