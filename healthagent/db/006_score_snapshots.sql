-- Server-computed scores, one row per user per score per day.
--
-- This table is what the phone reads. Scores are computed here and rendered
-- there, which is what stops readiness being calculated twice with two sets of
-- constants and two answers.
--
-- Every row carries its own provenance — model version, range set, the timezone
-- that defined the day, and a hash of the inputs — so a number can be explained
-- and reproduced without re-deriving it. A model or range change tomorrow
-- writes a NEW row rather than rewriting one the user has already read.
--
-- Not in save_normalized_wellness's table list, so a phone sync cannot touch it.

create table if not exists score_snapshots (
  user_id uuid not null,
  score_kind text not null
    check (score_kind in ('readiness', 'longi', 'training_load',
                          'biological_age', 'correlations')),
  as_of_date date not null,

  value double precision,
  drivers jsonb not null default '[]'::jsonb,
  missing_inputs text[] not null default '{}',
  data_quality text not null check (data_quality in ('full', 'partial', 'none')),

  model_version text not null,
  ranges_version text,
  timezone text not null default 'UTC',
  inputs_hash text not null,

  computed_at timestamptz not null default now(),
  created_at timestamptz not null default now(),

  primary key (user_id, score_kind, as_of_date),

  -- A missing score must be recorded as unknown, never as a zero.
  constraint quality_matches_value check (
    (value is null and data_quality = 'none')
    or (value is not null and data_quality in ('full', 'partial'))
  ),
  -- 'full' means nothing was missing. Saying full with gaps is the dishonesty
  -- this whole layer exists to prevent.
  constraint full_means_nothing_missing check (
    data_quality <> 'full' or cardinality(missing_inputs) = 0
  )
);

create index if not exists score_snapshots_user_kind_time_idx
  on score_snapshots (user_id, score_kind, as_of_date desc);

alter table score_snapshots enable row level security;

create policy "users read their own scores"
  on score_snapshots for select using (auth.uid() = user_id);

alter publication supabase_realtime add table score_snapshots;
