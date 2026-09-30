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

`Dockerfile.gateway` reads `$PORT` (Railway assigns it) and falls back to 8000 so
`docker-compose` keeps working locally.

The existing `worker` (the older realtime event worker) is optional for this feature; deploy it
the same way as activity-worker if you want it.

## Variables (set on gateway and activity-worker both)

```
SUPABASE_URL=https://oeghvplwcsxhimxvozzb.supabase.co
SUPABASE_SERVICE_KEY=<secret key — server side only, never in the app>
SUPABASE_DB_URL=<pooler connection string, port 5432 session mode>
WEBHOOK_SECRET=<the same long random string the trigger sends>
REDIS_URL=${{Redis.REDIS_URL}}
QUEUE_NAME=events:realtime
ACTIVITY_QUEUE_NAME=activity:realtime
LLM_PROVIDER=openai
OPENAI_API_KEY=<key>
LLM_MODEL=gpt-5.4-mini
```

`${{Redis.REDIS_URL}}` is Railway's variable-reference syntax — it wires the services together
without pasting the URL.

`SUPABASE_DB_URL` must be the **pooler** URL on port 5432 (session mode), not 6543 — the
LangGraph checkpointer uses prepared-statement-free session connections. It is already pooled and
health-checked in `app/common/checkpointer.py`.

## After the first deploy

1. Copy the gateway's Railway domain, e.g. `https://telomy-gateway-production.up.railway.app`.
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
