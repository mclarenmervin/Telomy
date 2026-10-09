-- The clinician spine: drafts the agent writes, reviews a clinician signs,
-- insights the user finally sees.
--
-- Four tables and four triggers. The triggers are the point — the clinician
-- console is a separate repo doing CRUD over Postgres with RLS, so anything
-- enforced only in our Python is not enforced for the one client that matters
-- most. Three properties therefore live in the database:
--
--   * a user cannot read a draft about themselves, because no policy admits it;
--   * a clinician whose licence has lapsed cannot sign, checked at signing
--     time and in a trigger, so the service role is bound by it too;
--   * a body that does not hash to the signature cannot become an insight.
--
-- Tested by db/tests/clinical_review_test.sql, which switches to the
-- `authenticated` role with a JWT claim rather than running as owner — the
-- lesson F3 and F4 both paid for, where a missing policy on a table the phone
-- had to write was invisible to every other kind of test.
--
-- None of these tables appear in save_normalized_wellness's table list, so a
-- phone sync cannot touch them (see 202610060001_sync_ownership.sql).


-- ── Who is a clinician, and may they still sign? ─────────────────────────────
--
-- 005 put clinics and clinic_members in place and gave a member no role and no
-- end date. Both gaps matter here. `clinic_members` already holds *patients* —
-- 005's range-override policy reads it for exactly that — so "a member of the
-- clinic" would have handed every patient the review queue. And a clinician
-- leaving was indistinguishable from a clinician staying.

alter table clinic_members
  add column if not exists role text not null default 'patient',
  -- Null means still here. A date rather than a boolean because "when did they
  -- leave" is the question an audit asks, and a boolean cannot answer it.
  add column if not exists left_at timestamptz;

alter table clinic_members drop constraint if exists clinic_member_role_known;
alter table clinic_members add constraint clinic_member_role_known
  check (role in ('patient', 'clinician', 'admin'));

-- The queue policies resolve "which clinics does this clinician work for" on
-- every row read, so it wants to be an index lookup rather than a scan.
create index if not exists clinic_members_clinician_idx
  on clinic_members (user_id, clinic_id)
  where role in ('clinician', 'admin') and left_at is null;


-- Licence state, which `clinic_members` has nowhere to put. Separate from the
-- membership because a clinician may work for two clinics on one registration,
-- and the registration is the thing that expires.
create table if not exists clinicians (
  user_id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null,
  registration_number text not null,
  registration_body text,
  -- Not nullable. A licence whose expiry we do not hold is a licence we cannot
  -- verify, and `clinician_may_sign` would have to either refuse everyone or
  -- wave everyone through. Refusing to store it is the honest third option.
  licence_expires_at timestamptz not null,
  status text not null default 'active'
    check (status in ('active', 'suspended', 'left')),
  specialties text[] not null default '{}',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint clinician_name_present check (length(trim(full_name)) > 0),
  constraint clinician_registration_present
    check (length(trim(registration_number)) > 0),
  -- Two people cannot hold one registration number. If this ever fires it is
  -- either a typo or something much worse, and both want looking at.
  unique (registration_number)
);


-- Which clinics does this person work for, as a clinician?
--
-- One function, called by every policy that needs the answer, in the same
-- spirit as the single range-resolution function and the single context
-- loader: a membership rule copied into four policies is a membership rule
-- that will disagree with itself.
--
-- SECURITY DEFINER is load-bearing rather than convenient. A policy ON
-- clinic_members that reads clinic_members re-enters its own policy and
-- Postgres raises "infinite recursion detected"; running the lookup as the
-- owner is what breaks the cycle.
create or replace function clinician_clinic_ids(p_clinician uuid)
returns setof uuid
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select clinic_id
    from clinic_members
   where user_id = p_clinician
     and role in ('clinician', 'admin')
     and left_at is null;
$$;


-- May this person sign, *right now*?
--
-- Called at signing time, never at claim time. A clinician whose registration
-- lapses mid-review must not be able to sign what they claimed an hour ago,
-- which is the specific failure the plan's clinical-workflow section names.
--
-- SECURITY DEFINER because it is called from triggers and policies that run as
-- whoever is signing, and the answer must not depend on whether that role can
-- read the clinicians table. search_path is pinned for the usual reason.
create or replace function clinician_may_sign(p_clinician uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
      from clinicians c
     where c.user_id = p_clinician
       and c.status = 'active'
       and c.licence_expires_at > now()
       and exists (select 1 from clinician_clinic_ids(p_clinician))
  );
