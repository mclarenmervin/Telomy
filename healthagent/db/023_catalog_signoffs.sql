-- Where a signature on reviewed clinical content is actually made.
--
-- Five files ship reviewed-content entries signed per entry and bound to a
-- content hash, and between them they carry ZERO signatures:
--
--   app/analytics/data/biomarkers.v1.yaml    33 markers; nine unblock bio age
--   app/analytics/data/supplements.v1.yaml    4 rules
--   app/analytics/data/correlations.v1.yaml   mechanism sentences
--   app/analytics/data/therapies.v1.yaml      modality-and-metric effects
--   app/analytics/data/variants.v1.yaml       the note beside a genotype
--
-- The reason is not that nobody has read them. It is that F6 built the
-- mechanism and left it unused because a signature needs a real name, a real
-- registration and a date, and a hand-edit to a YAML file is none of those.
-- The consequence is on real screens now: "Nobody has reviewed why these two
-- are related", "Nobody has reviewed what they mean yet", an empty biological
-- age. Four of those six sentences arrived in the last two phases and the
-- rate is increasing.
--
-- ── What this table is, and what it is not ──────────────────────────────────
--
-- It is the ACT of signing. git stays the source of truth for the CONTENT
-- that was signed.
--
-- That split is deliberate and it is the whole design. The loaders keep
-- reading YAML and nothing else, so:
--
--   * no catalog load becomes a database call, and `lru_cache` on every
--     loader stays sound;
--   * the property the catalog comments already lean on survives — "the git
--     diff shows the range changed, and the loader stops trusting the
--     signature in the same commit";
--   * a signature cannot take effect without a deploy, which for medical
--     content is a feature.
--
-- What the table adds is the half a file cannot hold: an identity verified
-- against `clinicians`, a licence that was unexpired at the moment of
-- signing, and a trail nobody can rewrite afterwards. The admin surface reads
-- these rows and renders the `clinical_review:` block to commit.
--
-- ── Who signs ───────────────────────────────────────────────────────────────
--
-- A registered clinician, authenticated as themselves. Not an admin on their
-- behalf — a signature somebody else can file in your name is not a
-- signature, and that refusal is the reason the whole surface is worth
-- building. The admin's job is to show what is waiting and to carry the
-- result into git; `signoff_recorded` in `admin_actions` is that act, not
-- this one.
--
-- Open question 8 in the programme doc is unchanged by this file: it does not
-- produce the signatory. It removes the excuse.


create table if not exists catalog_signoffs (
  id uuid primary key default gen_random_uuid(),

  -- Which file. Constrained, because a signature against a filename nobody
  -- reviews is a row that reads like coverage we do not have.
  catalog text not null
    check (catalog in ('biomarkers', 'supplements', 'correlations',
                       'therapies', 'variants')),

  -- The file's own `version:` string as it stood. Recorded rather than
  -- resolved at read time, same discipline as `ranges_version` on
  -- score_snapshots: the trail says what was true, not what is true now.
  catalog_version text not null,

  -- The entry within it: a biomarker id, a rule id, a pair id, a
  -- modality-and-metric, an rsid. Text rather than a foreign key because the
  -- entries live in YAML, which is the point.
  entry_id text not null,

  -- THE SIGNATURE. Over `content_fingerprint(entry)` — the whole entry, so a
  -- clinician signing a marker signs the ranges, the unit, the conversions,
  -- the labels and the citation together. Editing any of them moves the hash
  -- and the loader stops honouring this row, automatically, in the same
  -- commit as the edit.
  --
  -- Signing a name would be signing nothing: `albumin` is stable across every
  -- possible change to what albumin means.
  content_sha256 text not null
    check (content_sha256 ~ '^[0-9a-f]{64}$'),

  -- RESTRICT, as `clinical_reviews.clinician_id` is and for the same reason:
  -- a signature is a professional act and must not be erasable by the signer.
  -- The clinician's personal record is in `clinicians`, which does cascade.
  clinician_id uuid not null references auth.users(id) on delete restrict,

  action text not null default 'signed'
    check (action in ('signed', 'withdrawn')),

  -- Stamped by the trigger from `clinicians`, never accepted from the caller
  -- and never resolved at read time. A clinician who later changes their
  -- name, leaves, or has their account removed must not silently rewrite the
  -- record of who signed what.
  reviewer_name text,
  reviewer_registration text,

  notes text,
  signed_at timestamptz not null default now(),

  -- Which action came later, answered by insertion order rather than by a
  -- clock. `signed_at` defaults to now(), which inside one transaction is the
  -- transaction's start time -- so a signature and its withdrawal written
  -- together carry the identical timestamp and "which is current" becomes
  -- whichever row the planner happens to return first. The test found exactly
  -- that. Two events a millisecond apart in production would have had the
  -- same problem on a coarse clock.
  seq bigserial not null,

  -- A withdrawal is the one event here that most needs an explanation. A
  -- signature disappearing with no reason recorded is how a range quietly
  -- reverts.
  constraint withdrawal_carries_a_reason check (
    action <> 'withdrawn' or length(trim(coalesce(notes, ''))) > 0
  )
);

