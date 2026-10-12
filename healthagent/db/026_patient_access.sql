-- Patient-to-Doctor assignment, patient clinical consent and cross-user access
-- audit. These are three separate facts; no platform role implies another.

create table if not exists patient_doctor_assignments (
  id uuid primary key default gen_random_uuid(),
  centre_id uuid not null references centres(id) on delete restrict,
  patient_id uuid not null references auth.users(id) on delete restrict,
  doctor_id uuid not null references auth.users(id) on delete restrict,
  is_primary boolean not null default false,
  assigned_by uuid not null references auth.users(id) on delete restrict,
  assigned_at timestamptz not null default now(),
  ended_by uuid references auth.users(id) on delete restrict,
  ended_at timestamptz,
  end_reason text,
  constraint assignment_people_differ check (patient_id <> doctor_id),
  constraint assignment_end_is_whole check (
    (ended_at is null and ended_by is null and end_reason is null)
    or (ended_at is not null and ended_by is not null
        and length(trim(coalesce(end_reason, ''))) > 0)
  )
);

create unique index if not exists patient_doctor_active_pair_idx
  on patient_doctor_assignments (centre_id, patient_id, doctor_id)
  where ended_at is null;
create unique index if not exists patient_doctor_active_primary_idx
  on patient_doctor_assignments (centre_id, patient_id)
  where is_primary and ended_at is null;
create index if not exists patient_doctor_doctor_idx
  on patient_doctor_assignments (doctor_id, centre_id, assigned_at desc)
  where ended_at is null;

create table if not exists clinical_access_consents (
  id uuid primary key default gen_random_uuid(),
  patient_id uuid not null references auth.users(id) on delete restrict,
  centre_id uuid not null references centres(id) on delete restrict,
  purpose text not null check (purpose in ('clinical_care')),
  granted_by uuid not null references auth.users(id) on delete restrict,
  granted_at timestamptz not null default now(),
  provenance jsonb not null default '{}'::jsonb,
  revoked_by uuid references auth.users(id) on delete restrict,
  revoked_at timestamptz,
  revoke_reason text,
  constraint consent_revoke_is_whole check (
    (revoked_at is null and revoked_by is null and revoke_reason is null)
    or (revoked_at is not null and revoked_by is not null
        and length(trim(coalesce(revoke_reason, ''))) > 0)
  )
);

create unique index if not exists clinical_access_active_consent_idx
  on clinical_access_consents (patient_id, centre_id, purpose)
  where revoked_at is null;

create table if not exists access_audit (
  id uuid primary key default gen_random_uuid(),
  actor_id uuid not null references auth.users(id) on delete restrict,
  actor_role text not null check (actor_role in ('admin', 'centre', 'doctor', 'member')),
  action text not null check (length(trim(action)) > 0),
  patient_id uuid not null references auth.users(id) on delete restrict,
  centre_id uuid references centres(id) on delete restrict,
  resource_kind text not null check (length(trim(resource_kind)) > 0),
  resource_id text,
  reason text not null check (length(trim(reason)) > 0),
  request_id text not null check (length(trim(request_id)) > 0),
  outcome text not null check (outcome in ('allowed', 'denied', 'error')),
  created_at timestamptz not null default now()
);

create index if not exists access_audit_actor_idx
  on access_audit (actor_id, created_at desc);
create index if not exists access_audit_patient_idx
  on access_audit (patient_id, created_at desc);
create unique index if not exists access_audit_request_action_idx
  on access_audit (request_id, action, patient_id, actor_id);


-- ── History protection ─────────────────────────────────────────────────────

create or replace function protect_patient_access_history()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'DELETE' then
    raise exception '% history is append-only', tg_table_name using errcode = '55000';
  end if;

  if tg_table_name = 'patient_doctor_assignments' then
    if new.id is distinct from old.id
       or new.centre_id is distinct from old.centre_id
       or new.patient_id is distinct from old.patient_id
       or new.doctor_id is distinct from old.doctor_id
       or new.is_primary is distinct from old.is_primary
       or new.assigned_by is distinct from old.assigned_by
       or new.assigned_at is distinct from old.assigned_at then
      raise exception 'assignment identity is immutable' using errcode = '55000';
    end if;
    if old.ended_at is not null then
      raise exception 'an ended assignment is immutable' using errcode = '55000';
    end if;
    return new;
  end if;

  if new.id is distinct from old.id
     or new.patient_id is distinct from old.patient_id
     or new.centre_id is distinct from old.centre_id
     or new.purpose is distinct from old.purpose
     or new.granted_by is distinct from old.granted_by
     or new.granted_at is distinct from old.granted_at
     or new.provenance is distinct from old.provenance then
    raise exception 'consent grant is immutable' using errcode = '55000';
  end if;
  if old.revoked_at is not null then
    raise exception 'a revoked consent is immutable' using errcode = '55000';
  end if;
  return new;
