-- The score_snapshots constraints encode honesty properties: an unknown score
-- must not read as a zero, and 'full' must not be claimed over gaps.
--
--   psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f db/tests/score_snapshots_test.sql

\set uid '\'c3c4eefd-b60c-438e-8cdc-0f3f0fde7617\''

begin;

create or replace function pg_temp.refuses(stmt text, label text)
returns void language plpgsql as $$
declare state text;
begin
  begin
    execute stmt;
  exception
    when integrity_constraint_violation then
      raise notice 'PASS: %', label; return;
    when others then
      get stacked diagnostics state = returned_sqlstate;
      raise exception 'FAIL: % — refused for the wrong reason (SQLSTATE %)', label, state;
  end;
  raise exception 'FAIL: % — the database accepted it', label;
end $$;

-- A real snapshot inserts cleanly.
insert into score_snapshots
  (user_id, score_kind, as_of_date, value, data_quality, model_version, inputs_hash, timezone)
values (:uid, 'readiness', date '2026-10-01', 72, 'full', 'readiness-v1',
        'sha256:abc', 'Asia/Kolkata');

-- Recomputing the same day replaces it rather than duplicating.
insert into score_snapshots
  (user_id, score_kind, as_of_date, value, data_quality, model_version, inputs_hash, timezone)
values (:uid, 'readiness', date '2026-10-01', 74, 'full', 'readiness-v1',
        'sha256:def', 'Asia/Kolkata')
on conflict (user_id, score_kind, as_of_date) do update
  set value = excluded.value, inputs_hash = excluded.inputs_hash,
      computed_at = now();

do $$
declare n integer; v double precision;
begin
  select count(*), max(value) into n, v from score_snapshots
   where user_id = 'c3c4eefd-b60c-438e-8cdc-0f3f0fde7617'
     and score_kind = 'readiness' and as_of_date = date '2026-10-01';
  if n <> 1 or v <> 74 then
    raise exception 'FAIL: recomputing a day did not replace it (n=%, value=%)', n, v;
  end if;
  raise notice 'PASS: recomputing a day replaces rather than duplicates';
end $$;

select pg_temp.refuses($$
  insert into score_snapshots
    (user_id, score_kind, as_of_date, value, data_quality, model_version, inputs_hash)
  values ('c3c4eefd-b60c-438e-8cdc-0f3f0fde7617', 'readiness', date '2026-10-02',
          null, 'full', 'readiness-v1', 'sha256:abc')
$$, 'an absent score claiming full quality is refused');

select pg_temp.refuses($$
  insert into score_snapshots
    (user_id, score_kind, as_of_date, value, data_quality, model_version,
     inputs_hash, missing_inputs)
  values ('c3c4eefd-b60c-438e-8cdc-0f3f0fde7617', 'readiness', date '2026-10-03',
          72, 'full', 'readiness-v1', 'sha256:abc', array['HRV'])
$$, 'claiming full quality while inputs are missing is refused');

select pg_temp.refuses($$
  insert into score_snapshots
    (user_id, score_kind, as_of_date, value, data_quality, model_version, inputs_hash)
  values ('c3c4eefd-b60c-438e-8cdc-0f3f0fde7617', 'horoscope', date '2026-10-04',
          72, 'full', 'v1', 'sha256:abc')
$$, 'an unknown score kind is refused');

rollback;
