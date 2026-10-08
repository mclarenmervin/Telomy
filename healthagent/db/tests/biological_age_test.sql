-- What 012_biological_age.sql has to guarantee.
--
-- Two gaps found while building F4, both of the same shape as the one that bit
-- F3 on a real device: a table the phone must write to, with RLS enabled and no
-- INSERT policy, invisible because every other test path bypasses RLS.
--
-- Runs inside a transaction that always rolls back.
--
--   psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f db/tests/biological_age_test.sql

\set uid '\'c3c4eefd-b60c-438e-8cdc-0f3f0fde7617\''
\set ghost '\'00000000-dead-4000-8000-000000000001\''

begin;

-- Only an integrity violation counts. A missing table or a typo is a broken
-- test, not a passing one.
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
-- from `refuses` because a constraint failure and a policy denial are different
-- claims and a test should say which it expects.
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

insert into auth.users (id, email)
values (:uid, 'biological-age-test@example.com')
on conflict (id) do nothing;


-- ── A biological age is a score, not a new table ─────────────────────────────

select pg_temp.accepts(format($$
  insert into score_snapshots
    (user_id, score_kind, as_of_date, value, data_quality, model_version,
     ranges_version, inputs_hash)
  values (%L, 'biological_age', '2026-06-15', 43.2, 'full',
          'biological-age-phenoage-levine-2018-v1', 'global.v1', 'sha256:a')
$$, :uid), 'a biological age stores as a score_snapshots row');

-- The gate while the catalog is unreviewed: a row that records we looked and
-- are not giving a number. Null plus 'none' is the only honest shape for it.
select pg_temp.accepts(format($$
  insert into score_snapshots
    (user_id, score_kind, as_of_date, value, data_quality, model_version,
     missing_inputs, inputs_hash)
  values (%L, 'biological_age', '2026-06-16', null, 'none',
          'biological-age-phenoage-levine-2018-v1',
          array['clinical_review'], 'sha256:b')
$$, :uid), 'a withheld biological age stores as unknown');

-- A zero biological age is not a thing. The constraint is what stops a null
-- becoming one somewhere between here and the screen.
select pg_temp.refuses(format($$
  insert into score_snapshots
    (user_id, score_kind, as_of_date, value, data_quality, model_version, inputs_hash)
  values (%L, 'biological_age', '2026-06-17', null, 'full',
          'biological-age-phenoage-levine-2018-v1', 'sha256:c')
$$, :uid), 'an unknown biological age cannot claim to be a complete one');

select pg_temp.refuses(format($$
  insert into score_snapshots
    (user_id, score_kind, as_of_date, value, data_quality, model_version,
     missing_inputs, inputs_hash)
  values (%L, 'biological_age', '2026-06-18', 43.2, 'full',
          'biological-age-phenoage-levine-2018-v1',
          array['mcv'], 'sha256:d')
$$, :uid), 'a complete biological age cannot also be missing a marker');


-- ── Deleting an account takes its scores with it ─────────────────────────────
--
-- 006 declared `user_id uuid not null` and no foreign key, so every snapshot
-- survived the account it described. 007 added the cascade for lab_uploads,
-- biomarker_results and epigenetic_results and did not reach this table --
-- which mattered less when the only score was a readiness number and matters a
-- great deal now that one of them is a biological age.

select pg_temp.asserts(
  exists (
    select 1 from pg_constraint
     where conname = 'score_snapshots_user_fkey' and confdeltype = 'c'
  ),
  'a score snapshot cascades when the account is deleted');

select pg_temp.refuses(format($$
  insert into score_snapshots
    (user_id, score_kind, as_of_date, value, data_quality, model_version, inputs_hash)
  values (%L, 'biological_age', '2026-06-15', 43.2, 'full', 'm', 'sha256:e')
$$, :ghost), 'a score cannot be stored for an account that does not exist');


-- ── The phone can record a clock it paid for ─────────────────────────────────
--
-- 005 enabled RLS on epigenetic_results with a SELECT policy and no INSERT
-- policy. The feature is "display the third-party clocks the user already has",
-- and there was no way for the user to tell us about one -- the same shape of
-- bug as F3's lab_uploads insert, which failed with 42501 on a real device.

