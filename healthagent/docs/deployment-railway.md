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
| Scheduler (nightly score sweep, stuck-upload and purge sweeps) | Railway service, one replica |
| Score worker (computes score_snapshots) | Railway service, no public URL |
| Extraction worker (lab PDF → biomarker_results) | Railway service, no public URL |
| Lab report files | Supabase Storage, private `lab-reports` bucket |
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
5. **scheduler** — Root Directory `healthagent`, Dockerfile Path
   `docker/Dockerfile.scheduler`. No public domain. **Run exactly one replica.**
   It decides when work happens and computes nothing itself.
6. **score-worker** — Root Directory `healthagent`, Dockerfile Path
   `docker/Dockerfile.score-worker`. No public domain. Consumes `scores:batch`
   and writes `score_snapshots`, which is what the app reads instead of
   recomputing scores on the phone.
7. **extraction-worker** — Root Directory `healthagent`, Dockerfile Path
   `docker/Dockerfile.extraction-worker`. No public domain. Consumes
   `labs:batch` and turns an uploaded report into `biomarker_results`.
   **Required for lab uploads to do anything at all.** Without it a report
   uploads, nothing consumes the lane, and the row sits at `uploaded` until the
   scheduler's sweep marks it failed half an hour later.

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

## Migrations run themselves

Set the **gateway** service's **Pre-Deploy Command** to:

```
python -m app.migrate.main
```

Railway runs it after the build and before the new version takes traffic. If it
fails, the deploy fails and the old version keeps serving — which is what you
want, because starting new code against an old schema produces errors nobody
can explain.

Set it on **one service only**. The runner takes a Postgres advisory lock, so a
second one would simply wait and then find nothing to do, but there is no
reason to pay for that.

**What counts as a migration.** Only `db/NNN_*.sql`. `db/dev_harness.sql`
grants `anon` RLS policies for local browser testing and must never run in
production, so declaring a numbered prefix is how a file opts in.

**Applied migrations are history.** Each is recorded with a checksum, and
editing one that has already run is refused — this database would have done one
thing and the next would do another. Add a new migration instead.

**An existing database** that was migrated by hand is recorded without
re-running anything:

```
python -m app.migrate.main --baseline
```

`python -m app.migrate.main --dry-run` prints what would run and changes
nothing.

**`SUPABASE_DB_URL` must be the session pooler on port 5432**, as the
checkpointer already requires. Without it the migration step fails the deploy
rather than skipping silently.

## Turning on lab uploads (F3)

Everything below is additive. F1 (the biomarker catalog, units and reference
ranges) is a library inside the other services and needs nothing here, and F2's
services — scheduler and score-worker — already exist.

**1. Deploy the extraction-worker service** (number 7 above). Same variables as
the other workers; `./scripts/railway_env.sh` now emits `LAB_QUEUE_NAME` and
`OCR_ENGINE`. Its startup log line states which it got:

```
extraction worker started lane=labs:batch ocr=off
```

**2. The schema and the bucket arrive by themselves.** Migrations `007`–`010`
apply through the gateway's existing pre-deploy command. `007` creates the
private `lab-reports` bucket with a 20MB cap and a PDF/JPEG/PNG allowlist, and
the RLS policies on `storage.objects` that key on the first path segment. Check
it landed:

```sql
select id, public, file_size_limit, allowed_mime_types from storage.buckets;
```

`public` must be `false`. If it is ever `true`, every lab report in the project
is world-readable by URL.

**3. Add the trigger that starts extraction.** The phone uploads to Storage and
then inserts the `lab_uploads` row; this is what turns that row into a job. Run
it in the Supabase SQL editor, substituting your gateway domain and
`WEBHOOK_SECRET`:

```sql
create or replace function public.notify_lab_upload()
returns trigger language plpgsql security definer as $$
begin
  perform net.http_post(
    url := 'https://<your-railway-domain>/webhooks/lab-uploads',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-webhook-secret', '<WEBHOOK_SECRET>'),
    body := jsonb_build_object('type','INSERT','table','lab_uploads',
      'record', jsonb_build_object('id',new.id,'user_id',new.user_id,
                                   'status',new.status)));
  return new;
end $$;

create trigger lab_uploads_notify
  after insert on public.lab_uploads
  for each row execute function public.notify_lab_upload();
```

`after insert` only, and the gateway additionally ignores anything that is not
an INSERT at `status='uploaded'`. Confirming a panel UPDATEs this row, so
without both guards every tap on the confirmation screen would re-extract the
whole report.

**4. Verify end to end.** Upload a report in the app and watch the
extraction-worker logs. A healthy run logs
`upload <id> extracted: N result(s), M skipped`. The three failure states are
all deliberate and all say why on the row:

| `lab_uploads.status` | What happened |
|---|---|
| `needs_password` | Encrypted. The app asks for the password and retries. |
| `failed` + "looks like a scan" | No text layer and no OCR engine configured. |
| `extracted` | Ready for the user to confirm. Nothing reaches a score yet. |

**What is deliberately switched off.** `OCR_ENGINE` is blank, so photographed
and scanned reports fail with a reason rather than being read by an engine
nobody has measured against real printouts from your labs. Text-layer PDFs work
fully. Leave it blank until that bake-off has run.

**Nothing extracted is graded yet.** `biomarkers.v1.yaml` has not been reviewed
by a clinician, so every result comes back `ungraded` and the app shows the
number as printed with no verdict. That is enforced in code and stated to the
user on screen; flipping it needs a clinician's name and date in the file, which
the loader refuses to accept without. Critical values still escalate
immediately, because that cannot wait for a review meeting.

## Switching the readiness model

`READINESS_MODEL` selects which model the score worker runs. It is `v1` by
default: a faithful port of the model the phone has always used, kept in place
so the shadow period compares like with like.

Set it to `v2` only once the shadow log has shown **fourteen clean days with no
divergence at all**. Flipping it earlier gives any disagreement two possible
causes — a bad port or a changed model — with no way to tell them apart, which
is the one thing the whole exercise is designed to avoid.

A typo falls back to `v1` and logs an error rather than silently changing
every user's score.

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