$$;

comment on function clinician_may_sign(uuid) is
  'Active registration, unexpired licence, and a current clinic membership. '
  'Evaluated at signing time — a claim made while in good standing confers '
  'nothing once the licence has lapsed.';


-- ── What the agent writes, and nobody else reads ─────────────────────────────

create table if not exists clinical_drafts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,

  -- Null means the Bonphul network pool: no clinic has been assigned and any
  -- clinician in good standing may claim it. `set null` rather than cascade
  -- because a clinic closing should return its queue to the pool, not destroy
  -- work that is waiting on a human.
  clinic_id uuid references clinics(id) on delete set null,

  kind text not null
    check (kind in ('observation', 'lab_finding', 'supplement', 'therapy',
                    'lifestyle')),
  title text not null,
  body text not null,

  -- What the claim rests on: biomarker ids, values, collection dates, score
  -- snapshots. A clinician asked to put their registration number against a
  -- sentence needs to see what produced it without leaving the console.
  evidence jsonb not null default '[]'::jsonb,

  -- Why this needs a human. Set by the `clinician_queue` guardrail profile,
  -- which attaches flags instead of replacing the text — in that profile
  -- today's guardrail would blank out exactly the content a clinician is meant
  -- to sign. A draft carrying any flag can never take the unreviewed delivery
  -- path below.
  routing_flags text[] not null default '{}',

  status text not null default 'drafted'
    check (status in ('drafted', 'queued', 'in_review', 'revised', 'signed',
                      'rejected', 'expired', 'delivered', 'withdrawn')),

  claimed_by uuid references auth.users(id) on delete set null,
  claimed_at timestamptz,

  -- When the queue gives up and the SLA sweep takes over. Instrumented from
  -- day one because "the clinician queue becomes the bottleneck and the
  -- product feels dead" is a named risk, not a hypothetical.
  sla_due_at timestamptz,

  model_version text not null,
  -- What this was noticed from: a confirmed panel, a score snapshot, an event.
  source_kind text,
  source_id uuid,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  -- 006 shipped score_snapshots with no foreign key and every snapshot
  -- outlived the account it described until 012 fixed it. A draft is the most
  -- sensitive row of the three, because it is the one nobody has checked.
  constraint clinical_drafts_user_fkey
    foreign key (user_id) references auth.users(id) on delete cascade,

  constraint draft_title_present check (length(trim(title)) > 0),
  constraint draft_body_present check (length(trim(body)) > 0),
  -- A claim is a person and a time together. Half a claim cannot expire,
  -- because the sweep has no age to measure.
  constraint claim_is_whole check (
    (claimed_by is null and claimed_at is null)
    or (claimed_by is not null and claimed_at is not null)
  )
);

-- The console's queue read: what is waiting, oldest first.
create index if not exists clinical_drafts_queue_idx
  on clinical_drafts (clinic_id, created_at)
  where status in ('queued', 'revised');

-- The SLA sweep's read, and the claim-expiry sweep's.
create index if not exists clinical_drafts_claimed_idx
  on clinical_drafts (claimed_at)
  where status = 'in_review';
create index if not exists clinical_drafts_sla_idx
  on clinical_drafts (sla_due_at)
  where status in ('queued', 'in_review', 'revised');

create index if not exists clinical_drafts_user_idx
  on clinical_drafts (user_id, created_at desc);


-- ── The state machine ────────────────────────────────────────────────────────
--
--   drafted → queued → in_review → signed → delivered
--                         │  │                  │
--               revised ──┘  └→ rejected        └→ withdrawn
--
-- Plus `expired`, which the SLA sweep uses when no human arrived in time.
--
-- In the database rather than in Python because the console is a separate repo.
-- A state machine only our worker obeys is a convention, not a machine.

