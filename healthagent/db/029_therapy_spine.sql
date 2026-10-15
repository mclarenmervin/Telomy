-- F12 therapy spine: catalogue, plans, immutable safety decisions and sessions.
--
-- Authenticated clients receive scoped SELECT access only. All mutations pass
-- through gateway application services (and later narrow SECURITY DEFINER
-- commands) so a client cannot turn a refusal into eligibility.


-- ── A structured fact for safety-critical pregnancy decisions ─────────────

alter table profiles
  add column if not exists pregnancy_status text not null default 'unknown';

alter table profiles drop constraint if exists profile_pregnancy_status_known;
alter table profiles add constraint profile_pregnancy_status_known
  check (pregnancy_status in (
    'unknown', 'not_pregnant', 'pregnant', 'postpartum', 'not_applicable'
  ));

comment on column profiles.pregnancy_status is
  'Structured safety fact. Therapy gates must never infer current pregnancy '
  'from free-text conditions.';

grant update (pregnancy_status) on profiles to authenticated;


-- ── Versioned global catalogue and centre-local commercial offering ───────

create table if not exists therapy_catalogue (
  id uuid primary key default gen_random_uuid(),
  slug text not null,
  version integer not null check (version > 0),
  display_name text not null check (length(trim(display_name)) > 0),
  category text not null check (length(trim(category)) > 0),
  summary text not null check (length(trim(summary)) > 0),
  intended_experience text not null check (length(trim(intended_experience)) > 0),
  event_type text not null check (length(trim(event_type)) > 0),
  dose_schema jsonb not null check (jsonb_typeof(dose_schema) = 'object'),
  contraindication_rule_ids text[] not null default '{}',
  evidence_metadata jsonb not null default '{}'::jsonb
    check (jsonb_typeof(evidence_metadata) = 'object'),
  content_sha256 text not null check (content_sha256 ~ '^[0-9a-f]{64}$'),
  publication_status text not null default 'draft'
    check (publication_status in ('draft', 'published', 'retired')),
  published_at timestamptz,
  created_by uuid references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  constraint therapy_catalogue_publication_whole check (
    (publication_status = 'published' and published_at is not null)
    or publication_status <> 'published'
  ),
  unique (slug, version)
);

create unique index if not exists therapy_catalogue_one_published_slug_idx
  on therapy_catalogue (slug) where publication_status = 'published';

create table if not exists centre_therapy_offerings (
  id uuid primary key default gen_random_uuid(),
  centre_id uuid not null references centres(id) on delete restrict,
  catalogue_id uuid not null references therapy_catalogue(id) on delete restrict,
  service_id uuid references centre_services(id) on delete restrict,
  status text not null default 'active'
    check (status in ('active', 'inactive')),
  indicative_price_minor bigint not null check (indicative_price_minor >= 0),
  currency_code text not null check (currency_code ~ '^[A-Z]{3}$'),
  default_duration_minutes integer
    check (default_duration_minutes is null
           or default_duration_minutes between 1 and 1440),
  operational_notes text,
  created_by uuid not null references auth.users(id) on delete restrict,
  updated_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (centre_id, catalogue_id)
);

create index if not exists centre_therapy_offerings_scope_idx
  on centre_therapy_offerings (centre_id, status, catalogue_id);


-- ── Plans and signable versions ───────────────────────────────────────────

create table if not exists therapy_plans (
  id uuid primary key default gen_random_uuid(),
  patient_id uuid not null references auth.users(id) on delete restrict,
  centre_id uuid not null references centres(id) on delete restrict,
  version integer not null check (version > 0),
  supersedes_id uuid references therapy_plans(id) on delete restrict,
  proposed_by uuid not null references auth.users(id) on delete restrict,
  status text not null default 'draft'
    check (status in (
      'draft', 'proposed', 'in_review', 'signed', 'rejected',
      'superseded', 'withdrawn'
    )),
  clinical_draft_id uuid references clinical_drafts(id) on delete restrict,
  content_sha256 text check (content_sha256 is null
                              or content_sha256 ~ '^[0-9a-f]{64}$'),
  signed_by uuid references auth.users(id) on delete restrict,
  signed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint therapy_plan_signature_whole check (
    (status = 'signed' and signed_by is not null and signed_at is not null
      and content_sha256 is not null and clinical_draft_id is not null)
    or (status <> 'signed' and signed_by is null and signed_at is null)
  ),
  unique (patient_id, centre_id, version)
);

create index if not exists therapy_plans_patient_idx
  on therapy_plans (patient_id, centre_id, created_at desc);
create index if not exists therapy_plans_review_queue_idx
  on therapy_plans (centre_id, created_at)
  where status in ('proposed', 'in_review');