end;
$$;

drop trigger if exists patient_doctor_history_guard on patient_doctor_assignments;
create trigger patient_doctor_history_guard
  before update or delete on patient_doctor_assignments
  for each row execute function protect_patient_access_history();

drop trigger if exists clinical_access_consent_history_guard
  on clinical_access_consents;
create trigger clinical_access_consent_history_guard
  before update or delete on clinical_access_consents
  for each row execute function protect_patient_access_history();

create or replace function access_audit_append_only()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  raise exception 'access audit is append-only' using errcode = '55000';
end;
$$;

drop trigger if exists access_audit_history_guard on access_audit;
create trigger access_audit_history_guard
  before update or delete on access_audit
  for each row execute function access_audit_append_only();


-- ── Current-state authorization predicates ─────────────────────────────────

create or replace function doctor_can_read_patient(
  p_actor uuid,
  p_centre uuid,
  p_patient uuid
)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select app_role_of(p_actor) = 'doctor'
    and doctor_is_verified(p_actor)
    and active_centre_membership(p_actor, p_centre, 'doctor')
    and active_centre_membership(p_patient, p_centre, 'patient')
    and exists (
      select 1 from patient_doctor_assignments pda
      where pda.centre_id = p_centre
        and pda.patient_id = p_patient
        and pda.doctor_id = p_actor
        and pda.ended_at is null
    );
$$;

create or replace function doctor_can_author_clinical(
  p_actor uuid,
  p_centre uuid,
  p_patient uuid
)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select doctor_can_read_patient(p_actor, p_centre, p_patient);
$$;

create or replace function centre_can_read_clinical(
  p_actor uuid,
  p_centre uuid,
  p_patient uuid
)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select centre_owner_may_manage(p_actor, p_centre)
    and active_centre_membership(p_patient, p_centre, 'patient')
    and exists (
      select 1 from clinical_access_consents cac
      where cac.patient_id = p_patient
        and cac.centre_id = p_centre
        and cac.purpose = 'clinical_care'
        and cac.revoked_at is null
    );
$$;

create or replace function admin_can_read_patient(
  p_actor uuid,
  p_patient uuid
)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select app_role_of(p_actor) = 'admin'
    and exists (select 1 from profiles where id = p_patient);
$$;


-- ── Assignment procedures ──────────────────────────────────────────────────

create or replace function assignment_actor_may_manage(
  p_actor uuid,
  p_centre uuid
)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select app_role_of(p_actor) = 'admin'
    or centre_owner_may_manage(p_actor, p_centre);
$$;

create or replace function assign_patient_doctor(
  p_actor uuid,
  p_centre uuid,
  p_patient uuid,
  p_doctor uuid,
  p_primary boolean default false
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  assignment_id uuid;
begin
  if not assignment_actor_may_manage(p_actor, p_centre) then
    raise exception 'actor cannot assign Doctors in this centre'
      using errcode = '42501';
  end if;
  if not active_centre_membership(p_patient, p_centre, 'patient') then
    raise exception 'Patient is not active in this centre' using errcode = '42501';
  end if;
  if not active_centre_membership(p_doctor, p_centre, 'doctor')
     or not doctor_is_verified(p_doctor) then
    raise exception 'Doctor is not eligible in this centre' using errcode = '42501';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(
    p_centre::text || ':' || p_patient::text, 0
  ));

  select id into assignment_id
  from patient_doctor_assignments
  where centre_id = p_centre and patient_id = p_patient
    and doctor_id = p_doctor and ended_at is null;

  if assignment_id is not null and not p_primary then
    return assignment_id;
  end if;

  if p_primary then
    update patient_doctor_assignments
    set ended_by = p_actor, ended_at = now(),
        end_reason = case when doctor_id = p_doctor
          then 'promoted_to_primary' else 'primary_reassigned' end
    where centre_id = p_centre and patient_id = p_patient
      and ended_at is null and (is_primary or doctor_id = p_doctor);
  end if;

  insert into patient_doctor_assignments (
    centre_id, patient_id, doctor_id, is_primary, assigned_by
  ) values (p_centre, p_patient, p_doctor, p_primary, p_actor)
  returning id into assignment_id;

  return assignment_id;
end;
$$;

create or replace function set_primary_doctor(
  p_actor uuid,
  p_centre uuid,
  p_patient uuid,
  p_doctor uuid
)
returns uuid
language sql
security definer
set search_path = public, pg_temp
as $$
  select assign_patient_doctor(
    p_actor, p_centre, p_patient, p_doctor, true
  );
