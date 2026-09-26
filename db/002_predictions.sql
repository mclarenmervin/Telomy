-- predictions: what the agent tells the user about an event. Replaces the
-- temporary debug_log table. The mobile app reads it live through Realtime.
create table if not exists predictions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  event_id uuid not null,
  kind text not null check (kind in ('ack', 'analysis')),
  summary text not null,
  analysis jsonb not null default '{}'::jsonb,
  data_quality text not null default 'none'
    check (data_quality in ('full', 'partial', 'none')),
  guardrail_flags text[] not null default '{}',
  created_at timestamptz not null default now(),
  unique (event_id, kind)
);

create index if not exists predictions_user_time_idx
  on predictions (user_id, created_at desc);

alter table predictions enable row level security;

create policy "users read their own predictions"
  on predictions
  for select
  using (auth.uid() = user_id);

alter publication supabase_realtime add table predictions;
