# Deploying the health agent to Railway

Why this exists: today the Supabase trigger calls a `trycloudflare.com` URL that points at a
laptop. Anyone running the app gets a session saved but no report the moment that laptop sleeps.
Railway gives the agent a permanent URL so the app works for anyone, on any device.

## What runs where

| Piece | Where it runs after this |
|---|---|
| Flutter app | the user's phone (publishable key only) |
| Supabase | Supabase (unchanged) |
| Gateway (`/webhooks/activity-sessions`) | Railway service, public URL |
| Activity worker (the agent) | Railway service, no public URL |
| Event worker (events + mid-event check-ins) | Railway service, no public URL |
| Redis (the queue between them) | Railway managed Redis |

The phone never talks to the agent. It writes a row to `activity_sessions`; the Postgres trigger
calls the gateway; the gateway enqueues `{session_id, user_id}`; the worker runs the agent and
writes to `predictions`; the phone gets the report over Supabase Realtime. So the phone needs no
agent URL and no agent credentials at all — that is what makes this safe to hand out.

## Services to create

Railway deploys from GitHub, one service per process. Because this is a monorepo, **set each
service's Root Directory to `healthagent`** — the Dockerfiles do `COPY app ./app` and expect
`healthagent/` as the build context.

1. **Redis** — add from Railway's database templates. It exposes `REDIS_URL`.
2. **gateway** — Root Directory `healthagent`, Dockerfile Path `docker/Dockerfile.gateway`.
   Generate a public domain for this one. Health check path: `/health`.
3. **activity-worker** — Root Directory `healthagent`, Dockerfile Path
   `docker/Dockerfile.activity-worker`. No public domain.
4. **worker** — Root Directory `healthagent`, Dockerfile Path
   `docker/Dockerfile.worker`. No public domain. **Required** for events and for
   mid-event check-ins: this is the only process that sweeps the `events:delayed`
   timer, so without it an open event is never looked at again and no check-in
   can ever fire.

`Dockerfile.gateway` reads `$PORT` (Railway assigns it) and falls back to 8000 so
`docker-compose` keeps working locally.

The `worker` service was optional while only activity reports existed. It is not optional any
more — mid-event check-ins live entirely in it (see
[the check-ins design](superpowers/specs/2026-10-04-mid-event-check-ins-design.md)).

## Variables (set on gateway, activity-worker and worker)

Generate the exact block from your local `.env` instead of retyping it:

```
cd healthagent
./scripts/railway_env.sh | pbcopy
```

Paste that into Railway's **RAW Editor** (Service → Variables) on all three services, or once into
project-level **Shared Variables**. The script warns on stderr if a key is missing from `.env` or
if `SUPABASE_DB_URL` points at the transaction pooler (6543) instead of the session pooler (5432).

It emits:

```
SUPABASE_URL=            # your project URL
SUPABASE_SERVICE_KEY=    # secret key, server side only — never in the app
SUPABASE_DB_URL=         # session pooler, port 5432
WEBHOOK_SECRET=          # must match what the Postgres trigger sends
OPENAI_API_KEY=
REDIS_URL=${{Redis.REDIS_URL}}
LLM_PROVIDER=openai
LLM_MODEL=gpt-5.4-mini
QUEUE_NAME=events:realtime
ACTIVITY_QUEUE_NAME=activity:realtime
MAX_LLM_CALLS=2
MAX_TOOL_CALLS=8
WALL_CLOCK_SECONDS=60
```

`REDIS_URL=${{Redis.REDIS_URL}}` is Railway's variable-reference syntax — it wires the services
together without pasting the URL.

Do **not** set `PORT`. Railway assigns it and the gateway reads it; overriding it can break the
health check.

`LLM_MODEL` is worth setting explicitly: `config.py` defaults to `gpt-4o-mini`, so leaving it
unset silently runs a different model than the one tested.

### Using a second provider for narration

The activity agent needs tool calling and a response schema **in one request**, which Groq
rejects outright (`json mode cannot be combined with tool/function calling`). The event agent's
narration is a single plain call, which Groq handles well. So a cheaper provider goes in per
purpose, not globally:

```
LLM_PROVIDER_NARRATION=groq
LLM_MODEL_NARRATION=openai/gpt-oss-120b
LLM_API_KEY_NARRATION=gsk_...
```

Any of `LLM_{PROVIDER,MODEL,API_KEY,BASE_URL}_<PURPOSE>` works, for the purposes `NARRATION`
and `ACTIVITY`. Before pointing a purpose at a new provider, run:

```
PYTHONPATH=. python scripts/check_llm_provider.py
```

It builds a real `create_agent` and fails loudly if the provider cannot serve the activity
agent — a check worth trusting over vendor capability tables, because this failure is otherwise
silent: the report still appears, just with a `narration_incomplete` flag and flatter prose.

`SUPABASE_DB_URL` must be the **session** pooler on port 5432, not 6543 — the LangGraph
checkpointer needs session-scoped connections and fails at `setup()` on the transaction pooler. If
the password contains `@`, `/`, `#` or `?`, URL-encode it or the connection string mis-parses.

A crash-looping gateway almost always means `SUPABASE_URL`, `SUPABASE_SERVICE_KEY` or
`WEBHOOK_SECRET` is absent — `get_settings()` raises `KeyError` on startup for those three.

## After the first deploy

1. Copy the gateway's Railway domain, e.g. `https://gateway-production-82cd.up.railway.app`.
2. Confirm it is alive: `curl https://<domain>/health`.
3. Re-point the Supabase trigger at it (run in the Supabase SQL editor):

```sql
create or replace function public.notify_activity_session()
returns trigger language plpgsql security definer as $$
begin
  perform net.http_post(
    url := 'https://<your-railway-domain>/webhooks/activity-sessions',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-webhook-secret', '<WEBHOOK_SECRET>'),
    body := jsonb_build_object('type','INSERT','table','activity_sessions',
      'record', jsonb_build_object('id',new.id,'user_id',new.user_id,
                                   'activity_type',new.activity_type)));
  return new;
end $$;
```

The trigger itself does not need recreating — only the function body changes.

4. Stop the cloudflared tunnel and the local Docker stack; they are no longer in the path.
5. Verify: run a session in the app, watch the activity-worker logs in Railway, confirm the card
   appears. Nothing on the phone changes, so an already-installed build picks this up.

## Handing the app to someone else

The app needs only `SUPABASE_URL` and `SUPABASE_PUBLISHABLE_KEY`, which are already in
`mobile/.env.supabase`. Build with:

```
flutter build apk --release --dart-define-from-file=.env.supabase
```

Never put `SUPABASE_SERVICE_KEY` in the app. An APK is a zip file; the service key bypasses RLS,
so shipping it would expose every user's data to anyone who unzips the build.

## Cost note

Redis plus two small services on Railway's usage plan runs a few dollars a month at demo volume.
The agent itself is capped at 2 LLM calls per session (`max_llm_calls`), so OpenAI cost scales
with sessions, not with time.