create or replace function clinical_draft_status_allowed(p_from text, p_to text)
returns boolean
language sql
immutable
as $$
  select case p_from
    when 'drafted'   then p_to in ('queued', 'withdrawn')
    when 'queued'    then p_to in ('in_review', 'expired', 'withdrawn')
    when 'in_review' then p_to in ('signed', 'rejected', 'revised', 'queued',
                                   'expired', 'withdrawn')
    -- Back to a human, never straight to a signature: a revision is new text
    -- and has to be read before it is signed.
    when 'revised'   then p_to in ('in_review', 'queued', 'expired', 'withdrawn')
    -- `revised` is reachable from here on purpose. Editing a signed draft is
    -- allowed; what it must not do is inherit the signature, and the delivery
    -- gate below is what makes that true.
    when 'signed'    then p_to in ('delivered', 'revised', 'withdrawn')
    when 'rejected'  then p_to in ('withdrawn')
    when 'expired'   then p_to in ('delivered', 'withdrawn')
    when 'delivered' then p_to in ('withdrawn')
    when 'withdrawn' then false
    else false
  end;
$$;


create or replace function enforce_clinical_draft_machine()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'INSERT' then
    -- Every draft starts at the beginning. A status that asserts a human acted
    -- -- signed, rejected, delivered -- must not be typeable on the way in, or
    -- the whole trail can be fabricated in one statement.
    if new.status <> 'drafted' then
      raise exception
        'a draft is created as drafted, not as %', new.status
        using errcode = '23514';
    end if;
    return new;
  end if;

  if new.status is distinct from old.status
     and not clinical_draft_status_allowed(old.status, new.status) then
    raise exception
      'a clinical draft cannot move from % to %', old.status, new.status
      using errcode = '23514';
  end if;

  new.updated_at := now();
  return new;
end $$;

drop trigger if exists clinical_draft_machine on clinical_drafts;
create trigger clinical_draft_machine
  before insert or update on clinical_drafts
  for each row execute function enforce_clinical_draft_machine();


-- ── The review trail ─────────────────────────────────────────────────────────
--
-- Append-only. "Who said this was safe, and when" is the question this whole
-- phase exists to answer, and an editable audit trail does not answer it.

create table if not exists clinical_reviews (
  id uuid primary key default gen_random_uuid(),
  draft_id uuid not null,
  clinician_id uuid not null,
  action text not null
    check (action in ('claimed', 'revised', 'signed', 'rejected', 'withdrawn')),

  -- Hex sha256 of the body as it stood when it was signed. This is the whole
  -- delivery gate: a status check would pass for a draft edited afterwards.
  signed_body_sha256 text,
  notes text,
  created_at timestamptz not null default now(),

  constraint clinical_reviews_draft_fkey
    foreign key (draft_id) references clinical_drafts(id) on delete cascade,

  -- RESTRICT, deliberately, and the one place in this schema where a user
  -- deletion is allowed to fail. A signature is a professional act and must
  -- not be erasable by the signer; the clinician's *personal* record is in
  -- `clinicians`, which does cascade. Insights stamp the reviewer's name and
  -- registration at delivery, so the user-facing trail survives either way.
  constraint clinical_reviews_clinician_fkey
    foreign key (clinician_id) references auth.users(id) on delete restrict,

  constraint signature_carries_a_hash check (
    (action = 'signed' and signed_body_sha256 is not null)
    or (action <> 'signed' and signed_body_sha256 is null)
  ),
  constraint signature_is_a_sha256 check (
    signed_body_sha256 is null or signed_body_sha256 ~ '^[0-9a-f]{64}$'
  )
);

create index if not exists clinical_reviews_draft_idx
  on clinical_reviews (draft_id, created_at);
create index if not exists clinical_reviews_clinician_idx
  on clinical_reviews (clinician_id, created_at desc);


create or replace function enforce_signature_validity()
returns trigger
language plpgsql
as $$
declare
  draft clinical_drafts;
