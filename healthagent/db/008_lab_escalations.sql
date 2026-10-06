-- Where a critical lab value goes, immediately.
--
-- `predictions` cannot hold this: it is event-keyed with `unique (event_id,
-- kind)` and an uploaded report is not an event. `insights` is the F5
-- clinician-reviewed artefact, and routing an emergency through a review queue
-- is exactly the thing that must not happen.
--
-- So this table has one job and one level. A row here means "today, not at your
-- next appointment", and it is written before the user has confirmed anything,
-- while the catalog is still clinically unreviewed, and independent of any
-- review state.
--
-- Tested by db/tests/lab_ingest_test.sql.

create table if not exists lab_escalations (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  upload_id uuid not null references lab_uploads(id) on delete cascade,
  biomarker_id text not null,
  context text not null default 'standard',
  value_canonical double precision not null,
  operator text not null default '=' check (operator in ('=', '<', '>')),
  unit text not null,
  severity text not null default 'critical' check (severity = 'critical'),
  message text not null,
  -- The person has seen it. Never used to decide whether to fire.
  acknowledged_at timestamptz,
  created_at timestamptz not null default now(),

  -- Re-running the extraction worker on a report must not escalate twice. The
  -- webhook retries, and a user hitting a critical value three times because
  -- Supabase redelivered is how an alert stops being believed.
  unique (upload_id, biomarker_id, context)
);

create index if not exists lab_escalations_user_time_idx
  on lab_escalations (user_id, created_at desc);

-- Unacknowledged ones are the hot path: the app asks "is there anything I must
-- show this person right now?" on every open.
create index if not exists lab_escalations_open_idx
  on lab_escalations (user_id, created_at desc) where acknowledged_at is null;

alter table lab_escalations enable row level security;

create policy "users read their own escalations"
  on lab_escalations for select using (auth.uid() = user_id);

-- The user may mark one as seen, and that is all. There is no insert or delete
-- policy, so they cannot manufacture or remove a finding.
create policy "users acknowledge their own escalations"
  on lab_escalations for update using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

-- RLS decides which *rows* a policy admits; it cannot restrict which columns an
-- update touches. Without this, the policy above would let the phone rewrite
-- `message`, `value_canonical` or `severity` on its own escalation. Column
-- privileges are the mechanism that actually limits it to acknowledgement.
revoke update on lab_escalations from authenticated;
grant update (acknowledged_at) on lab_escalations to authenticated;

-- It has to reach the phone without waiting for a poll.
alter publication supabase_realtime add table lab_escalations;
