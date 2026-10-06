-- Does a phone sync destroy server-written data?
--
-- The whole clinical-intelligence programme depends on the backend being able to
-- write a lab value, a genotype or a derived measurement and have it survive.
-- `save_normalized_wellness` deletes everything the user owns and re-inserts the
-- phone's copy, so without an ownership column it does not.
--
-- Runs inside a transaction that ALWAYS rolls back: it deletes the test user's
-- real rows as part of the exercise, and must never leave that committed.
--
--   psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/sync_ownership_test.sql

\set uid '\'c3c4eefd-b60c-438e-8cdc-0f3f0fde7617\''

begin;

-- A row the backend wrote: a lab-derived measurement the phone has never seen.
insert into public.health_measurements
  (id, user_id, measurement_type, value, unit, recorded_at, source, quality, origin)
values
  (gen_random_uuid(), :uid, 'glucose', 92.0, 'mg/dL', now(), 'lab_extraction', 'confirmed', 'server');

-- A lab result the backend extracted from an uploaded PDF.
insert into public.lab_results (id, user_id, title, recorded_at, notes, fields, origin)
values (gen_random_uuid(), :uid, 'Fasting glucose', now(), '',
        '{"value":"92","unit":"mg/dL"}'::jsonb, 'server');

-- Now the phone syncs. Its payload knows nothing about either row.
set local role authenticated;
set local request.jwt.claims = '{"sub":"c3c4eefd-b60c-438e-8cdc-0f3f0fde7617"}';

select public.save_normalized_wellness(
  '{"profile":{},"demo":false,"measurements":[],"entries":[],"ring":{}}'::jsonb
);

reset role;

-- Both must still be here.
do $$
declare
  m integer;
  l integer;
begin
  select count(*) into m from public.health_measurements
   where user_id = 'c3c4eefd-b60c-438e-8cdc-0f3f0fde7617' and source = 'lab_extraction';
  select count(*) into l from public.lab_results
   where user_id = 'c3c4eefd-b60c-438e-8cdc-0f3f0fde7617' and title = 'Fasting glucose';

  if m <> 1 then
    raise exception 'FAIL: server-written health_measurement destroyed by phone sync (found %)', m;
  end if;
  if l <> 1 then
    raise exception 'FAIL: server-written lab_result destroyed by phone sync (found %)', l;
  end if;
  raise notice 'PASS: server-written rows survived a phone sync';
end $$;

-- Round trip: a server-written row must not come back to the phone, or the next
-- save would re-insert it as the phone's own and duplicate it on every sync.
set local role authenticated;
set local request.jwt.claims = '{"sub":"c3c4eefd-b60c-438e-8cdc-0f3f0fde7617"}';

do $$
declare
  doc jsonb;
  leaked integer;
begin
  doc := public.load_normalized_wellness();
  select count(*) into leaked
    from jsonb_array_elements(coalesce(doc -> 'measurements', '[]'::jsonb)) m
   where m ->> 'source' = 'lab_extraction';
  if leaked <> 0 then
    raise exception
      'FAIL: % server-written measurement(s) returned to the phone; the next save would duplicate them',
      leaked;
  end if;
  raise notice 'PASS: server-written rows are not returned to the phone';
end $$;

reset role;

-- Regression: the phone's own data must still round-trip exactly as before.
set local role authenticated;
set local request.jwt.claims = '{"sub":"c3c4eefd-b60c-438e-8cdc-0f3f0fde7617"}';

do $$
declare
  doc jsonb;
  n integer;
begin
  perform public.save_normalized_wellness(jsonb_build_object(
    'profile', '{}'::jsonb, 'demo', false, 'ring', '{}'::jsonb,
    'entries', '[]'::jsonb,
    'measurements', jsonb_build_array(jsonb_build_object(
      'id', gen_random_uuid(), 'measurement_type', 'heartRate', 'value', 61,
      'unit', 'bpm', 'recorded_at', now(), 'source', 'manual'))));

  doc := public.load_normalized_wellness();
  select count(*) into n
    from jsonb_array_elements(coalesce(doc -> 'measurements', '[]'::jsonb)) m
   where m ->> 'source' = 'manual';
  if n <> 1 then
    raise exception 'FAIL: the phone can no longer round-trip its own data (found %)', n;
  end if;
  raise notice 'PASS: app-owned data still round-trips';
end $$;

reset role;

rollback;