create table if not exists therapy_plan_items (
  id uuid primary key default gen_random_uuid(),
  plan_id uuid not null references therapy_plans(id) on delete restrict,
  catalogue_id uuid not null references therapy_catalogue(id) on delete restrict,
  position integer not null check (position > 0),
  frequency jsonb not null check (jsonb_typeof(frequency) = 'object'),
  prescribed_dose jsonb not null check (jsonb_typeof(prescribed_dose) = 'object'),
  disposition text not null default 'proposed'
    check (disposition in ('proposed', 'active', 'excluded_safety', 'removed')),
  safety_reason_code text,
  safety_explanation text,
  created_at timestamptz not null default now(),
  constraint therapy_plan_item_safety_exclusion_whole check (
    (disposition = 'excluded_safety'
      and length(trim(coalesce(safety_reason_code, ''))) > 0
      and length(trim(coalesce(safety_explanation, ''))) > 0)
    or (disposition <> 'excluded_safety'
      and safety_reason_code is null and safety_explanation is null)
  ),
  unique (plan_id, position),
  unique (plan_id, catalogue_id)
);


-- ── Immutable safety evaluations ──────────────────────────────────────────

create table if not exists therapy_safety_checks (
  id uuid primary key default gen_random_uuid(),
  patient_id uuid not null references auth.users(id) on delete restrict,
  centre_id uuid not null references centres(id) on delete restrict,
  catalogue_id uuid not null references therapy_catalogue(id) on delete restrict,
  plan_item_id uuid references therapy_plan_items(id) on delete restrict,
  session_id uuid,
  evaluation_point text not null
    check (evaluation_point in ('proposal', 'signature', 'booking', 'start')),
  rule_version text not null check (length(trim(rule_version)) > 0),
  fact_snapshot jsonb not null check (jsonb_typeof(fact_snapshot) = 'object'),
  eligible boolean not null,
  reason_codes text[] not null default '{}',
  explanations jsonb not null default '[]'::jsonb
    check (jsonb_typeof(explanations) = 'array'),
  evaluated_by uuid references auth.users(id) on delete restrict,
  evaluated_at timestamptz not null default now(),
  constraint therapy_safety_refusal_has_reason check (
    eligible or cardinality(reason_codes) > 0
  )
);

create index if not exists therapy_safety_checks_patient_idx
  on therapy_safety_checks (patient_id, catalogue_id, evaluated_at desc);


-- ── Session lifecycle, separate prescribed and delivered dose ─────────────

-- `therapy_sessions` already exists as a legacy Vault journal table. Keep it
-- untouched: these rows have a stricter booking/execution lifecycle and are
-- named explicitly so a migration cannot reinterpret historical journal data.
create table if not exists therapy_service_sessions (
  id uuid primary key default gen_random_uuid(),
  patient_id uuid not null references auth.users(id) on delete restrict,
  centre_id uuid not null references centres(id) on delete restrict,
  offering_id uuid not null references centre_therapy_offerings(id) on delete restrict,
  plan_item_id uuid not null references therapy_plan_items(id) on delete restrict,
  centre_booking_id uuid references centre_bookings(id) on delete restrict,
  status text not null default 'scheduled'
    check (status in ('scheduled', 'started', 'completed', 'cancelled', 'refused')),
  prescribed_dose jsonb not null check (jsonb_typeof(prescribed_dose) = 'object'),
  delivered_dose jsonb check (delivered_dose is null
                               or jsonb_typeof(delivered_dose) = 'object'),
  scheduled_start timestamptz,
  started_at timestamptz,
  ended_at timestamptz,
  refusal_reason_codes text[] not null default '{}',
  cancellation_reason text,
  event_id uuid references events(id) on delete restrict,
  idempotency_key text not null check (length(trim(idempotency_key)) > 0),
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint therapy_session_times_ordered check (
    (started_at is null or ended_at is null or started_at < ended_at)
  ),
  constraint therapy_session_completion_whole check (
    status <> 'completed'
    or (started_at is not null and ended_at is not null
        and delivered_dose is not null)
  ),
  constraint therapy_session_refusal_has_reason check (
    status <> 'refused' or cardinality(refusal_reason_codes) > 0
  ),
  unique (patient_id, idempotency_key),
  unique (event_id)
);

alter table therapy_safety_checks
  add constraint therapy_safety_checks_session_fkey
  foreign key (session_id) references therapy_service_sessions(id) on delete restrict;

create index if not exists therapy_service_sessions_patient_idx
  on therapy_service_sessions (patient_id, started_at desc, scheduled_start desc);
create index if not exists therapy_service_sessions_centre_idx
  on therapy_service_sessions (centre_id, scheduled_start, status);

create table if not exists therapy_checkins (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null references therapy_service_sessions(id) on delete restrict,
  patient_id uuid not null references auth.users(id) on delete restrict,
  question_version text not null check (length(trim(question_version)) > 0),
  question_ordinal smallint not null check (question_ordinal between 1 and 2),
  question_code text not null check (length(trim(question_code)) > 0),
  answer jsonb not null,
  answered_at timestamptz not null default now(),
  unique (session_id, question_ordinal)
);


-- ── History guards ────────────────────────────────────────────────────────

