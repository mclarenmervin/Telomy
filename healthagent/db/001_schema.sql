-- events: the single trigger table for the whole platform (Platform HLD P1).
-- A button press, a voice command, and (later) the detector all write this
-- same shape. Downstream code never knows which one fired.
create table if not exists events (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  event_type text not null,
  status text not null
    check (status in ('started', 'candidate', 'confirmed', 'rejected', 'ended', 'expired')),
  source text not null
    check (source in ('manual', 'voice', 'auto')),
  confidence numeric,
  started_at timestamptz not null default now(),
  ended_at timestamptz,
  expected_max_duration interval,
  metadata jsonb not null default '{}'::jsonb
);

alter table events enable row level security;

create policy "users manage their own events"
  on events
  for all
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

-- debug_log: TEMPORARY, this-milestone-only. Proves the webhook -> queue ->
-- worker -> write-back loop closes before the real `predictions` table
-- exists (Build Order step 5). Delete this table once step 5 lands.
create table if not exists debug_log (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null,
  user_id uuid not null,
  event_type text,
  note text,
  created_at timestamptz not null default now()
);

alter table debug_log enable row level security;

create policy "users read their own debug log"
  on debug_log
  for select
  using (auth.uid() = user_id);
