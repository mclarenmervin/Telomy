-- The role spine: what a person is on the *platform*, enforced in Postgres.
--
-- The prototype this programme is parity with keeps the role in
-- `AsyncStorage` and every endpoint trusts it. That is fine for a simulator
-- with one profile and it is a cross-tenant leak in a product with real
-- accounts, which makes this file the one place the difference lives.
--
-- Four roles, and the names are a decision rather than a detail because F10
-- and F11 inherit them across policies that will by then be load-bearing:
--
--   member  — the person whose body it is
--   doctor  — a registered clinician in the Bonphul network
--   centre  — a wellness centre owner or operator
--   admin   — us
--
-- `doctor` rather than `clinician` is deliberate. `clinic_members.role`
-- already has a value spelled `clinician` and it means something else
-- entirely (see below), and two axes that share a word are two axes somebody
-- eventually conflates. No value appears in both lists except `admin`, which
-- is unambiguous because it is scoped by the table it sits in.
--
-- ── The two axes, and why this one is new ───────────────────────────────────
--
-- `clinic_members.role` is membership INSIDE ONE CLINIC: patient, clinician,
-- admin. `clinician_may_sign()` reads it at signing time by design, and 005's
-- range-override policy reads it to find patients. It is not the platform
-- role and must never be made to mean both.
--
-- One human may be a member of Telomy, a clinician at two clinics and the
-- operator of a centre. Those are three facts in three places. The moment
-- they are one column, a booking path starts consulting a signing function.
--
-- Nothing in 013 is rewritten here. The clinical surface keeps reading
-- `clinicians` and `clinic_members`, so `app_role = 'doctor'` admits no
-- clinical row by itself — asserted in db/tests/app_role_test.sql, from both
-- directions.
--
-- ── The column is the fact; a JWT claim is a cache ──────────────────────────
--
-- Decision 2 in the programme doc. Every policy below reads the column. If a
-- claim is ever added to the token it grants nothing on its own, which is the
-- property the test mints a forged token to prove: claims saying `admin`
-- against a column saying `member` reads zero admin rows.
--
-- ── Nobody grants themselves a role ─────────────────────────────────────────
--
-- Enforced twice, for the reason 013 gives: the policy absence stops the
-- client, the trigger stops us.
--
--   * COLUMN PRIVILEGES. `profiles` already carries a policy admitting the
--     user's own row for UPDATE, and RLS decides which ROWS a policy admits
--     and cannot restrict which COLUMNS an update touches — exactly as 008
--     found for lab_escalations.acknowledged_at and 013 for insights.body.
--     Without the revoke below, `app_role` would be writable by its owner the
--     moment it existed, and the whole phase would be decoration.
--
--   * A TRIGGER. Column privileges bind `authenticated`. They do not bind the
--     service role, and our own code holds it. A support endpoint that
--     elevated the user it was acting for would be a privilege escalation
--     with a feature request in front of it, so self-elevation is refused
--     wherever it is attempted and by whoever attempts it.
--
-- A role is therefore granted by exactly one path: `grant_app_role()` below,
-- which files an admin action in the same statement.


-- ── The column ──────────────────────────────────────────────────────────────

alter table profiles
  -- Defaulting to the safe role matters more than it looks: `handle_new_user`
  -- names its columns explicitly, so every account that already exists and
  -- every account created from here takes this default without that trigger
  -- being touched.
  add column if not exists app_role text not null default 'member';

alter table profiles drop constraint if exists profile_app_role_known;
alter table profiles add constraint profile_app_role_known
  check (app_role in ('member', 'doctor', 'centre', 'admin'));

comment on column profiles.app_role is
  'What this person is on the platform: member, doctor, centre or admin. '
  'NOT clinic_members.role, which is membership inside one clinic and is read '
  'by clinician_may_sign(). Written only by grant_app_role().';

-- Every admin policy below resolves "is the caller an admin" on each row read.
create index if not exists profiles_app_role_idx
  on profiles (app_role)
  where app_role <> 'member';


-- Surgical, not a blanket revoke: a member must still be able to edit their
-- own name. `created_at` and `id` are deliberately absent from the update
-- list — neither is a thing a profile owner has any business rewriting.
revoke update on profiles from authenticated, anon;
grant update (full_name, email, phone, updated_at) on profiles to authenticated;

-- There is no INSERT policy on profiles, so RLS already refuses a client
-- insert. The grant is narrowed anyway, so that adding one later cannot
-- accidentally admit a self-made admin row.
revoke insert on profiles from authenticated, anon;
grant insert (id, full_name, email, phone, created_at, updated_at)
  on profiles to authenticated;