begin
  if new.action <> 'signed' then
    return new;
  end if;

  select * into draft from clinical_drafts where id = new.draft_id;

  -- Checked here rather than only in an RLS policy because the agent and the
  -- scheduler hold the service role, and RLS does not apply to them. A licence
  -- check that only binds the console has a service-role-shaped hole in it.
  if not clinician_may_sign(new.clinician_id) then
    raise exception
      'clinician % may not sign: no active registration with an unexpired '
      'licence and a current clinic membership', new.clinician_id
      using errcode = '23514';
  end if;

  -- You sign what you claimed. Without this a clinician could sign out from
  -- under a colleague's claim, and the trail would record a review of a draft
  -- they never had open.
  if draft.claimed_by is distinct from new.clinician_id then
    raise exception
      'clinician % has not claimed draft %', new.clinician_id, new.draft_id
      using errcode = '23514';
  end if;

  if draft.status <> 'in_review' then
    raise exception
      'draft % is %, so there is nothing under review to sign',
      new.draft_id, draft.status
      using errcode = '23514';
  end if;

  -- The hash must be of what is actually there. Without this a console could
  -- sign a hash of text it invented, and the delivery gate would compare two
  -- numbers that both came from the same lie.
  if new.signed_body_sha256
     <> encode(sha256(convert_to(draft.body, 'UTF8')), 'hex') then
    raise exception
      'the signature is not over the current body of draft %', new.draft_id
      using errcode = '23514';
  end if;

  return new;
end $$;

drop trigger if exists clinical_review_signature on clinical_reviews;
create trigger clinical_review_signature
  before insert on clinical_reviews
  for each row execute function enforce_signature_validity();


create or replace function refuse_review_mutation()
returns trigger
language plpgsql
as $$
begin
  raise exception
    'clinical_reviews is append-only; a recorded review cannot be % ',
    lower(tg_op)
    using errcode = '23514';
end $$;

drop trigger if exists clinical_review_append_only on clinical_reviews;
create trigger clinical_review_append_only
  before update or delete on clinical_reviews
  for each row execute function refuse_review_mutation();


-- ── What the user finally sees ───────────────────────────────────────────────
--
-- Kept separate from `predictions`, which is event-keyed with
-- `unique (event_id, kind)` — an uploaded panel is not an event — and from
-- `lab_escalations`, which is the emergency path and is never gated on a human.

create table if not exists insights (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,

  -- Not nullable: every insight comes from a draft, and the draft is where the
  -- evidence and the model version live. Cascade because they are one artefact
  -- recorded in two rows.
  draft_id uuid not null references clinical_drafts(id) on delete cascade,
  review_id uuid references clinical_reviews(id) on delete cascade,

  kind text not null
    check (kind in ('observation', 'lab_finding', 'supplement', 'therapy',
                    'lifestyle')),
  title text not null,
  body text not null,
  evidence jsonb not null default '[]'::jsonb,

  noticed_by text not null default 'agent'
    check (noticed_by in ('agent', 'clinician')),
  reviewed_by uuid references auth.users(id) on delete set null,
  reviewed_at timestamptz,

  -- Stamped at delivery from the clinicians table, not accepted from the
  -- caller, and never resolved at read time. The trail has to say what was
  -- true when the user was shown it: a clinician who later changes their name,
  -- leaves, or has their account removed must not silently rewrite the record
  -- of who signed. Same discipline as `ranges_version` on score_snapshots.
  reviewer_name text,
  reviewer_registration text,

  -- Which door it came through. `sla_expired` is the plan's de-risk for a
  -- queue that has stalled, and is only ever open to an unflagged draft.
  delivery_route text not null default 'clinician_signed'
    check (delivery_route in ('clinician_signed', 'sla_expired')),

  -- Stamped by a trigger, so no caller ever types it. This is what a later
  -- integrity check compares against the signature.
  --
  -- Not a generated column, though it reads like one: `convert_to` is STABLE
  -- rather than IMMUTABLE because it depends on the server encoding, and
  -- Postgres refuses a generation expression built on it. The trigger is the
  -- same guarantee by other means.
  body_sha256 text not null,

  delivered_at timestamptz not null default now(),

  -- A signed insight the user disagrees with needs a dispute path, not just a
  -- dismiss button. Both exist, and they mean different things: dismissed is
  -- "I have read this", disputed is "this is wrong about me".
  disputed_at timestamptz,
  dispute_reason text,
  dismissed_at timestamptz,
  withdrawn_at timestamptz,

  created_at timestamptz not null default now(),

  constraint insights_user_fkey
    foreign key (user_id) references auth.users(id) on delete cascade,

  constraint insight_title_present check (length(trim(title)) > 0),
  constraint insight_body_present check (length(trim(body)) > 0),
  -- A reviewer is a person, a time and the row that proves it. Any one of the
  -- three alone is a claim we cannot evidence.
  constraint reviewer_is_whole check (
    (review_id is null and reviewed_by is null and reviewed_at is null)
    or (review_id is not null and reviewed_by is not null
        and reviewed_at is not null)
  ),
  constraint dispute_carries_a_reason check (
    disputed_at is null or length(trim(coalesce(dispute_reason, ''))) > 0
  )
);

