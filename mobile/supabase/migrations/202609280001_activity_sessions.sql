create table if not exists public.activity_sessions (
  id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  activity_type text not null,
  started_at timestamptz not null,
  ended_at timestamptz not null,
  duration_seconds integer not null check (duration_seconds >= 0),
  summary jsonb not null default '{}'::jsonb,
  samples jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists activity_sessions_user_started_idx
  on public.activity_sessions (user_id, started_at desc);
alter table public.activity_sessions enable row level security;
drop policy if exists "Users manage own activity sessions" on public.activity_sessions;
create policy "Users manage own activity sessions"
on public.activity_sessions for all to authenticated
using ((select auth.uid()) = user_id)
with check ((select auth.uid()) = user_id);
grant select, insert, update, delete on public.activity_sessions to authenticated;