create or replace function protect_therapy_history()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare parent_status text;
begin
  if tg_op = 'DELETE' then
    raise exception '% history is append-only', tg_table_name using errcode = '55000';
  end if;

  if tg_table_name in ('therapy_safety_checks', 'therapy_checkins') then
    raise exception '% history is immutable', tg_table_name using errcode = '55000';
  end if;

  if tg_table_name = 'therapy_plan_items' then
    select status into parent_status
    from therapy_plans
    where id = case when tg_op = 'INSERT' then new.plan_id else old.plan_id end;
    if parent_status in ('signed', 'rejected', 'superseded', 'withdrawn') then
      raise exception 'decided therapy plan items are immutable' using errcode = '55000';
    end if;
    return new;
  end if;

  if tg_table_name = 'therapy_plans' then
    if old.status in ('signed', 'rejected', 'superseded', 'withdrawn') then
      raise exception 'a decided therapy plan is immutable' using errcode = '55000';
    end if;
    if new.id is distinct from old.id
       or new.patient_id is distinct from old.patient_id
       or new.centre_id is distinct from old.centre_id
       or new.version is distinct from old.version
       or new.supersedes_id is distinct from old.supersedes_id
       or new.proposed_by is distinct from old.proposed_by
       or new.created_at is distinct from old.created_at then
      raise exception 'therapy plan identity is immutable' using errcode = '55000';
    end if;
    return new;
  end if;

  if tg_table_name = 'therapy_service_sessions' then
    if old.status in ('completed', 'cancelled', 'refused') then
      raise exception 'a terminal therapy session is immutable' using errcode = '55000';
    end if;
    if new.id is distinct from old.id
       or new.patient_id is distinct from old.patient_id
       or new.centre_id is distinct from old.centre_id
       or new.offering_id is distinct from old.offering_id
       or new.plan_item_id is distinct from old.plan_item_id
       or new.prescribed_dose is distinct from old.prescribed_dose
       or new.idempotency_key is distinct from old.idempotency_key
       or new.created_by is distinct from old.created_by
       or new.created_at is distinct from old.created_at then
      raise exception 'therapy session identity and prescription are immutable'
        using errcode = '55000';
    end if;
    return new;
  end if;

  return new;
end;
$$;

create trigger therapy_plans_history_guard
  before update or delete on therapy_plans
  for each row execute function protect_therapy_history();
create trigger therapy_plan_items_history_guard
  before insert or update or delete on therapy_plan_items
  for each row execute function protect_therapy_history();
create trigger therapy_safety_checks_history_guard
  before update or delete on therapy_safety_checks
  for each row execute function protect_therapy_history();
create trigger therapy_service_sessions_history_guard
  before update or delete on therapy_service_sessions
  for each row execute function protect_therapy_history();
create trigger therapy_checkins_history_guard
  before update or delete on therapy_checkins
  for each row execute function protect_therapy_history();


-- ── Read policies. Mutation stays server-side and separately authorized ───

alter table therapy_catalogue enable row level security;
alter table centre_therapy_offerings enable row level security;
alter table therapy_plans enable row level security;
alter table therapy_plan_items enable row level security;
alter table therapy_safety_checks enable row level security;
alter table therapy_service_sessions enable row level security;
alter table therapy_checkins enable row level security;

create policy "Authenticated read published therapy catalogue"
  on therapy_catalogue for select
  using (publication_status = 'published' or app_role_of(auth.uid()) = 'admin');

create policy "Centre participants read therapy offerings"
  on centre_therapy_offerings for select
  using (
    app_role_of(auth.uid()) = 'admin'
    or exists (
      select 1 from centre_memberships cm
      where cm.centre_id = centre_therapy_offerings.centre_id
        and cm.user_id = auth.uid() and cm.status = 'active'
        and cm.left_at is null
    )
  );

create policy "Patients read their therapy plans"
  on therapy_plans for select
  using (patient_id = auth.uid());

create policy "Patients read their therapy plan items"
  on therapy_plan_items for select
  using (exists (
    select 1 from therapy_plans plan
    where plan.id = therapy_plan_items.plan_id
      and plan.patient_id = auth.uid()
  ));

create policy "Patients read their therapy safety checks"
  on therapy_safety_checks for select
  using (patient_id = auth.uid());

create policy "Patients read their therapy sessions"
  on therapy_service_sessions for select
  using (patient_id = auth.uid());

create policy "Patients read their therapy checkins"
  on therapy_checkins for select
  using (exists (
    select 1 from therapy_service_sessions session
    where session.id = therapy_checkins.session_id
      and session.patient_id = therapy_checkins.patient_id
      and session.patient_id = auth.uid()
  ));

grant select on therapy_catalogue, centre_therapy_offerings, therapy_plans,
  therapy_plan_items, therapy_safety_checks, therapy_service_sessions,
  therapy_checkins
  to authenticated;

revoke insert, update, delete on therapy_catalogue, centre_therapy_offerings,
  therapy_plans, therapy_plan_items, therapy_safety_checks,
  therapy_service_sessions, therapy_checkins from authenticated, anon;
