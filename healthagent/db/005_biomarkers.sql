-- Biomarker results, and the clinician range overrides that grade them.
--
-- The catalog itself (markers, canonical units, global standard/optimal/critical
-- ranges) lives in app/analytics/data/biomarkers.v1.yaml, not here. Medical
-- content belongs in git where a change gets a diff, blame and a pull request.
-- Postgres holds only what is per-user or per-clinic.
--
-- None of these tables appear in save_normalized_wellness's table list, so a
-- phone sync cannot touch them (see 202610060001_sync_ownership.sql).

-- ── Clinics and clinicians ───────────────────────────────────────────────────

create table if not exists clinics (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  created_at timestamptz not null default now()
);

create table if not exists clinic_members (
  clinic_id uuid not null references clinics(id) on delete cascade,
  user_id uuid not null,
  joined_at timestamptz not null default now(),
  primary key (clinic_id, user_id)
);

create index if not exists clinic_members_user_idx on clinic_members (user_id);

-- ── Reference range overrides ────────────────────────────────────────────────
--
-- Append-only. A clinician changing a range inserts a new row with a new
-- version; nothing is ever updated in place. That is what makes a number
-- already shown to a user reproducible: the artefact stamped the version it
-- used, and that version still says what it said.
--
-- Critical bounds are deliberately absent. They come from the catalog and are
-- not overridable: a clinic may take a view on what counts as normal, not on
-- when we tell someone to seek care.

create table if not exists reference_range_overrides (
  id uuid primary key default gen_random_uuid(),
  scope text not null check (scope in ('user', 'clinic')),
  user_id uuid,
  clinic_id uuid references clinics(id) on delete cascade,
  biomarker_id text not null,
  sex text check (sex in ('male', 'female')),
  standard_low double precision not null,
  standard_high double precision not null,
  optimal_low double precision not null,
  optimal_high double precision not null,
  version text not null,
  citation text not null,
  created_by uuid not null,
  effective_from timestamptz not null default now(),
  created_at timestamptz not null default now(),

  -- A range we cannot cite is a range we cannot defend to a clinician.
  constraint override_citation_present check (length(trim(citation)) > 0),
  constraint override_ranges_ordered check (
    standard_low <= optimal_low
    and optimal_low <= optimal_high
    and optimal_high <= standard_high
  ),
  constraint override_scope_target check (
    (scope = 'user' and user_id is not null)
    or (scope = 'clinic' and clinic_id is not null)
  )
);

create index if not exists range_overrides_user_idx
  on reference_range_overrides (user_id) where scope = 'user';
create index if not exists range_overrides_clinic_idx
  on reference_range_overrides (clinic_id) where scope = 'clinic';

-- ── Uploaded documents ───────────────────────────────────────────────────────

create table if not exists lab_uploads (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  storage_provider text not null default 'supabase',
  storage_path text not null,
  content_sha256 text not null,
  status text not null default 'uploaded'
    check (status in ('uploaded', 'extracting', 'extracted', 'needs_password', 'failed')),
  page_count integer,
  collected_at timestamptz,
  lab_name text,
  patient_name text,
  error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  -- The same PDF twice would double every value and corrupt every trend.
  unique (user_id, content_sha256)
);

create index if not exists lab_uploads_user_time_idx
  on lab_uploads (user_id, created_at desc);

-- ── Extracted values ─────────────────────────────────────────────────────────
--
-- `value_canonical` is the only thing any score reads; raw value and unit are
-- retained for display and for the verbatim check against the page text.
--
-- `operator` carries censored results (<0.01, >500), which are routine on real
-- panels. A censored value may be displayed and may escalate, but is excluded
-- from biological age and correlations because the true value is unknown.
--
-- `result_type` separates numbers from qualitative results (Positive, Trace),
-- which must never be coerced to a number.

create table if not exists biomarker_results (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  upload_id uuid references lab_uploads(id) on delete cascade,
  biomarker_id text not null,
  result_type text not null default 'quantitative'
    check (result_type in ('quantitative', 'qualitative')),
  operator text not null default '='
    check (operator in ('=', '<', '>')),
  raw_value text,
  raw_unit text,
  value_canonical double precision,
  value_text text,
  unit_canonical text,
  collected_at timestamptz,
  lab_name text,
  confidence double precision check (confidence between 0 and 1),
  page integer,
  bbox jsonb,
  status text not null default 'extracted'
    check (status in ('extracted', 'confirmed', 'corrected', 'rejected')),
  source text not null default 'lab_extraction',
  quality text not null default 'extracted',
  created_at timestamptz not null default now(),
  confirmed_at timestamptz,

  -- A quantitative result needs a number; a qualitative one needs text.
  constraint result_has_a_value check (
    (result_type = 'quantitative' and value_canonical is not null)
    or (result_type = 'qualitative' and value_text is not null)
  )
);

create index if not exists biomarker_results_user_marker_time_idx
  on biomarker_results (user_id, biomarker_id, collected_at desc);

-- Only confirmed values feed scores. The partial index makes that the cheap path.
create index if not exists biomarker_results_confirmed_idx
  on biomarker_results (user_id, biomarker_id, collected_at desc)
  where status in ('confirmed', 'corrected');

-- ── Third-party epigenetic clocks ────────────────────────────────────────────
--
-- Displayed and tracked, never recomputed. The check constraint is the
-- enforcement: nothing can write a value here and call it ours.

create table if not exists epigenetic_results (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  clock text not null
    check (clock in ('horvath', 'hannum', 'phenoage', 'grimage', 'dunedinpace')),
  value double precision not null,
  unit text not null,
  provider text not null,
  collected_at timestamptz not null,
  source text not null default 'third_party' check (source = 'third_party'),
  created_at timestamptz not null default now()
);

create index if not exists epigenetic_results_user_idx
  on epigenetic_results (user_id, collected_at desc);

-- ── RLS ──────────────────────────────────────────────────────────────────────
-- The agent uses service-role credentials and bypasses these by design; they
-- protect the mobile app, which reads results and nothing else.

alter table lab_uploads enable row level security;
alter table biomarker_results enable row level security;
alter table epigenetic_results enable row level security;
alter table reference_range_overrides enable row level security;
alter table clinic_members enable row level security;

create policy "users read their own uploads"
  on lab_uploads for select using (auth.uid() = user_id);

create policy "users read their own results"
  on biomarker_results for select using (auth.uid() = user_id);

create policy "users confirm their own results"
  on biomarker_results for update using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

create policy "users read their own epigenetic results"
  on epigenetic_results for select using (auth.uid() = user_id);

-- A user may see the ranges applied to them: their own, and their clinics'.
create policy "users read ranges that apply to them"
  on reference_range_overrides for select using (
    (scope = 'user' and auth.uid() = user_id)
    or (scope = 'clinic' and clinic_id in (
      select clinic_id from clinic_members where user_id = auth.uid()))
  );

create policy "users read their own memberships"
  on clinic_members for select using (auth.uid() = user_id);

alter publication supabase_realtime add table biomarker_results;