-- ── Resolving the role ──────────────────────────────────────────────────────
--
-- One function, called by every policy that needs the answer, in the same
-- spirit as `clinician_clinic_ids` and the single context loader. A role rule
-- copied into nine policies is a role rule that will disagree with itself.
--
-- SECURITY DEFINER is load-bearing and not convenient, and for the exact
-- reason 013 records as a scar: a policy ON profiles that reads profiles
-- re-enters its own policy and Postgres raises "infinite recursion detected".
-- Running the lookup as the owner is what breaks the cycle. It is also why
-- this cannot be inlined as a subquery in the admin policy on profiles.
create or replace function app_role_of(p_user uuid)
returns text
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(
    (select app_role from profiles where id = p_user),
    -- An account with no profile row is not an error here; it is somebody
    -- mid-signup, and the safe reading of "no row" is the least privileged
    -- role rather than a null that every caller then has to remember to
    -- handle.
    'member'
  );
$$;

comment on function app_role_of(uuid) is
  'The platform role, read from profiles.app_role. The column is the fact; a '
  'JWT claim is a cache and grants nothing on its own.';


-- ── The audit table ─────────────────────────────────────────────────────────
--
-- Append-only, and visible to admins including the admin who acted. An admin
-- who can silently read a Vault or quietly rewrite what they did is a DPDP
-- problem wearing a support ticket.
--
-- Same discipline as `clinical_reviews`: the policy absence stops a client,
-- the trigger stops the service role, and the clinician FK is RESTRICT so a
-- professional act cannot be erased by the person who performed it.

create table if not exists admin_actions (
  id uuid primary key default gen_random_uuid(),

  -- RESTRICT, deliberately, and the second place in this schema where
  -- deleting a user is allowed to fail. "Who did this" is the question the
  -- table exists to answer, and an answer that disappears with the account
  -- does not answer it. An admin leaving is a role change, not a deletion.
  actor_id uuid not null references auth.users(id) on delete restrict,

  action text not null
    check (action in (
      -- Roles and people
      'role_granted', 'role_revoked',
      'clinician_registered', 'clinician_suspended', 'clinician_reinstated',
      -- Reviewed content. The five unsigned catalog files are the admin
      -- surface's first real job, so these exist from the first migration.
      'signoff_recorded', 'signoff_withdrawn',
      -- The queue
      'draft_withdrawn', 'draft_requeued',
      -- DPDP
      'erasure_requested', 'erasure_completed',
      'consent_viewed'
    )),

  -- What it was about. Deliberately loose — a text id rather than a foreign
  -- key — because the subject is a profile, a catalog entry id, a draft or a
  -- registration number, and a trail that only records the subjects we have
  -- tables for today is a trail with holes in it next phase.
  subject_kind text,
  subject_id text,

  -- Why, and what changed. The thing a dispute actually needs.
  detail jsonb not null default '{}'::jsonb,

  created_at timestamptz not null default now(),

  constraint admin_action_subject_is_whole check (
    (subject_kind is null and subject_id is null)
    or (subject_kind is not null and subject_id is not null)
  )
);

create index if not exists admin_actions_time_idx
  on admin_actions (created_at desc);
create index if not exists admin_actions_actor_idx
  on admin_actions (actor_id, created_at desc);
create index if not exists admin_actions_subject_idx
  on admin_actions (subject_kind, subject_id, created_at desc);


create or replace function refuse_admin_action_mutation()
returns trigger
language plpgsql
as $$
begin
  raise exception
    'admin_actions is append-only; a recorded action cannot be %',
    lower(tg_op)
    using errcode = '23514';
end $$;

drop trigger if exists admin_action_append_only on admin_actions;
create trigger admin_action_append_only
  before update or delete on admin_actions
  for each row execute function refuse_admin_action_mutation();


-- ── Granting a role ─────────────────────────────────────────────────────────
--
-- The only path that writes the column. A function rather than an endpoint
-- because the action and its record have to be one statement: a role granted
-- without a trail and a trail without the grant are both worse than either.

create or replace function enforce_app_role_change()
returns trigger
language plpgsql
as $$
begin
  if new.app_role is not distinct from old.app_role then
    return new;
  end if;

  -- Self-elevation, refused whatever privileges the actor holds. `auth.uid()`
  -- reads the request's claims rather than the database role, so this binds
  -- our own service code when it is acting for a signed-in user — which is
  -- the shape the escalation would actually take.
  if auth.uid() is not null and auth.uid() = new.id then
    raise exception
      'nobody grants themselves a platform role'
      using errcode = '42501';
  end if;

  -- Any other change has to come through `grant_app_role`, which sets this
  -- local and files the admin action. A bare UPDATE from a console would
  -- leave the column changed and the trail empty.
  if coalesce(current_setting('telomy.granting_role', true), '') <> 'yes' then
    raise exception
      'app_role is written by grant_app_role() only, so that the grant and '
      'its record are one statement'
      using errcode = '42501';
  end if;

  new.updated_at := now();
  return new;
