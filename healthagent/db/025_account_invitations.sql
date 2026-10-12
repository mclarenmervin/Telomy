-- Safe account invitations and append-only clinician verification.
--
-- Supabase Auth owns passwords and provider links. This schema persists only
-- the intent, delivery bookkeeping and membership outcome needed to make an
-- invitation idempotent and auditable.

create table if not exists clinician_verifications (
  id uuid primary key default gen_random_uuid(),
  doctor_id uuid not null references auth.users(id) on delete restrict,
  registration_number text,
  registration_body text,
  licence_expires_at timestamptz,
  specialties text[] not null default '{}',
  status text not null
    check (status in ('pending', 'verified', 'rejected', 'expired', 'superseded')),
  decision_reason text not null check (length(trim(decision_reason)) > 0),
  evidence jsonb not null default '{}'::jsonb,
  submitted_at timestamptz not null default now(),
  reviewed_by uuid references auth.users(id) on delete restrict,
  reviewed_at timestamptz,
  supersedes_id uuid references clinician_verifications(id) on delete restrict,
  created_at timestamptz not null default clock_timestamp(),

  constraint verified_registration_complete check (
    status <> 'verified'
    or (
      length(trim(coalesce(registration_number, ''))) > 0
      and length(trim(coalesce(registration_body, ''))) > 0
      and licence_expires_at is not null
      and licence_expires_at > reviewed_at
      and reviewed_by is not null
      and reviewed_at is not null
    )
  ),
  constraint reviewed_decision_has_reviewer check (
    status = 'pending' or (reviewed_by is not null and reviewed_at is not null)
  )
);

create index if not exists clinician_verifications_doctor_idx
  on clinician_verifications (doctor_id, created_at desc);