create index if not exists catalog_signoffs_entry_idx
  on catalog_signoffs (catalog, entry_id, seq desc);
create index if not exists catalog_signoffs_clinician_idx
  on catalog_signoffs (clinician_id, signed_at desc);

comment on table catalog_signoffs is
  'The act of signing reviewed clinical content. git holds the content; this '
  'holds the verified identity, the licence state at signing time and the '
  'trail. Append-only. The loaders never read it.';


-- ── The gate ────────────────────────────────────────────────────────────────

create or replace function enforce_catalog_signoff()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  signer clinicians;
begin
  -- Checked in a trigger rather than only in a policy, which is 013's lesson
  -- stated once more: the agent and the scheduler hold the service role and
  -- RLS does not apply to them, so a licence check that only binds a client
  -- has a service-role-shaped hole in it. This is content that will be shown
  -- to people as reviewed, so the hole matters more here than almost
  -- anywhere.
  if not clinician_may_sign(new.clinician_id) then
    raise exception
      'clinician % may not sign: no active registration with an unexpired '
      'licence and a current clinic membership', new.clinician_id
      using errcode = '23514';
  end if;

  select * into signer from clinicians where user_id = new.clinician_id;

  -- Refused rather than overwritten. A caller who supplied a name was trying
  -- to assert something, and quietly replacing it would hide the attempt.
  if new.reviewer_name is not null
     and new.reviewer_name is distinct from signer.full_name then
    raise exception
      'the reviewer name is stamped from the registration and cannot be '
      'supplied'
      using errcode = '23514';
  end if;
  if new.reviewer_registration is not null
     and new.reviewer_registration is distinct from signer.registration_number
  then
    raise exception
      'the registration number is stamped from the registration and cannot '
      'be supplied'
      using errcode = '23514';
  end if;

  new.reviewer_name := signer.full_name;
  new.reviewer_registration := signer.registration_number;
  return new;
end $$;

drop trigger if exists catalog_signoff_gate on catalog_signoffs;
create trigger catalog_signoff_gate
  before insert on catalog_signoffs
  for each row execute function enforce_catalog_signoff();


create or replace function refuse_catalog_signoff_mutation()
returns trigger
language plpgsql
as $$
begin
  raise exception
    'catalog_signoffs is append-only; a signature cannot be %. A withdrawal '
    'is a new row, so that "signed in October, withdrawn in November" stays a '
    'fact rather than becoming an absence',
    lower(tg_op)
    using errcode = '23514';
end $$;

drop trigger if exists catalog_signoff_append_only on catalog_signoffs;
create trigger catalog_signoff_append_only
  before update or delete on catalog_signoffs
  for each row execute function refuse_catalog_signoff_mutation();


-- ── Reading the current state ───────────────────────────────────────────────
--
-- Per (entry, hash) rather than per entry, deliberately. Two hashes signed
-- for one entry is two facts: somebody signed the old wording and somebody
-- signed the new one, and collapsing them would lose which version of a
-- sentence a named clinician actually put their registration against.
--
-- The caller joins this against the file's own fingerprints to decide what is
-- live, which is the one place the two halves meet.

create or replace function catalog_signoff_state(p_catalog text)
returns table (
  entry_id text,
  content_sha256 text,
  action text,
  reviewer_name text,
  reviewer_registration text,
  signed_at timestamptz,
  notes text
)
language sql
stable
as $$
  select distinct on (s.entry_id, s.content_sha256)
         s.entry_id, s.content_sha256, s.action, s.reviewer_name,
         s.reviewer_registration, s.signed_at, s.notes
    from catalog_signoffs s
   where s.catalog = p_catalog
   -- `seq`, not `signed_at`: see the column's comment. A timestamp is what a
   -- person reads; a sequence is what decides.
   order by s.entry_id, s.content_sha256, s.seq desc;
$$;

comment on function catalog_signoff_state(text) is
  'The latest action per (entry, content hash) for one catalog, by insertion '
  'order. Keyed on the hash as well as the entry because two hashes signed is '
  'two facts.';


-- ── RLS ─────────────────────────────────────────────────────────────────────

alter table catalog_signoffs enable row level security;

-- A clinician signs as themselves. Identity is all this decides; whether
-- *anyone* may sign is the trigger's business, because that question has to
-- bind the service role too — the same division 013 draws.
create policy "clinicians sign as themselves"
  on catalog_signoffs for insert with check (clinician_id = auth.uid());

-- And reads their own, which is how they see what they have already taken a
-- view on before being asked again.
create policy "clinicians read their own signatures"
  on catalog_signoffs for select using (clinician_id = auth.uid());

-- An admin reads every signature, because collecting them is the job. There
-- is deliberately no admin INSERT policy: an admin filing a signature in a
-- clinician's name is the one thing this whole surface exists to make
-- impossible.
create policy "admins read every signature"
  on catalog_signoffs for select using (app_role_of(auth.uid()) = 'admin');

-- No update or delete policy, and the trigger behind it. A member has no
-- policy at all and reads zero: this is operational, not their record.
revoke update, delete on catalog_signoffs from authenticated, anon;
