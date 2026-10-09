-- A finding, not a run.
--
-- 013 gave clinical_drafts no natural key, so the nightly sweep would create a
-- fresh row for the same finding every night until somebody acted on it. A
-- queue that grows while it is being worked is a queue nobody works, and this
-- is the same defect lab_escalations avoids with
-- `unique (upload_id, biomarker_id, context)`: the webhook retries, the sweep
-- re-runs, and the user must not be told the same thing three times.
--
-- The key identifies what was noticed -- marker, context, latest draw date --
-- rather than when we noticed it. Two sweeps on different days produce the same
-- key for the same finding; a new panel moves the draw date and is correctly a
-- new finding.
--
-- Deliberately indifferent to what state the existing draft reached. A
-- clinician who rejected a finding must not be asked about it again tomorrow,
-- so `rejected` suppresses a recreation exactly as `signed` does.
--
-- Tested by db/tests/clinical_review_test.sql.

alter table clinical_drafts
  -- NOT NULL with a random default rather than nullable: every draft should be
  -- attributable to a reason, and a draft that genuinely has no natural key --
  -- one a clinician composes by hand later -- gets a unique one and is never
  -- blocked by the constraint. A nullable column would have needed a partial
  -- unique index, which ON CONFLICT cannot infer without repeating the
  -- predicate at every call site.
  add column if not exists dedupe_key text not null default gen_random_uuid()::text;

alter table clinical_drafts drop constraint if exists one_draft_per_finding;
alter table clinical_drafts add constraint one_draft_per_finding
  unique (user_id, dedupe_key);