create index if not exists insights_user_time_idx
  on insights (user_id, delivered_at desc);

-- The app's primary read on open: what has arrived that I have not dealt with.
create index if not exists insights_user_open_idx
  on insights (user_id, delivered_at desc)
  where dismissed_at is null and withdrawn_at is null;

create index if not exists insights_draft_idx on insights (draft_id);


-- ── The delivery gate ────────────────────────────────────────────────────────
--
-- `review.signed_body_sha256 == sha256(delivery_body)`, as the plan specifies,
-- and in the database so that it binds the console and the service role as
-- well as our own delivery code. A one-character edit after signing makes the
-- insight structurally undeliverable rather than merely discouraged.

-- What `body_sha256` would have been as a generated column. Separate from the
-- gate below so that the stored hash is maintained even on the paths the gate
-- does not run on.
create or replace function stamp_insight_body_hash()
returns trigger
language plpgsql
as $$
begin
  new.body_sha256 := encode(sha256(convert_to(new.body, 'UTF8')), 'hex');
  return new;
end $$;

drop trigger if exists insight_body_hash on insights;
create trigger insight_body_hash
  before insert or update on insights
  for each row execute function stamp_insight_body_hash();


create or replace function enforce_delivery_gate()
returns trigger
language plpgsql
as $$
declare
  draft clinical_drafts;
  review clinical_reviews;
begin
  select * into draft from clinical_drafts where id = new.draft_id;

  if new.review_id is null then
    -- The unreviewed path. It exists only because a stalled queue would make
    -- the product feel dead, and it is deliberately narrow: no named reviewer,
    -- no routing flags, and only for a draft the SLA sweep has given up on.
    -- Widen any one of those three and the escape hatch eats the gate it was
    -- built beside.
    if new.reviewed_by is not null or new.reviewed_at is not null then
      raise exception
        'an insight cannot name a reviewer without the signature that proves it'
        using errcode = '23514';
    end if;

    if coalesce(array_length(draft.routing_flags, 1), 0) > 0 then
      raise exception
        'draft % carries routing flags (%) and can only be delivered with a '
        'signature', new.draft_id, array_to_string(draft.routing_flags, ', ')
        using errcode = '23514';
    end if;

    if draft.status <> 'expired' then
      raise exception
        'draft % is %, so there is no expired review to deliver without one',
        new.draft_id, draft.status
        using errcode = '23514';
    end if;

    new.delivery_route := 'sla_expired';
    new.noticed_by := 'agent';
    return new;
  end if;

  select * into review from clinical_reviews where id = new.review_id;

  if review.action <> 'signed' then
    raise exception
      'review % is a %, not a signature', new.review_id, review.action
      using errcode = '23514';
  end if;

  if review.draft_id is distinct from new.draft_id then
    raise exception
      'review % signed draft %, not draft %',
      new.review_id, review.draft_id, new.draft_id
      using errcode = '23514';
  end if;

  -- The gate itself.
  if review.signed_body_sha256
     <> encode(sha256(convert_to(new.body, 'UTF8')), 'hex') then
    raise exception
      'the body being delivered is not the body that was signed for draft %',
      new.draft_id
      using errcode = '23514';
  end if;

  -- Taken from the signature rather than from the caller, so the trail cannot
  -- be addressed to a clinician who did not sign it.
  new.reviewed_by := review.clinician_id;
  new.reviewed_at := coalesce(new.reviewed_at, review.created_at);
  new.delivery_route := 'clinician_signed';

  select full_name, registration_number
    into new.reviewer_name, new.reviewer_registration
    from clinicians where user_id = review.clinician_id;

  return new;
end $$;

