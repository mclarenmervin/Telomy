-- Enough of a wearable history for the Correlations screen to have something
-- to show, and for the therapy engine to have a run of sessions.
--
--   psql "$SUPABASE_DB_URL" -f db/dev_correlations_demo.sql
--
-- DEV ONLY. Writes to test-harness@example.com and nobody else, and is
-- idempotent: re-running it replaces its own rows rather than doubling them.
--
-- ── What it seeds, and why it is not random ────────────────────────────────
--
-- Sixty days of HRV, resting heart rate and sleep, built so that exactly one
-- declared pair holds and the others do not. That is the point: a seed where
-- everything correlates proves nothing about a screen whose whole job is to
-- refuse most things.
--
--   * HRV and resting heart rate move oppositely, strongly. `hrv__resting_
--     heart_rate` expects negative, so this one should be REPORTED.
--   * sleep duration wanders independently, so `hrv__sleep_duration` and
--     `resting_heart_rate__sleep_duration` should be WITHHELD as not
--     significant -- which is what makes the "also tested, not shown"
--     section appear with a real reason in it.
--
-- The series are deliberately not smooth ramps. A monotone ramp is perfectly
-- autocorrelated and the effective-sample-size adjustment would throw almost
-- all of it away, which would be correct and would leave the screen empty.
-- A day-to-day zigzag is what a real wearable looks like.
--
-- Eight sauna sessions, three days apart, each with a reading an hour either
-- side showing the heart rate raised afterwards -- the direction
-- `therapies.v1.yaml` predicts, so the therapy engine should report it.

do $$
declare
  uid uuid;
  day integer;
  stamp timestamptz;
  swing numeric;
  session_start timestamptz;
begin
  select id into uid from auth.users where email = 'test-harness@example.com';
  if uid is null then
    raise exception 'test-harness@example.com does not exist';
  end if;

  delete from health_measurements
   where user_id = uid and source = 'correlations-demo';
  delete from events
   where user_id = uid and source = 'manual'
     and metadata->>'seed' = 'correlations-demo';

  for day in 0..59 loop
    stamp := date_trunc('day', now()) - make_interval(days => day) + interval '7 hours';
    -- A zigzag rather than a ramp, so consecutive days are not near-identical.
    swing := (array[0,3,1,4,2,5,1,3,0,4,2,5,3,1])[(day % 14) + 1];

    -- `origin = 'server'` is load bearing, not decoration: with the default
    -- of 'app' the phone's `save_normalized_wellness` would delete every one
    -- of these on the next sync, and it would look like the engine losing
    -- data days later. That is the defect F0 exists to prevent, and a seed
    -- script is exactly where somebody forgets it.
    insert into health_measurements
      (id, user_id, measurement_type, value, unit, recorded_at, source,
       quality, origin)
    values
      (gen_random_uuid(), uid, 'hrv', 42 + swing * 3, 'ms', stamp,
       'correlations-demo', 'measured', 'server'),
      -- The inverse of HRV, which is the mechanism the catalog declares,
      -- plus a little noise of its own. Without it the pair comes out at
      -- exactly -1.000, which is a number no real wearable has ever
      -- produced and which makes a screenshot look like a mock.
      (gen_random_uuid(), uid, 'restingHeartRate',
       68 - swing * 2 + (array[0.0,1.4,-0.9,0.6,-1.7,1.1,-0.4])[(day % 7) + 1],
       'bpm', stamp, 'correlations-demo', 'measured', 'server'),
      -- Independent of both: a different period, so it should NOT hold.
      (gen_random_uuid(), uid, 'sleep', 6.0 + ((day * 7) % 5) * 0.4, 'hours',
       stamp - interval '1 hours', 'correlations-demo', 'measured', 'server');
  end loop;

  -- Eight sauna sessions, every third day, with a before and an after.
  for day in 0..7 loop
    session_start := date_trunc('day', now()) - make_interval(days => day * 3)
                     + interval '18 hours';
    insert into events (user_id, event_type, status, source, started_at, ended_at,
                        metadata)
    values (uid, 'sauna', 'ended', 'manual', session_start,
            session_start + interval '20 minutes',
            jsonb_build_object('seed', 'correlations-demo'));

    insert into health_measurements
      (id, user_id, measurement_type, value, unit, recorded_at, source,
       quality, origin)
    values
      (gen_random_uuid(), uid, 'heartRate', 62 + (day % 3), 'bpm',
       session_start - interval '30 minutes', 'correlations-demo', 'measured',
       'server'),
      (gen_random_uuid(), uid, 'heartRate', 79 + (day % 3), 'bpm',
       session_start + interval '50 minutes', 'correlations-demo', 'measured',
       'server');
  end loop;
end $$;

select 'measurements' as what, count(*) from health_measurements
 where source = 'correlations-demo'
union all
select 'sauna events', count(*) from events
 where event_type = 'sauna' and metadata->>'seed' = 'correlations-demo';
