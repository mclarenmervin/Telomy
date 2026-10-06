-- The constraints in 005_biomarkers.sql encode safety properties, so they are
-- tested rather than assumed. Each case asserts the database REFUSES something
-- that would otherwise corrupt a clinical result.
--
-- Runs inside a transaction that always rolls back.
--
--   psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f db/tests/biomarkers_schema_test.sql

\set uid '\'c3c4eefd-b60c-438e-8cdc-0f3f0fde7617\''

begin;

-- Only an integrity violation counts. A missing table or a typo is a broken
-- test, not a passing one — the trap this helper fell into first time around.
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

-- A range override must be citable.
select pg_temp.refuses($$
  insert into reference_range_overrides
    (scope, user_id, biomarker_id, standard_low, standard_high,
     optimal_low, optimal_high, version, citation, created_by)
  values ('user', 'c3c4eefd-b60c-438e-8cdc-0f3f0fde7617', 'hba1c',
          4.0, 6.5, 4.8, 5.4, 'user.v1', '   ',
          'c3c4eefd-b60c-438e-8cdc-0f3f0fde7617')
$$, 'an uncitable range override is refused');

-- Optimal must sit inside standard.
select pg_temp.refuses($$
  insert into reference_range_overrides
    (scope, user_id, biomarker_id, standard_low, standard_high,
     optimal_low, optimal_high, version, citation, created_by)
  values ('user', 'c3c4eefd-b60c-438e-8cdc-0f3f0fde7617', 'hba1c',
          4.0, 5.0, 4.8, 9.9, 'user.v1', 'Clinic protocol',
          'c3c4eefd-b60c-438e-8cdc-0f3f0fde7617')
$$, 'an optimal range escaping its standard range is refused');

-- A clinic-scoped override with no clinic is meaningless.
select pg_temp.refuses($$
  insert into reference_range_overrides
    (scope, biomarker_id, standard_low, standard_high,
     optimal_low, optimal_high, version, citation, created_by)
  values ('clinic', 'hba1c', 4.0, 6.5, 4.8, 5.4, 'clinic.v1', 'Protocol',
          'c3c4eefd-b60c-438e-8cdc-0f3f0fde7617')
$$, 'a clinic override with no clinic is refused');

-- The same document twice would double every value on the chart.
-- `storage_path` became `storage_prefix` in 007: a report is a folder of files,
-- not a single file, and the digest is now over the ordered set of file digests.
insert into lab_uploads (user_id, storage_prefix, content_sha256)
values (:uid, 'c3c4eefd/2026/a/', 'sha256:abc');

select pg_temp.refuses($$
  insert into lab_uploads (user_id, storage_prefix, content_sha256)
  values ('c3c4eefd-b60c-438e-8cdc-0f3f0fde7617', 'c3c4eefd/2026/b/', 'sha256:abc')
$$, 'a duplicate upload of the same document is refused');

-- A quantitative result with no number is not a result.
select pg_temp.refuses($$
  insert into biomarker_results (user_id, biomarker_id, result_type, raw_value)
  values ('c3c4eefd-b60c-438e-8cdc-0f3f0fde7617', 'hba1c', 'quantitative', '5.1')
$$, 'a quantitative result with no canonical value is refused');

-- A qualitative result must not be forced into the numeric column.
insert into biomarker_results
  (user_id, biomarker_id, result_type, value_text, raw_value)
values (:uid, 'hba1c', 'qualitative', 'Not detected', 'Not detected');

-- Censored results are first-class.
insert into biomarker_results
  (user_id, biomarker_id, operator, raw_value, raw_unit, value_canonical, unit_canonical)
values (:uid, 'hs_crp', '<', '<0.01', 'mg/L', 0.01, 'mg/L');

-- Nothing may claim an epigenetic clock as our own computation.
select pg_temp.refuses($$
  insert into epigenetic_results (user_id, clock, value, unit, provider, collected_at, source)
  values ('c3c4eefd-b60c-438e-8cdc-0f3f0fde7617', 'horvath', 41.2, 'years',
          'TruDiagnostic', now(), 'telomy_computed')
$$, 'an epigenetic result claimed as our own computation is refused');

-- New rows must be invisible to a phone sync.
do $$
declare
  listed boolean;
begin
  select exists (
    select 1 from pg_proc
     where proname = 'save_normalized_wellness'
       and prosrc like '%biomarker_results%'
  ) into listed;
  if listed then
    raise exception 'FAIL: biomarker_results is reachable from the phone sync';
  end if;
  raise notice 'PASS: the new tables are outside the phone sync';
end $$;

rollback;
