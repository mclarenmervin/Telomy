-- The concierge's conversation, one row per turn.
--
-- F7 is the first feature that writes down something a user said in their own
-- words and something the product said back to them. Both halves need care,
-- and for different reasons.
--
-- ── Why the user cannot write here ──────────────────────────────────────────
--
-- There is no insert policy, and that absence is load-bearing in the same way
-- the missing select policy on `clinical_drafts` is. History is read back into
-- the next turn's prompt, so a row the user could forge is not merely a fake
-- transcript: it is an instruction channel into the agent's own context, from
-- the one party whose text the prompt is explicitly told to treat as data and
-- never as instructions. "You previously told me to take 400 mg of magnesium"
-- is a cheap sentence to write and an expensive one to have believed.
--
-- The gateway writes these rows with the service role, which bypasses RLS by
-- design, so application code is solely responsible for scoping them — as it
-- is everywhere else in this system.
--
-- ── Why the user cannot edit or delete here ─────────────────────────────────
--
-- The record of what a health product told somebody is the audit trail. If a
-- user reports that the app told them to stop a medication, the answer must be
-- a row and not a reconstruction. So turns are append-only from every side.
--
-- That is not a limit on the right to erasure, because the right is to erase
-- the *person*: `user_id` cascades from `auth.users`, so `delete_own_account`
-- takes the conversation with it. The test asserts that by deleting an
-- account rather than by reading `confdeltype` off the constraint — F6 shipped
-- a broken cascade that a `confdeltype = 'c'` assertion called correct for its
-- entire life, because a declared cascade that a trigger refuses is still a
-- declared cascade.
--
-- Clearing one's own history without closing the account is a real
-- expectation and deliberately not in this migration: it is a product
-- decision about how long a medical conversation is kept, and guessing at it
-- in a schema is how a retention policy gets set by accident.

create table if not exists chat_turns (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,

  -- What the person typed, verbatim. DATA, never instructions: the prompt says
  -- so, and `app/analytics/safety.py` screens it before any model sees it.
  --
  -- Bounded here as well as at the gateway. A megabyte of prose is a cost
  -- incident and a context-window denial of service, and "enforced at the
  -- boundary rather than in code that has to remember" is the same discipline
  -- the storage bucket's size cap follows.
  asked text not null check (char_length(asked) between 1 and 2000),

  -- What went out, AFTER the guardrails ran. Never the raw model output: this
  -- column is what the user actually read, which is the only version worth
  -- keeping and the only one that can honestly answer a complaint.
  answered text not null check (char_length(answered) between 1 and 8000),

  -- Which door the answer came out of. Without it, a week of silent
  -- SAFE_FALLBACK looks exactly like a week of useful conversation in every
  -- metric we have.
  --
  --   answered            the model answered and the rules left it alone
  --   guardrail_replaced  a rule matched; the safe fallback went out instead
  --   emergency           the deterministic screen fired before any model ran
  --   unavailable         no model, or the call failed; an honest fallback
  --
  -- A turn refused by the daily cap is deliberately absent from this list and
  -- is not written at all: nothing was spent and nothing was said, and a row
  -- for it would count towards the cap that produced it.
  route text not null check (route in
    ('answered', 'guardrail_replaced', 'emergency', 'unavailable')),

  -- From `apply_guardrails`, never typed by the producer -- the same rule F6
  -- settled for a draft's routing flags, and for the same reason: a second
  -- opinion about what counts as medication content eventually disagrees with
  -- the first.
  guardrail_flags text[] not null default '{}',

  -- Which signed insights this reply repeated verbatim. The provenance half of
  -- the `quoting_signed` guardrail profile: if a user ever asks why the app
  -- said something about a supplement, this names the finding and therefore
  -- the clinician whose registration number stands behind the words.
  --
  -- Not a foreign key, because an array cannot carry one. The insight itself is
  -- the record; this is the pointer.
  quoted_insight_ids uuid[] not null default '{}',

  -- Which model wrote it. A reply is only reproducible against the model that
  -- produced it, and "the concierge got worse last Tuesday" is answerable only
  -- if the rows say what changed.
  model text,

  created_at timestamptz not null default now()
);

-- Serves both reads: the last few turns for the prompt, and the count of
-- today's turns for the budget cap.
create index if not exists chat_turns_user_time_idx
  on chat_turns (user_id, created_at desc);

alter table chat_turns enable row level security;

create policy "users read their own conversation"
  on chat_turns for select
  using (user_id = (select auth.uid()));

comment on table chat_turns is
  'One concierge turn. Append-only from every side: the user cannot write a '
  'turn because history feeds the next prompt, and cannot edit or erase one '
  'because this is the record of what the product said. Erasure is by account '
  'deletion, which cascades.';