end $$;

drop trigger if exists profile_app_role_guard on profiles;
create trigger profile_app_role_guard
  before update on profiles
  for each row execute function enforce_app_role_change();


create or replace function grant_app_role(
  p_user uuid,
  p_role text,
  p_actor uuid,
  p_reason text default null
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  previous text;
begin
  -- The actor must be an admin *now*, read from the column, in the same
  -- spirit as `clinician_may_sign` being evaluated at signing time rather
  -- than at claim time. SECURITY DEFINER means this check is the only thing
  -- standing here, so it is checked before anything is read or written.
  if app_role_of(p_actor) <> 'admin' then
    raise exception 'only a platform admin grants a platform role'
      using errcode = '42501';
  end if;

  if p_actor = p_user then
    raise exception 'nobody grants themselves a platform role'
      using errcode = '42501';
  end if;

  select app_role into previous from profiles where id = p_user;
  if previous is null then
    raise exception 'no such account: %', p_user using errcode = '23503';
  end if;
  if previous = p_role then
    -- Not an error, and deliberately not a no-op either: re-granting a role
    -- somebody already has would otherwise file an action saying something
    -- changed when nothing did.
    return;
  end if;

  perform set_config('telomy.granting_role', 'yes', true);
  update profiles set app_role = p_role where id = p_user;
  perform set_config('telomy.granting_role', '', true);

  insert into admin_actions (actor_id, action, subject_kind, subject_id, detail)
  values (
    p_actor,
    case when p_role = 'member' then 'role_revoked' else 'role_granted' end,
    'profile',
    p_user::text,
    jsonb_build_object('from', previous, 'to', p_role)
      || case when p_reason is null then '{}'::jsonb
              else jsonb_build_object('reason', p_reason) end
  );
end $$;

comment on function grant_app_role(uuid, text, uuid, text) is
  'The only path that writes profiles.app_role. Files an admin action in the '
  'same statement. Refuses self-elevation and a non-admin actor.';

-- Callable by the service role only. The gateway resolves the caller from a
-- verified token and passes it as p_actor; a client that could call this
-- directly could pass somebody else as the actor.
revoke all on function grant_app_role(uuid, text, uuid, text) from public;
revoke all on function grant_app_role(uuid, text, uuid, text) from authenticated, anon;


-- ── RLS ─────────────────────────────────────────────────────────────────────

alter table admin_actions enable row level security;

-- Visible to admins, including the admin who performed it. There is no
-- "except mine" clause and there must never be one.
create policy "admins read the admin trail"
  on admin_actions for select using (app_role_of(auth.uid()) = 'admin');

-- An admin records their own actions and nobody else's. Identity is all this
-- decides; the append-only trigger is what binds the service role.
create policy "admins record their own actions"
  on admin_actions for insert with check (
    app_role_of(auth.uid()) = 'admin' and actor_id = auth.uid()
  );

-- No update or delete policy, and the trigger behind it.
revoke update, delete on admin_actions from authenticated, anon;


-- An admin reads every account. This is the role's operational half: a
-- clinician cannot be onboarded, an erasure request cannot be honoured and a
-- stranded queue cannot be traced to a person without it.
create policy "admins read every account"
  on profiles for select using (app_role_of(auth.uid()) = 'admin');

-- And every licence, so that a lapse is noticed before a refused signature is.
create policy "admins read every registration"
  on clinicians for select using (app_role_of(auth.uid()) = 'admin');

create policy "admins read every clinic"
  on clinics for select using (app_role_of(auth.uid()) = 'admin');

-- WHAT IS DELIBERATELY ABSENT, and the reason this file is longer in comments
-- than in SQL.
--
-- There is no admin policy on health_measurements, biomarker_results,
-- insights, chat_turns, genetic_variants, genetic_uploads,
-- environment_snapshots, score_snapshots or clinical_drafts. An admin
-- authenticated as themselves reads zero rows of every one of them, which the
-- test asserts table by table.
--
-- The programme's risk table calls the failure "the admin role becomes a God
-- account" and the answer is not a filter in a query somebody has to
-- remember. Queue health reaches the admin surface as counts computed by the
-- gateway under the service role — `stranded_total` is a number, not a list
-- of sentences about people — and anything finer than a count waits for the
-- per-purpose consent row that F19 builds. There is nowhere in this schema
-- for such a consent to be recorded yet, so the honest state of F9 is that
-- the escape hatch does not exist rather than that it is unguarded.