set local role authenticated;
set local request.jwt.claims = '{"sub":"c3c4eefd-b60c-438e-8cdc-0f3f0fde7617","role":"authenticated"}';

select pg_temp.accepts(format($$
  insert into epigenetic_results (user_id, clock, value, unit, provider, collected_at)
  values (%L, 'horvath', 41.3, 'years', 'TruDiagnostic', '2026-03-01')
$$, :uid), 'the phone can record its own epigenetic clock result');

select pg_temp.refuses_rls(format($$
  insert into epigenetic_results (user_id, clock, value, unit, provider, collected_at)
  values (%L, 'horvath', 41.3, 'years', 'TruDiagnostic', '2026-03-01')
$$, :ghost), 'the phone cannot record a clock result for another account');

-- A clock is a rate or an age depending on which clock it is, so the unit
-- travels with the value and the user may correct a typo in their own row.
select pg_temp.accepts(format($$
  update epigenetic_results set value = 41.5
   where user_id = %L and clock = 'horvath'
$$, :uid), 'the user can correct their own clock result');

select pg_temp.accepts(format($$
  delete from epigenetic_results where user_id = %L and clock = 'horvath'
$$, :uid), 'the user can remove their own clock result');

reset role;

-- Nothing may claim one of these is ours. The check constraint in 005 is the
-- enforcement and the insert policy must not have widened it.
select pg_temp.refuses(format($$
  insert into epigenetic_results
    (user_id, clock, value, unit, provider, collected_at, source)
  values (%L, 'horvath', 41.3, 'years', 'Telomy', '2026-03-01', 'computed')
$$, :uid), 'an epigenetic clock cannot be recorded as our own computation');

-- A clock we do not carry is refused rather than stored as free text, or the
-- app ends up rendering a name it has no idea how to label.
select pg_temp.refuses(format($$
  insert into epigenetic_results (user_id, clock, value, unit, provider, collected_at)
  values (%L, 'my_own_clock', 41.3, 'years', 'Someone', '2026-03-01')
$$, :uid), 'an unknown epigenetic clock is refused');

-- An epigenetic result has no meaning without a date -- it is a measurement of
-- a sample taken on a day, and a trend of undated points is not a trend.
select pg_temp.refuses(format($$
  insert into epigenetic_results (user_id, clock, value, unit, provider)
  values (%L, 'hannum', 44.0, 'years', 'Someone')
$$, :uid), 'an epigenetic result needs a collection date');


-- ── The phone cannot write its own scores ────────────────────────────────────
--
-- Postgres holds facts, Python computes, Flutter renders. A client that could
-- insert a score_snapshots row could put any biological age on its own screen
-- and bypass the clinical-review gate entirely, which is the one thing that
-- gate exists to prevent.

set local role authenticated;
set local request.jwt.claims = '{"sub":"c3c4eefd-b60c-438e-8cdc-0f3f0fde7617","role":"authenticated"}';

select pg_temp.refuses_rls(format($$
  insert into score_snapshots
    (user_id, score_kind, as_of_date, value, data_quality, model_version, inputs_hash)
  values (%L, 'biological_age', '2026-07-01', 25.0, 'full', 'mine', 'sha256:f')
$$, :uid), 'the phone cannot write itself a biological age');

reset role;

-- An UPDATE or DELETE with no policy to permit it matches no rows and therefore
-- succeeds trivially rather than raising 42501 -- so the absence of the policy
-- is what has to be asserted, which is how storage_purges is tested too. An
-- INSERT does raise, because its WITH CHECK is evaluated on the new row.
select pg_temp.asserts(
  not exists (
    select 1 from pg_policies
     where tablename = 'score_snapshots' and cmd in ('INSERT', 'UPDATE', 'DELETE', 'ALL')
  ),
  'no policy lets any user role write a score');

-- And it can still read its own, which is how the screen works at all.
select pg_temp.asserts(
  exists (
    select 1 from pg_policies
     where tablename = 'score_snapshots' and cmd = 'SELECT'
  ),
  'a user can read their own scores');

rollback;