drop trigger if exists insight_delivery_gate on insights;
create trigger insight_delivery_gate
  before insert on insights
  for each row execute function enforce_delivery_gate();


-- ── RLS ──────────────────────────────────────────────────────────────────────

alter table clinicians enable row level security;
alter table clinical_drafts enable row level security;
alter table clinical_reviews enable row level security;
alter table insights enable row level security;

-- A clinician reads their own registration, which is how the console shows
-- "your licence expires in 12 days" before it becomes a refused signature.
create policy "clinicians read their own registration"
  on clinicians for select using (auth.uid() = user_id);

-- 005 gave clinic_members a select policy for the member's own row only. A
-- clinician needs to see who else is in their clinic to hand work over.
create policy "clinicians read their clinic's roster"
  on clinic_members for select using (
    clinic_id in (select clinician_clinic_ids(auth.uid()))
  );


-- THE enforcement, and the reason this phase is shaped the way it is.
--
-- There is no policy here admitting the draft's own `user_id`, and there must
-- never be one. An unreviewed draft may say something wrong, frightening or
-- both; a filter in a query someone has to remember is not what should be
-- standing between it and the person it is about.
--
-- A clinician sees their clinics' queue and the unassigned network pool. Note
-- what this does NOT give them: the drafts of a clinic they have left, or of a
-- clinic they were never in.
create policy "clinicians read their queue"
  on clinical_drafts for select using (
    exists (select 1 from clinicians c
             where c.user_id = auth.uid() and c.status = 'active')
    and (
      clinic_id is null
      or clinic_id in (select clinician_clinic_ids(auth.uid()))
    )
  );

-- Claiming, revising and resolving. The state machine trigger decides which
-- moves are legal; this decides whose queue it is.
create policy "clinicians work their queue"
  on clinical_drafts for update using (
    exists (select 1 from clinicians c
             where c.user_id = auth.uid() and c.status = 'active')
    and (
      clinic_id is null
      or clinic_id in (select clinician_clinic_ids(auth.uid()))
    )
  ) with check (
    exists (select 1 from clinicians c
             where c.user_id = auth.uid() and c.status = 'active')
  );

-- Drafts are written by the agent under the service role, and deleted by
-- nobody: there is no insert or delete policy, deliberately. A user cannot
-- write themselves a draft, and a clinician cannot make one disappear --
-- `rejected` and `withdrawn` are how a draft ends, and both leave a row.


-- A clinician records their own actions, against a draft in their own queue.
-- Identity is all this decides; whether *anyone* may sign is the trigger's
-- business, because that question has to bind the service role too.
create policy "clinicians record their own reviews"
  on clinical_reviews for insert with check (
    clinician_id = auth.uid()
    and draft_id in (select id from clinical_drafts)
  );

create policy "clinicians read reviews in their queue"
  on clinical_reviews for select using (
    draft_id in (select id from clinical_drafts)
  );

-- No update or delete policy, and the append-only trigger behind it. The
-- policy absence stops the console; the trigger stops us.
revoke update, delete on clinical_reviews from authenticated;


-- The user-visible artefact, and the only one of the four they can read.
create policy "users read their own insights"
  on insights for select using (auth.uid() = user_id);

-- A clinician sees what was delivered from their queue, so a follow-up
-- conversation starts from what the person was actually told.
create policy "clinicians read insights from their queue"
  on insights for select using (
    draft_id in (select id from clinical_drafts)
  );

create policy "users respond to their own insights"
  on insights for update using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

-- RLS decides which ROWS a policy admits; it cannot restrict which COLUMNS an
-- update touches. Without this the policy above would let the phone rewrite
-- `body`, or put a clinician's name against a sentence no clinician saw.
-- Column privileges are the mechanism that actually limits it to responding,
-- exactly as 008 does for lab_escalations.acknowledged_at.
revoke update on insights from authenticated;
grant update (disputed_at, dispute_reason, dismissed_at) on insights to authenticated;

-- There is no insert policy on insights. Delivery is the service role's job,
-- through the gate above.


-- A signed insight has to reach the phone without waiting for a poll -- the
-- person has been waiting on a human, and the whole point of the trail is that
-- they see when it arrives.
alter publication supabase_realtime add table insights;