$$;


-- ── Patient consent procedure ───────────────────────────────────────────────

create or replace function set_clinical_access_consent(
  p_actor uuid,
  p_centre uuid,
  p_patient uuid,
  p_granted boolean,
  p_purpose text default 'clinical_care'
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  consent_id uuid;
begin
  if p_actor <> p_patient or app_role_of(p_actor) <> 'member' then
    raise exception 'only the Patient controls this consent' using errcode = '42501';
  end if;
  if p_purpose <> 'clinical_care'
     or not active_centre_membership(p_patient, p_centre, 'patient') then
    raise exception 'invalid consent scope' using errcode = '22023';
  end if;

  select id into consent_id
  from clinical_access_consents
  where patient_id = p_patient and centre_id = p_centre
    and purpose = p_purpose and revoked_at is null
  for update;

  if p_granted then
    if consent_id is not null then return consent_id; end if;
    insert into clinical_access_consents (
      patient_id, centre_id, purpose, granted_by,
      provenance
    ) values (
      p_patient, p_centre, p_purpose, p_actor,
      jsonb_build_object('source', 'patient_action')
    ) returning id into consent_id;
    return consent_id;
  end if;

  if consent_id is null then
    raise exception 'no active consent to revoke' using errcode = '55000';
  end if;
  update clinical_access_consents
  set revoked_by = p_actor, revoked_at = now(), revoke_reason = 'patient_revoked'
  where id = consent_id;
  return consent_id;
end;
$$;


-- ── Fail-closed audited read event ─────────────────────────────────────────

create or replace function record_access_event(
  p_actor uuid,
  p_action text,
  p_patient uuid,
  p_centre uuid,
  p_resource_kind text,
  p_resource_id text,
  p_reason text,
  p_request_id text,
  p_outcome text default 'allowed'
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  role_name text := app_role_of(p_actor);
  event_id uuid;
  permitted boolean;
begin
  if p_outcome not in ('allowed', 'denied', 'error') then
    raise exception 'unknown access outcome' using errcode = '22023';
  end if;
  if length(trim(coalesce(p_reason, ''))) = 0
     or length(trim(coalesce(p_request_id, ''))) = 0
     or length(trim(coalesce(p_action, ''))) = 0
     or length(trim(coalesce(p_resource_kind, ''))) = 0 then
    raise exception 'access audit context is incomplete' using errcode = '22023';
  end if;

  permitted := case role_name
    when 'admin' then admin_can_read_patient(p_actor, p_patient)
    when 'centre' then centre_can_read_clinical(p_actor, p_centre, p_patient)
    when 'doctor' then doctor_can_read_patient(p_actor, p_centre, p_patient)
    when 'member' then p_actor = p_patient
    else false
  end;
  if p_outcome = 'allowed' and not permitted then
    raise exception 'allowed audit event has no matching authorization'
      using errcode = '42501';
  end if;

  insert into access_audit (
    actor_id, actor_role, action, patient_id, centre_id,
    resource_kind, resource_id, reason, request_id, outcome
  ) values (
    p_actor, role_name, trim(p_action), p_patient, p_centre,
    trim(p_resource_kind), p_resource_id, trim(p_reason),
    trim(p_request_id), p_outcome
  ) returning id into event_id;
  return event_id;
end;
$$;

revoke all on function assign_patient_doctor(uuid, uuid, uuid, uuid, boolean)
  from public, authenticated, anon;
revoke all on function set_primary_doctor(uuid, uuid, uuid, uuid)
  from public, authenticated, anon;
revoke all on function set_clinical_access_consent(uuid, uuid, uuid, boolean, text)
  from public, authenticated, anon;
revoke all on function record_access_event(
  uuid, text, uuid, uuid, text, text, text, text, text
) from public, authenticated, anon;


-- ── RLS: mobile sees self-safe rows, cross-user reads use the gateway ───────

alter table patient_doctor_assignments enable row level security;
alter table clinical_access_consents enable row level security;
alter table access_audit enable row level security;

create policy "Patients read their own Doctor assignments"
  on patient_doctor_assignments for select using (patient_id = auth.uid());

create policy "Patients read their own clinical access consents"
  on clinical_access_consents for select using (patient_id = auth.uid());

create policy "Super Admin reads access audit"
  on access_audit for select using (app_role_of(auth.uid()) = 'admin');

grant select on patient_doctor_assignments, clinical_access_consents, access_audit
  to authenticated;
revoke insert, update, delete on patient_doctor_assignments from authenticated, anon;
revoke insert, update, delete on clinical_access_consents from authenticated, anon;
revoke insert, update, delete on access_audit from authenticated, anon;
