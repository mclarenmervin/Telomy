-- What the air and the sun were doing where the user was, per day.
--
-- The environment form in the app asks people to type an AQI and a UV index
-- in by hand and nothing reads what they type. This is the real source
-- behind it.
--
-- ── The location rules, and where each one is enforced ──────────────────────
--
-- Answering "what was the air like where you were" requires knowing where
-- somebody was, and this product has had no reason to know that until now.
-- Three rules, each enforced somewhere it cannot be forgotten:
--
--   * COARSE. One decimal place, about 11 km: a city, not a street. The
--     check constraint below is the enforcement, so a row at six decimals
--     cannot be written by any caller, including ours. `environment.coarsen`
--     rounds on the way in as well, because the rule has to hold against our
--     own app being wrong and not only against somebody else's.
--
--   * CONSENT. `user_preferences.profile->>'consentLocation'` gates the
--     scheduler's fetch. It is deliberately NOT a column here: a consent flag
--     living next to the data it authorises is one somebody eventually reads
--     from the wrong row, and the profile is where every other consent in
--     this product already lives.
--
--   * PROVENANCE. `provider` is not decoration. "The AQI was 180" is a claim
--     somebody else made, and a user is entitled to know who made it and
--     when we asked.
--
-- ── Why a day and not a moment ──────────────────────────────────────────────
--
-- The first version of the adapter stored the provider's CURRENT UV index,
-- which at the hour a nightly job runs is 0.0. The day it was tested against
-- peaked at 10.2. So UV is the day's maximum, from the provider's own daily
-- aggregate, and the air-quality figures are averaged from the 24 hourly
-- values in Python -- arithmetic is ours (P2).
--
-- Both a mean and a max for AQI: a day that averaged 90 and peaked at 180 for
-- three hours is a different day from one that sat at 90 throughout.
--
-- ── What this is for ────────────────────────────────────────────────────────
--
-- Context, in the same sense a genetic variant is. The number sits beside
-- what was measured about the person; the connection between the two is a
-- claim nobody has reviewed, and the agent is told so.

create table if not exists environment_snapshots (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,

  -- The day this describes, in UTC, matching the window the provider was
  -- asked for. Not a timestamp: this is a day's conditions and storing an
  -- instant would invite somebody to read it as one.
  observed_on date not null,

  -- Coarse, and the constraint is what makes that true rather than
  -- intended. `scale` of 1 is the rounding; the bounds are the planet.
  latitude numeric(4,1) not null check (latitude between -90 and 90),
  longitude numeric(5,1) not null check (longitude between -180 and 180),

  us_aqi_mean numeric(6,1),
  us_aqi_max numeric(6,1),
  european_aqi_mean numeric(6,1),
  pm2_5_mean numeric(7,1),
  pm10_mean numeric(7,1),

  -- The day's peak, which is the question a UV index answers.
  uv_index_max numeric(4,2),

  -- How many hours of the day the provider actually had. A snapshot built
  -- from four hours is not a day, and whoever narrates it should know.
  hours_observed smallint not null default 0
    check (hours_observed between 0 and 24),

  provider text not null,
  fetched_at timestamptz not null default now(),

  -- One row per person per day. A second fetch updates it rather than
  -- adding a second opinion about the same day.
  unique (user_id, observed_on)
);

create index if not exists environment_snapshots_user_day_idx
  on environment_snapshots (user_id, observed_on desc);

alter table environment_snapshots enable row level security;

create policy "users read their own environment"
  on environment_snapshots for select
  using (user_id = (select auth.uid()));

-- No insert and no update policy: the scheduler writes these with the
-- service role. A client that could write one could put itself anywhere,
-- which would make `latitude` a field the user asserts rather than a fact.

-- Deletable, because withdrawing location consent should be able to take the
-- history with it and not only stop the next fetch.
create policy "users delete their own environment"
  on environment_snapshots for delete
  using (user_id = (select auth.uid()));

comment on table environment_snapshots is
  'One day of air quality and UV at a coarse (~11km) location. Written by the '
  'scheduler only, gated on profile consentLocation. Context beside a '
  'measurement, never a statement about what the air did to the person.';