create or replace function doctor_is_verified(p_doctor uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce((
    select cv.status = 'verified'
       and cv.licence_expires_at > now()
       and exists (
         select 1 from clinicians c
         where c.user_id = p_doctor
           and c.status = 'active'
           and c.licence_expires_at > now()
       )
    from clinician_verifications cv
    where cv.doctor_id = p_doctor
    order by cv.created_at desc, cv.id desc
    limit 1
  ), false);
$$;

comment on function doctor_is_verified(uuid) is
  'The latest append-only verification decision and current clinician '
  'projection both permit this Doctor to practise. Clinic membership and '
  'patient assignment are separate checks.';

create table if not exists account_invitations (
  id uuid primary key default gen_random_uuid(),
  email text not null check (
    email = lower(trim(email)) and position('@' in email) > 1
  ),
  intended_role text not null
    check (intended_role in ('admin', 'centre', 'doctor', 'member')),
  centre_id uuid references centres(id) on delete restrict,
  invited_by uuid not null references auth.users(id) on delete restrict,
  invited_user_id uuid references auth.users(id) on delete restrict,
  primary_doctor_id uuid references auth.users(id) on delete restrict,
  status text not null default 'pending'
    check (status in ('pending', 'accepted', 'revoked', 'expired')),
  idempotency_key text not null check (length(trim(idempotency_key)) > 0),
  provider_user_id text,
  delivery_attempts integer not null default 0 check (delivery_attempts >= 0),
  last_delivery_error text,
  expires_at timestamptz not null default now() + interval '24 hours',
  sent_at timestamptz,
  accepted_at timestamptz,
  revoked_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint invitation_scope_matches_role check (
    (intended_role = 'admin' and centre_id is null)
    or (intended_role <> 'admin' and centre_id is not null)
  ),
  constraint invitation_primary_doctor_for_patient check (
    primary_doctor_id is null or intended_role = 'member'
  ),
  constraint invitation_status_times check (
    (status <> 'accepted' or accepted_at is not null)
    and (status <> 'revoked' or revoked_at is not null)
  ),
  unique (invited_by, idempotency_key)
);

create unique index if not exists account_invitations_pending_intent_idx
  on account_invitations (
    email, intended_role,
    coalesce(centre_id, '00000000-0000-0000-0000-000000000000'::uuid)
  )
  where status = 'pending';
create index if not exists account_invitations_recipient_idx
  on account_invitations (invited_user_id, status, created_at desc);
create index if not exists account_invitations_expiry_idx
  on account_invitations (expires_at)
  where status = 'pending';


-- ── Immutable decision history and controlled invitation state ─────────────

create or replace function protect_clinician_verification_history()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  raise exception 'clinician verification history is append-only'
    using errcode = '55000';
end;
$$;

drop trigger if exists clinician_verification_append_only
  on clinician_verifications;
create trigger clinician_verification_append_only
  before update or delete on clinician_verifications
  for each row execute function protect_clinician_verification_history();

create or replace function protect_invitation_identity()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'account invitation history is retained' using errcode = '55000';
  end if;
  if new.id is distinct from old.id
     or new.email is distinct from old.email
     or new.intended_role is distinct from old.intended_role
     or new.centre_id is distinct from old.centre_id
     or new.invited_by is distinct from old.invited_by
     or new.primary_doctor_id is distinct from old.primary_doctor_id
     or new.created_at is distinct from old.created_at then
    raise exception 'account invitation identity is immutable' using errcode = '55000';
  end if;
  if old.status <> 'pending' then
    raise exception 'a completed invitation is immutable' using errcode = '55000';
  end if;
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists account_invitation_history_guard on account_invitations;
create trigger account_invitation_history_guard
  before update or delete on account_invitations
  for each row execute function protect_invitation_identity();


-- ── Invitation authority and lifecycle ─────────────────────────────────────

create or replace function can_invite_role(
  p_actor uuid,
  p_centre uuid,
  p_intended_role text
)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select case app_role_of(p_actor)
    when 'admin' then p_intended_role in ('admin', 'centre', 'doctor', 'member')
    when 'centre' then p_intended_role in ('doctor', 'member')
      and centre_owner_may_manage(p_actor, p_centre)
    when 'doctor' then p_intended_role = 'member'
      and active_centre_membership(p_actor, p_centre, 'doctor')
      and doctor_is_verified(p_actor)
    else false
  end;
$$;

create or replace function create_account_invitation(
  p_email text,
  p_intended_role text,
  p_centre uuid,
  p_actor uuid,
  p_primary_doctor uuid,
  p_idempotency_key text
)
returns uuid
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  normalized_email text := lower(trim(coalesce(p_email, '')));
  existing_id uuid;
  linked_user uuid;
begin
  if position('@' in normalized_email) <= 1 then
    raise exception 'valid invitation email is required' using errcode = '22023';
  end if;
  if p_intended_role not in ('admin', 'centre', 'doctor', 'member') then
    raise exception 'unknown intended role' using errcode = '22023';
  end if;
  if (p_intended_role = 'admin' and p_centre is not null)
     or (p_intended_role <> 'admin' and p_centre is null) then
    raise exception 'invitation centre does not match intended role'
      using errcode = '22023';
  end if;
  if not can_invite_role(p_actor, p_centre, p_intended_role) then
    raise exception 'actor cannot create this invitation' using errcode = '42501';
  end if;
  if length(trim(coalesce(p_idempotency_key, ''))) = 0 then
    raise exception 'idempotency key is required' using errcode = '22023';
  end if;
  if p_primary_doctor is not null and (
    p_intended_role <> 'member'
    or not active_centre_membership(p_primary_doctor, p_centre, 'doctor')
    or not doctor_is_verified(p_primary_doctor)
  ) then
    raise exception 'primary Doctor is not eligible in this centre'
      using errcode = '42501';
  end if;

  select id into existing_id
  from account_invitations
  where invited_by = p_actor and idempotency_key = trim(p_idempotency_key);
  if existing_id is not null then return existing_id; end if;

  update account_invitations
  set status = 'expired'
  where email = normalized_email
    and intended_role = p_intended_role
    and centre_id is not distinct from p_centre
    and status = 'pending'
    and expires_at <= now();

  select id into existing_id
  from account_invitations
  where email = normalized_email
    and intended_role = p_intended_role
    and centre_id is not distinct from p_centre
    and status = 'pending'
    and expires_at > now()
  order by created_at desc
  limit 1;
  if existing_id is not null then return existing_id; end if;

  select id into linked_user
  from auth.users
  where lower(email) = normalized_email
  order by created_at
  limit 1;

  insert into account_invitations (
    email, intended_role, centre_id, invited_by, invited_user_id,
    primary_doctor_id, idempotency_key
  ) values (
    normalized_email, p_intended_role, p_centre, p_actor, linked_user,
    p_primary_doctor, trim(p_idempotency_key)
  ) returning id into existing_id;

  return existing_id;
end;
$$;

create or replace function accept_account_invitation(
  p_invitation uuid,
  p_user uuid
)
returns uuid
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  invitation account_invitations%rowtype;
  user_email text;
  existing_role text;
  membership_kind text;
  membership_status text;
begin
  select * into invitation
  from account_invitations
  where id = p_invitation
  for update;

  if not found or invitation.status <> 'pending' then
    raise exception 'invitation is not available' using errcode = '55000';
  end if;
  if invitation.expires_at <= now() then
    raise exception 'invitation has expired' using errcode = '55000';
  end if;
  if invitation.invited_user_id is not null
     and invitation.invited_user_id <> p_user then
    raise exception 'invitation belongs to another account' using errcode = '42501';
  end if;

  select lower(email) into user_email from auth.users where id = p_user;
  if user_email is null or user_email <> invitation.email then
    raise exception 'invitation email does not match account' using errcode = '42501';
  end if;

  existing_role := app_role_of(p_user);
  if existing_role <> invitation.intended_role
     and existing_role <> 'member'
     and invitation.intended_role <> 'member' then
    raise exception 'account already has a conflicting platform role'
      using errcode = '55000';
  end if;

  if existing_role = 'member' and invitation.intended_role <> 'member' then
    perform set_config('telomy.granting_role', 'yes', true);
    update profiles set app_role = invitation.intended_role where id = p_user;
    perform set_config('telomy.granting_role', '', true);
  end if;

  if invitation.intended_role <> 'admin' then
    membership_kind := case invitation.intended_role
      when 'centre' then 'owner'
      when 'doctor' then 'doctor'
      else 'patient'
    end;
    membership_status := case
      when invitation.intended_role = 'doctor' and not doctor_is_verified(p_user)
        then 'pending_verification'
      else 'active'
    end;

    insert into centre_memberships (
      centre_id, user_id, member_kind, status, invited_by, accepted_at
    ) values (
      invitation.centre_id, p_user, membership_kind, membership_status,
      invitation.invited_by,
      case when membership_status = 'active' then now() else null end
    )
    on conflict (centre_id, user_id, member_kind) where left_at is null
    do update set
      status = excluded.status,
      accepted_at = excluded.accepted_at,
      suspended_at = null;
  end if;

  update account_invitations
  set status = 'accepted', invited_user_id = p_user, accepted_at = now()
  where id = p_invitation;

  return invitation.centre_id;
end;
$$;


-- ── Super Admin verification decision ──────────────────────────────────────

alter table admin_actions drop constraint if exists admin_actions_action_check;
alter table admin_actions add constraint admin_actions_action_check check (
  action in (
    'role_granted', 'role_revoked',
    'clinician_registered', 'clinician_suspended', 'clinician_reinstated',
    'signoff_recorded', 'signoff_withdrawn',
    'draft_withdrawn', 'draft_requeued',
    'erasure_requested', 'erasure_completed', 'consent_viewed',
    'centre_created', 'centre_status_changed',
    'centre_membership_changed', 'centre_clinic_changed',
    'clinician_verification_decided'
  )
);

create or replace function record_clinician_verification(
  p_actor uuid,
  p_doctor uuid,
  p_status text,
  p_reason text,
  p_registration_number text default null,
  p_registration_body text default null,
  p_licence_expires_at timestamptz default null,
  p_specialties text[] default '{}'
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  previous_id uuid;
  decision_id uuid;
begin
  if app_role_of(p_actor) <> 'admin' then
    raise exception 'only a platform admin verifies a Doctor' using errcode = '42501';
  end if;
  if app_role_of(p_doctor) <> 'doctor' then
    raise exception 'verification subject is not a Doctor' using errcode = '22023';
  end if;
  if p_status not in ('verified', 'rejected', 'expired') then
    raise exception 'unknown verification decision' using errcode = '22023';
  end if;
  if length(trim(coalesce(p_reason, ''))) = 0 then
    raise exception 'verification reason is required' using errcode = '22023';
  end if;
  if p_status = 'verified' and (
    length(trim(coalesce(p_registration_number, ''))) = 0
    or length(trim(coalesce(p_registration_body, ''))) = 0
    or p_licence_expires_at is null
    or p_licence_expires_at <= now()
  ) then
    raise exception 'verified registration details are incomplete'
      using errcode = '22023';
  end if;

  select id into previous_id
  from clinician_verifications
  where doctor_id = p_doctor
  order by created_at desc, id desc
  limit 1;

  insert into clinician_verifications (
    doctor_id, registration_number, registration_body,
    licence_expires_at, specialties, status, decision_reason,
    reviewed_by, reviewed_at, supersedes_id
  ) values (
    p_doctor, p_registration_number, p_registration_body,
    p_licence_expires_at, coalesce(p_specialties, '{}'), p_status, trim(p_reason),
    p_actor, now(), previous_id
  ) returning id into decision_id;

  if p_status = 'verified' then
    insert into clinicians (
      user_id, full_name, registration_number, registration_body,
      licence_expires_at, status, specialties
    ) values (
      p_doctor,
      coalesce(nullif(trim((select full_name from profiles where id = p_doctor)), ''),
               'Doctor'),
      trim(p_registration_number), trim(p_registration_body),
      p_licence_expires_at, 'active', coalesce(p_specialties, '{}')
    )
    on conflict (user_id) do update set
      full_name = excluded.full_name,
      registration_number = excluded.registration_number,
      registration_body = excluded.registration_body,
      licence_expires_at = excluded.licence_expires_at,
      status = 'active',
      specialties = excluded.specialties,
      updated_at = now();

    update centre_memberships
    set status = 'active', accepted_at = coalesce(accepted_at, now()),
        suspended_at = null
    where user_id = p_doctor and member_kind = 'doctor'
      and status = 'pending_verification' and left_at is null;
  else
    update clinicians set status = 'suspended', updated_at = now()
    where user_id = p_doctor;
    update centre_memberships
    set status = 'suspended', suspended_at = now()
    where user_id = p_doctor and member_kind = 'doctor'
      and status in ('active', 'pending_verification') and left_at is null;
  end if;

  insert into admin_actions
    (actor_id, action, subject_kind, subject_id, detail)
  values (
    p_actor, 'clinician_verification_decided', 'doctor', p_doctor::text,
    jsonb_build_object('status', p_status, 'decision_id', decision_id)
  );

  return decision_id;
end;
$$;

revoke all on function create_account_invitation(text, text, uuid, uuid, uuid, text)
  from public, authenticated, anon;
revoke all on function accept_account_invitation(uuid, uuid)
  from public, authenticated, anon;
revoke all on function record_clinician_verification(
  uuid, uuid, text, text, text, text, timestamptz, text[]
) from public, authenticated, anon;


-- ── Safe read policies ─────────────────────────────────────────────────────

alter table account_invitations enable row level security;
alter table clinician_verifications enable row level security;

create policy "invitation participants read safe invitation metadata"
  on account_invitations for select using (
    app_role_of(auth.uid()) = 'admin'
    or invited_by = auth.uid()
    or invited_user_id = auth.uid()
    or email = lower(coalesce(auth.jwt() ->> 'email', ''))
  );

create policy "admins and Doctors read verification history"
  on clinician_verifications for select using (
    app_role_of(auth.uid()) = 'admin' or doctor_id = auth.uid()
  );

grant select on account_invitations, clinician_verifications to authenticated;
revoke insert, update, delete on account_invitations from authenticated, anon;
revoke insert, update, delete on clinician_verifications from authenticated, anon;
