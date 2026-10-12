-- Append-only clinician notes and immutable, versioned monthly reports.

create table if not exists clinician_notes (
  id uuid primary key default gen_random_uuid(),
  patient_id uuid not null references auth.users(id) on delete restrict,
  centre_id uuid not null references centres(id) on delete restrict,
  author_doctor_id uuid not null references auth.users(id) on delete restrict,
  body text not null check (length(trim(body)) > 0),
  supersedes_id uuid references clinician_notes(id) on delete restrict,
  created_at timestamptz not null default now(),
  withdrawn_at timestamptz,
  withdrawn_by uuid references auth.users(id) on delete restrict,
  withdrawal_reason text,
  constraint note_withdrawal_is_whole check (
    (withdrawn_at is null and withdrawn_by is null and withdrawal_reason is null)
    or (withdrawn_at is not null and withdrawn_by is not null
        and length(trim(coalesce(withdrawal_reason, ''))) > 0)
  )
);
create index if not exists clinician_notes_patient_idx
  on clinician_notes (patient_id, centre_id, created_at desc);

create table if not exists monthly_reports (
  id uuid primary key default gen_random_uuid(),
  patient_id uuid not null references auth.users(id) on delete restrict,
  centre_id uuid not null references centres(id) on delete restrict,
  period_start date not null,
  period_end date not null,
  source_cutoff timestamptz not null,
  evidence jsonb not null,
  body text not null check (length(trim(body)) > 0),
  version integer not null check (version > 0),
  status text not null default 'draft'
    check (status in ('draft', 'in_review', 'signed', 'rejected', 'superseded')),
  supersedes_id uuid references monthly_reports(id) on delete restrict,
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  reviewer_note text,
  signed_by uuid references auth.users(id) on delete restrict,
  reviewed_at timestamptz,
  signed_body_sha256 text,
  constraint report_period_ordered check (period_start <= period_end),
  constraint report_signature_is_whole check (
    (status = 'signed' and signed_by is not null and reviewed_at is not null
      and length(trim(coalesce(reviewer_note, ''))) > 0
      and signed_body_sha256 ~ '^[0-9a-f]{64}$')
    or (status <> 'signed' and signed_by is null and signed_body_sha256 is null)
  ),
  unique (patient_id, centre_id, period_start, period_end, version)
);
create index if not exists monthly_reports_patient_idx
  on monthly_reports (patient_id, centre_id, period_end desc, version desc);

create or replace function protect_doctor_workspace_history()
returns trigger language plpgsql set search_path = public, pg_temp as $$
begin
  if tg_op = 'DELETE' then
    raise exception '% history is append-only', tg_table_name using errcode = '55000';
  end if;
  if tg_table_name = 'clinician_notes' then
    if new.id is distinct from old.id or new.patient_id is distinct from old.patient_id
       or new.centre_id is distinct from old.centre_id
       or new.author_doctor_id is distinct from old.author_doctor_id
       or new.body is distinct from old.body
       or new.supersedes_id is distinct from old.supersedes_id
       or new.created_at is distinct from old.created_at then
      raise exception 'clinician note content is immutable' using errcode = '55000';
    end if;
    if old.withdrawn_at is not null then
      raise exception 'a withdrawn note is immutable' using errcode = '55000';
    end if;
    return new;
  end if;
  if old.status in ('signed', 'rejected') then
    raise exception 'a decided monthly report is immutable' using errcode = '55000';
  end if;
  if new.id is distinct from old.id or new.patient_id is distinct from old.patient_id
     or new.centre_id is distinct from old.centre_id
     or new.period_start is distinct from old.period_start
     or new.period_end is distinct from old.period_end
     or new.source_cutoff is distinct from old.source_cutoff
     or new.evidence is distinct from old.evidence
     or new.body is distinct from old.body
     or new.version is distinct from old.version
     or new.supersedes_id is distinct from old.supersedes_id
     or new.created_by is distinct from old.created_by
     or new.created_at is distinct from old.created_at then
    raise exception 'monthly report evidence and body are immutable' using errcode = '55000';
  end if;
  return new;
end $$;

create trigger clinician_notes_history_guard before update or delete on clinician_notes
  for each row execute function protect_doctor_workspace_history();
create trigger monthly_reports_history_guard before update or delete on monthly_reports
  for each row execute function protect_doctor_workspace_history();

create or replace function centre_clinician_may_sign(p_doctor uuid, p_centre uuid)
returns boolean language sql stable security definer
set search_path = public, pg_temp as $$
  select clinician_may_sign(p_doctor)
    and exists (
      select 1 from centre_clinics cc
      join clinic_members cm on cm.clinic_id = cc.clinic_id
      where cc.centre_id = p_centre and cc.status = 'linked'
        and cc.unlinked_at is null and cm.user_id = p_doctor
        and cm.role in ('clinician', 'admin') and cm.left_at is null
    );
$$;

