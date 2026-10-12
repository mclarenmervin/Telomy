-- Commercial centre tenancy.
--
-- A centre owns an operational roster. A clinic remains the entity whose
-- verified clinicians may sign clinical content. Keeping these facts in
-- separate tables prevents a Centre Owner from acquiring clinical authority.

create table if not exists centres (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(trim(name)) > 0),
  status text not null default 'active'
    check (status in ('active', 'suspended', 'closed')),
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists centres_status_idx on centres (status, created_at);

create table if not exists centre_memberships (
  id uuid primary key default gen_random_uuid(),
  centre_id uuid not null references centres(id) on delete restrict,
  user_id uuid not null references auth.users(id) on delete restrict,
  member_kind text not null check (member_kind in ('owner', 'doctor', 'patient')),
  status text not null default 'invited'
    check (status in (
      'invited', 'pending_verification', 'active', 'suspended', 'left'
    )),
  invited_by uuid not null references auth.users(id) on delete restrict,
  accepted_at timestamptz,
  suspended_at timestamptz,
  left_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint centre_membership_state_time check (
    (status <> 'active' or accepted_at is not null)
    and (status <> 'suspended' or suspended_at is not null)
    and (status <> 'left' or left_at is not null)
  )
);

-- A prior membership is history, not the current membership rewritten. A
-- person can rejoin after a row is ended, but cannot have two current rows of
-- the same kind in one centre.
create unique index if not exists centre_memberships_current_idx
  on centre_memberships (centre_id, user_id, member_kind)
  where left_at is null;
create index if not exists centre_memberships_user_idx
  on centre_memberships (user_id, status, centre_id);
create index if not exists centre_memberships_centre_idx
  on centre_memberships (centre_id, member_kind, status);

create table if not exists centre_clinics (
  id uuid primary key default gen_random_uuid(),
  centre_id uuid not null references centres(id) on delete restrict,
  clinic_id uuid not null references clinics(id) on delete restrict,
  status text not null default 'linked' check (status in ('linked', 'unlinked')),
  linked_by uuid not null references auth.users(id) on delete restrict,
  linked_at timestamptz not null default now(),
  unlinked_at timestamptz,
  constraint centre_clinic_unlinked_time check (
    status <> 'unlinked' or unlinked_at is not null
  )
);

create unique index if not exists centre_clinics_current_idx
  on centre_clinics (centre_id, clinic_id)
  where unlinked_at is null;


-- ── Current-state authorization facts ──────────────────────────────────────

create or replace function active_centre_membership(
  p_user uuid,
  p_centre uuid,
  p_kind text
)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select
    p_kind in ('owner', 'doctor', 'patient')
    and exists (
      select 1
      from centre_memberships cm
      join centres c on c.id = cm.centre_id
      where cm.user_id = p_user
        and cm.centre_id = p_centre
        and cm.member_kind = p_kind
        and cm.status = 'active'
        and cm.left_at is null
        and c.status = 'active'
    );
$$;

comment on function active_centre_membership(uuid, uuid, text) is
  'Current operational membership in an active centre. Evaluated from rows, '
  'never from JWT claims.';

create or replace function centre_owner_may_manage(
  p_actor uuid,
  p_centre uuid
)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select app_role_of(p_actor) = 'centre'
    and active_centre_membership(p_actor, p_centre, 'owner');
$$;

comment on function centre_owner_may_manage(uuid, uuid) is
  'True only for a current Centre Owner membership in this active centre.';


-- ── Centre creation ────────────────────────────────────────────────────────

alter table admin_actions drop constraint if exists admin_actions_action_check;
alter table admin_actions add constraint admin_actions_action_check check (
  action in (
    'role_granted', 'role_revoked',
    'clinician_registered', 'clinician_suspended', 'clinician_reinstated',
    'signoff_recorded', 'signoff_withdrawn',
    'draft_withdrawn', 'draft_requeued',
    'erasure_requested', 'erasure_completed', 'consent_viewed',
    'centre_created', 'centre_status_changed',
    'centre_membership_changed', 'centre_clinic_changed'
  )
);

