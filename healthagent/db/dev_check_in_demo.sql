-- DEV / TEST FIXTURE. Seeds a realistic 14-day baseline for the demo user and
-- opens an event, so the mid-event check-in path can be exercised end to end
-- while there are no real users yet.
--
-- Realism is the point. An earlier version of this file used near-constant
-- readings (sigma ~1 bpm), which made `hr_elevated` fire at 20 standard
-- deviations — a pass that predicted nothing about production. Real wrist and
-- ring data over a 14-day all-day window runs sigma ~10-15 bpm, because the
-- window spans sleep and waking. This fixture reproduces that spread:
--
--   * a circadian baseline (~52 bpm asleep, ~70 bpm awake)
--   * per-reading noise on top
--   * an event response sized like a real sauna session, not a caricature
--
-- A rule that fires here is a rule that will fire on a person.
--
-- Run sections 1-3. Section 4 is the cleanup.

-- ── 1. Baseline: 14 days, every 15 minutes, with a day/night rhythm ──────────
-- Stops 90 minutes ago: analyze_event excludes the hour before an event from
-- the baseline, so newer rows would pollute the comparison.
insert into health_measurements
  (id, user_id, measurement_type, value, unit, recorded_at, source, quality)
select
  gen_random_uuid(),
  'c3c4eefd-b60c-438e-8cdc-0f3f0fde7617',
  m.type,
  m.base
    + m.swing * cos(2 * pi() * (extract(hour from ts) - 4) / 24.0)
    + (random() - 0.5) * m.noise,
  m.unit,
  ts,
  'demo_seed',
  'measured'
from generate_series(
       now() - interval '14 days',
       now() - interval '90 minutes',
       interval '15 minutes'
     ) as ts
cross join (values
  -- base, swing (peak-to-trough/2 over the day), noise
  ('heartRate',    61.0,  9.0,  6.0,  'bpm'),
  ('hrv',          55.0, -9.0,  8.0,  'ms'),
  ('temperature',  36.5,  0.25, 0.15, '°C'),
  ('spo2',         97.0,  0.3,  1.2,  '%')
) as m(type, base, swing, noise, unit);

-- ── 2. The last 25 minutes: a realistic sauna response ───────────────────────
-- ~+28 bpm over the waking baseline and HRV down ~40%: large, but within what
-- a real sauna session produces. Not a caricature.
insert into health_measurements
  (id, user_id, measurement_type, value, unit, recorded_at, source, quality)
select
  gen_random_uuid(),
  'c3c4eefd-b60c-438e-8cdc-0f3f0fde7617',
  m.type,
  m.base + (random() - 0.5) * m.noise,
  m.unit,
  ts,
  'demo_seed',
  'measured'
from generate_series(
       now() - interval '25 minutes',
       now(),
       interval '2 minutes'
     ) as ts
cross join (values
  ('heartRate',    98.0, 7.0,  'bpm'),
  ('hrv',          33.0, 6.0,  'ms'),
  ('temperature',  37.4, 0.2,  '°C'),
  ('spo2',         97.0, 1.2,  '%')
) as m(type, base, noise, unit);

-- ── 3. Open the event ────────────────────────────────────────────────────────
insert into events (user_id, event_type, status, source, started_at)
values (
  'c3c4eefd-b60c-438e-8cdc-0f3f0fde7617',
  'sauna',
  'started',
  'manual',
  now() - interval '25 minutes'
)
returning id, started_at;

-- Read what the agent wrote:
--
--   select kind, summary, data_quality, guardrail_flags, created_at
--   from predictions
--   where user_id = 'c3c4eefd-b60c-438e-8cdc-0f3f0fde7617'
--   order by created_at desc limit 10;
--
-- Close it (runs the end-of-event analysis and stops the timer):
--
--   update events set status = 'ended', ended_at = now()
--   where user_id = 'c3c4eefd-b60c-438e-8cdc-0f3f0fde7617' and status = 'started';

-- ── 4. Cleanup ───────────────────────────────────────────────────────────────
-- delete from predictions where user_id = 'c3c4eefd-b60c-438e-8cdc-0f3f0fde7617';
-- delete from events where user_id = 'c3c4eefd-b60c-438e-8cdc-0f3f0fde7617';
-- delete from health_measurements
--  where user_id = 'c3c4eefd-b60c-438e-8cdc-0f3f0fde7617' and source = 'demo_seed';