create or replace function append_clinician_note(
  p_actor uuid, p_centre uuid, p_patient uuid, p_body text,
  p_supersedes uuid default null
) returns uuid language plpgsql security definer
set search_path = public, pg_temp as $$
declare note_id uuid;
begin
  if not doctor_can_author_clinical(p_actor, p_centre, p_patient) then
    raise exception 'Doctor is not assigned to this Patient' using errcode = '42501';
  end if;
  if length(trim(coalesce(p_body, ''))) = 0 then
    raise exception 'note body is required' using errcode = '22023';
  end if;
  if p_supersedes is not null and not exists (
    select 1 from clinician_notes where id = p_supersedes
      and patient_id = p_patient and centre_id = p_centre
  ) then
    raise exception 'superseded note is outside this Patient context'
      using errcode = '42501';
  end if;
  insert into clinician_notes
    (patient_id, centre_id, author_doctor_id, body, supersedes_id)
  values (p_patient, p_centre, p_actor, trim(p_body), p_supersedes)
  returning id into note_id;
  return note_id;
end $$;

create or replace function withdraw_clinician_note(
  p_actor uuid, p_note uuid, p_reason text
) returns void language plpgsql security definer
set search_path = public, pg_temp as $$
declare target clinician_notes%rowtype;
begin
  select * into target from clinician_notes where id = p_note for update;
  if not found or target.author_doctor_id <> p_actor
     or not doctor_can_author_clinical(p_actor, target.centre_id, target.patient_id) then
    raise exception 'Doctor cannot withdraw this note' using errcode = '42501';
  end if;
  if length(trim(coalesce(p_reason, ''))) = 0 then
    raise exception 'withdrawal reason is required' using errcode = '22023';
  end if;
  update clinician_notes set withdrawn_at = now(), withdrawn_by = p_actor,
    withdrawal_reason = trim(p_reason) where id = p_note;
end $$;

create or replace function create_monthly_report_version(
  p_actor uuid, p_centre uuid, p_patient uuid,
  p_period_start date, p_period_end date, p_source_cutoff timestamptz,
  p_evidence jsonb, p_body text
) returns uuid language plpgsql security definer
set search_path = public, pg_temp as $$
declare prior_id uuid; next_version integer; report_id uuid;
begin
  if not doctor_can_author_clinical(p_actor, p_centre, p_patient) then
    raise exception 'Doctor is not assigned to this Patient' using errcode = '42501';
  end if;
  if p_period_start > p_period_end or p_source_cutoff is null
     or jsonb_typeof(p_evidence) <> 'array'
     or length(trim(coalesce(p_body, ''))) = 0 then
    raise exception 'monthly report inputs are incomplete' using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(
    p_centre::text || ':' || p_patient::text || ':' || p_period_start::text, 0));
  select id, version into prior_id, next_version from monthly_reports
   where centre_id = p_centre and patient_id = p_patient
     and period_start = p_period_start and period_end = p_period_end
   order by version desc limit 1;
  next_version := coalesce(next_version, 0) + 1;
  insert into monthly_reports
    (patient_id, centre_id, period_start, period_end, source_cutoff,
     evidence, body, version, supersedes_id, created_by)
  values (p_patient, p_centre, p_period_start, p_period_end, p_source_cutoff,
          p_evidence, trim(p_body), next_version, prior_id, p_actor)
  returning id into report_id;
  return report_id;
end $$;

create or replace function sign_monthly_report(
  p_actor uuid, p_report uuid, p_note text
) returns text language plpgsql security definer
set search_path = public, pg_temp as $$
declare target monthly_reports%rowtype; delivery text; body_hash text;
begin
  select * into target from monthly_reports where id = p_report for update;
  if not found or target.status not in ('draft', 'in_review') then
    raise exception 'monthly report is not signable' using errcode = '55000';
  end if;
  if length(trim(coalesce(p_note, ''))) = 0 then
    raise exception 'clinician note is required' using errcode = '22023';
  end if;
  if not doctor_can_author_clinical(p_actor, target.centre_id, target.patient_id)
     or not centre_clinician_may_sign(p_actor, target.centre_id) then
    raise exception 'Doctor cannot sign this report' using errcode = '42501';
  end if;
  delivery := target.body || E'\n\nClinician note: ' || trim(p_note);
  body_hash := encode(sha256(convert_to(delivery, 'UTF8')), 'hex');
  update monthly_reports set status = 'signed', reviewer_note = trim(p_note),
    signed_by = p_actor, reviewed_at = now(), signed_body_sha256 = body_hash
  where id = p_report;
  return body_hash;
end $$;

revoke all on function append_clinician_note(uuid, uuid, uuid, text, uuid)
  from public, authenticated, anon;
revoke all on function withdraw_clinician_note(uuid, uuid, text)
  from public, authenticated, anon;
revoke all on function create_monthly_report_version(
  uuid, uuid, uuid, date, date, timestamptz, jsonb, text
) from public, authenticated, anon;
revoke all on function sign_monthly_report(uuid, uuid, text)
  from public, authenticated, anon;

alter table clinician_notes enable row level security;
alter table monthly_reports enable row level security;
create policy "Patients read their clinician notes" on clinician_notes
  for select using (patient_id = auth.uid());
create policy "Patients read signed monthly reports" on monthly_reports
  for select using (patient_id = auth.uid() and status = 'signed');
grant select on clinician_notes, monthly_reports to authenticated;
revoke insert, update, delete on clinician_notes from authenticated, anon;
revoke insert, update, delete on monthly_reports from authenticated, anon;