create or replace function create_centre(p_name text, p_actor uuid)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  new_centre uuid;
begin
  if app_role_of(p_actor) <> 'admin' then
    raise exception 'only a platform admin creates a centre' using errcode = '42501';
  end if;

  if length(trim(coalesce(p_name, ''))) = 0 then
    raise exception 'centre name is required' using errcode = '22023';
  end if;

  insert into centres (name, created_by)
  values (trim(p_name), p_actor)
  returning id into new_centre;

  insert into admin_actions
    (actor_id, action, subject_kind, subject_id, detail)
  values
    (p_actor, 'centre_created', 'centre', new_centre::text,
     jsonb_build_object('name', trim(p_name)));

  return new_centre;
end;
$$;

revoke all on function create_centre(text, uuid) from public;
revoke all on function create_centre(text, uuid) from authenticated, anon;


-- ── History protection ─────────────────────────────────────────────────────

create or replace function protect_centre_history()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'DELETE' then
    raise exception '% history is append-only', tg_table_name using errcode = '55000';
  end if;

  if tg_table_name = 'centres' then
    if new.id is distinct from old.id
       or new.created_by is distinct from old.created_by
       or new.created_at is distinct from old.created_at then
      raise exception 'centre identity is immutable' using errcode = '55000';
    end if;
    new.updated_at := now();
    return new;
  end if;

  if tg_table_name = 'centre_memberships' then
    if new.id is distinct from old.id
       or new.centre_id is distinct from old.centre_id
       or new.user_id is distinct from old.user_id
       or new.member_kind is distinct from old.member_kind
       or new.invited_by is distinct from old.invited_by
       or new.created_at is distinct from old.created_at then
      raise exception 'centre membership identity is immutable' using errcode = '55000';
    end if;
    if old.left_at is not null then
      raise exception 'an ended centre membership is immutable' using errcode = '55000';
    end if;
    new.updated_at := now();
    return new;
  end if;

  if new.id is distinct from old.id
     or new.centre_id is distinct from old.centre_id
     or new.clinic_id is distinct from old.clinic_id
     or new.linked_by is distinct from old.linked_by
     or new.linked_at is distinct from old.linked_at then
    raise exception 'centre-clinic link identity is immutable' using errcode = '55000';
  end if;
  if old.unlinked_at is not null then
    raise exception 'an ended centre-clinic link is immutable' using errcode = '55000';
  end if;
  return new;
end;
$$;

drop trigger if exists centre_history_guard on centres;
create trigger centre_history_guard
  before update or delete on centres
  for each row execute function protect_centre_history();

drop trigger if exists centre_membership_history_guard on centre_memberships;
create trigger centre_membership_history_guard
  before update or delete on centre_memberships
  for each row execute function protect_centre_history();

drop trigger if exists centre_clinic_history_guard on centre_clinics;
create trigger centre_clinic_history_guard
  before update or delete on centre_clinics
  for each row execute function protect_centre_history();


-- ── RLS and grants ─────────────────────────────────────────────────────────

alter table centres enable row level security;
alter table centre_memberships enable row level security;
alter table centre_clinics enable row level security;

create policy "admins and members read their centres"
  on centres for select using (
    app_role_of(auth.uid()) = 'admin'
    or active_centre_membership(auth.uid(), id, 'owner')
    or active_centre_membership(auth.uid(), id, 'doctor')
    or active_centre_membership(auth.uid(), id, 'patient')
  );

create policy "admins owners and self read centre memberships"
  on centre_memberships for select using (
    app_role_of(auth.uid()) = 'admin'
    or user_id = auth.uid()
    or centre_owner_may_manage(auth.uid(), centre_id)
  );

create policy "admins and members read centre clinic links"
  on centre_clinics for select using (
    app_role_of(auth.uid()) = 'admin'
    or active_centre_membership(auth.uid(), centre_id, 'owner')
    or active_centre_membership(auth.uid(), centre_id, 'doctor')
    or active_centre_membership(auth.uid(), centre_id, 'patient')
  );

grant select on centres, centre_memberships, centre_clinics to authenticated;
revoke insert, update, delete on centres from authenticated, anon;
revoke insert, update, delete on centre_memberships from authenticated, anon;
revoke insert, update, delete on centre_clinics from authenticated, anon;
