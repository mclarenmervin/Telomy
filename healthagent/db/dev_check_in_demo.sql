-- DEMO / DEV ONLY. Seeds a 14-day baseline plus an elevated "right now" window
-- for the demo user, then opens a sauna event so a mid-event check-in fires.
--
-- Why the seed is needed: every check-in rule is a deviation from the person's
-- OWN baseline. With no history there is nothing to deviate from, and the rule
-- correctly stays silent — so an unseeded demo looks broken when it is working.
--
-- Run section by section. Section 4 is the cleanup; run it when you are done.

-- ── 1. Baseline: 14 days of calm readings, every 30 minutes ──────────────────
-- Stops 90 minutes ago: analyze_event excludes the hour before the event from
-- the baseline, so anything newer would pollute what we are comparing against.
insert into health_measurements
  (id, user_id, measurement_type, value, unit, recorded_at, source, quality)
select
  gen_random_uuid(),
  'c3c4eefd-b60c-438e-8cdc-0f3f0fde7617',
  m.type,
  m.base + (random() - 0.5) * m.jitter,
  m.unit,
  ts,
  'demo_seed',
  'measured'
from generate_series(
       now() - interval '14 days',
       now() - interval '90 minutes',
       interval '30 minutes'
     ) as ts
cross join (values
  ('heartRate',    62.0, 3.0,  'bpm'),
  ('hrv',          55.0, 6.0,  'ms'),
  ('temperature',  36.5, 0.2,  '°C'),
  ('spo2',         97.0, 1.0,  '%')
) as m(type, base, jitter, unit);

-- ── 2. The last 20 minutes: heart rate well above that baseline ──────────────
-- ~+18 bpm, which clears both legs of the rule: the 12 bpm absolute delta and
-- the 2-sigma personal-spread check.
insert into health_measurements
  (id, user_id, measurement_type, value, unit, recorded_at, source, quality)
select
  gen_random_uuid(),
  'c3c4eefd-b60c-438e-8cdc-0f3f0fde7617',
  m.type,
  m.base + (random() - 0.5) * m.jitter,
  m.unit,
  ts,
  'demo_seed',
  'measured'
from generate_series(
       now() - interval '20 minutes',
       now(),
       interval '2 minutes'
     ) as ts
cross join (values
  ('heartRate',    80.0, 2.0,  'bpm'),
  ('hrv',          38.0, 3.0,  'ms'),
  ('temperature',  36.9, 0.2,  '°C'),
  ('spo2',         97.0, 1.0,  '%')
) as m(type, base, jitter, unit);

-- ── 3. Open the event. The webhook fires; the worker acks and sets the timer ──
insert into events (user_id, event_type, status, source, started_at)
values (
  'c3c4eefd-b60c-438e-8cdc-0f3f0fde7617',
  'sauna',
  'started',
  'manual',
  now() - interval '20 minutes'
)
returning id, started_at;

-- Watch the worker log, then read what it wrote:
--
--   select kind, summary, data_quality, guardrail_flags, created_at
--   from predictions
--   where user_id = 'c3c4eefd-b60c-438e-8cdc-0f3f0fde7617'
--   order by created_at desc limit 10;
--
-- Close the event (triggers the full end-of-event analysis):
--
--   update events set status = 'ended', ended_at = now()
--   where user_id = 'c3c4eefd-b60c-438e-8cdc-0f3f0fde7617' and status = 'started';

-- ── 4. Cleanup ───────────────────────────────────────────────────────────────
-- delete from health_measurements
--  where user_id = 'c3c4eefd-b60c-438e-8cdc-0f3f0fde7617' and source = 'demo_seed';
-- delete from predictions
--  where user_id = 'c3c4eefd-b60c-438e-8cdc-0f3f0fde7617';
-- delete from events
--  where user_id = 'c3c4eefd-b60c-438e-8cdc-0f3f0fde7617' and source = 'manual';
