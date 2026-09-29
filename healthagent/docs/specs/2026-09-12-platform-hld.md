# Platform High-Level Design

**Date:** 2026-09-12
**Status:** Draft for review
**Scope:** Everything outside the agent — entry points, data model, service
topology, analytics layer, deployment.

---

## 1. Architectural Principles

These five principles explain most of the decisions in this document. When a
future change conflicts with one of them, that is a signal to reconsider the
change.

**P1 — One event contract.**
`events` is the single table that triggers analysis. A button press, a voice
command, and an ML detection all produce the *same row shape*. Downstream code
neither knows nor cares which one fired. This is what lets Phases 2 and 3 be
purely additive.

**P2 — Compute deterministically; let the LLM narrate.**
"Did they sleep 8 hours?" is subtraction. Asking an LLM to do arithmetic over
sensor data is slower, costlier, and wrong more often. Every number is computed
in ordinary Python; the LLM turns already-computed facts into language.

**P3 — Stateless workers, state in Postgres.**
No worker holds user state between jobs. This is simultaneously the scaling
story, the isolation story, and the resumability story.

**P4 — Separate the ingest path from the compute path.**
The HTTP request lifecycle is never coupled to agent execution time. Ingest
acknowledges in milliseconds; work happens on a durable queue.

**P5 — The agent is invisible to the frontend.**
The mobile team integrates with Supabase tables only. The agent has no public
address and no documented API from the client's perspective.

## 2. System Context

```
┌──────────────┐   BLE    ┌──────────────┐
│ Ring / Band  │─────────▶│  Mobile App  │  (other team)
└──────────────┘          └──────┬───────┘
                                 │ auth, reads, writes
                                 ▼
                      ┌─────────────────────┐
                      │      SUPABASE       │  shared data plane
                      │ Postgres · Auth ·   │
                      │ Storage · Realtime  │
                      └──────────┬──────────┘
                                 │ webhooks / polling
              ═══════════════════╪═══════════════════  isolation boundary
                                 ▼
        ┌────────────────────────────────────────────────┐
        │           THIS PROJECT (Railway, Docker)       │
        │                                                │
        │  Gateway · Detector · Analytics · Agent        │
        │  Extraction · Scheduler · Redis                │
        └────────────────────────────────────────────────┘
                                 │
                                 ▼
                   LLM APIs · Web search · MCP servers
```

## 3. Entry Points

Four ways work enters the system. They differ in one respect that drives the
design: **whether a human is waiting.**

```
① EVENT-DRIVEN        ② CHAT              ③ SCHEDULED        ④ UPLOAD
   button/voice/         user asks           cron tick          lab report
   detector              a question
       │                     │                   │                  │
   DB webhook          SSE / WebSocket        scheduler       storage hook
       │                     │                   │                  │
       ▼                     ▼                   ▼                  ▼
   ┌────────┐          ┌──────────┐         ┌────────┐        ┌────────┐
   │ queue  │          │  direct  │         │ queue  │        │ queue  │
   │(async) │          │(stream)  │         │(batch) │        │(batch) │
   └────────┘          └──────────┘         └────────┘        └────────┘
```

| Entry | Sync? | Path | Latency target |
|---|---|---|---|
| ① Event | No | webhook → queue → worker | < 30 s to first output |
| ② Chat | **Yes** | SSE, bypasses queue | < 2 s first token |
| ③ Scheduled | No | cron → queue (batch lane) | minutes |
| ④ Upload | No | storage hook → queue | minutes |

Chat bypasses the job queue deliberately. Routing an interactive request behind
a backlog of ten thousand weekly reports would make it unusable. Same agent
runtime, same tools — different door.

### 3.1 Event Flow (canonical path)

```
1. Mobile app inserts row   → events (status='started')
2. Supabase webhook fires   → POST /webhooks/events
3. Gateway verifies secret  → rejects unverified requests outright
4. Gateway reads user_id from the verified payload
5. Gateway enqueues job     → Redis (realtime lane), returns 202
6. Agent worker consumes    → loads context, runs graph
7. Worker writes results    → predictions / alerts
8. Mobile app receives      → Supabase Realtime subscription
9. On 'Stop', steps 2–8 repeat to close the session
```

The webhook payload carries the full row, so `user_id` arrives with the trigger
— no lookup required:

```json
{
  "type": "INSERT",
  "table": "events",
  "record": {
    "id": "evt_9f2a...",
    "user_id": "a3d1e8c0-...",
    "event_type": "alcohol",
    "status": "started",
    "started_at": "2026-09-12T18:42:10Z",
    "source": "manual",
    "metadata": { "declared_qty": 1 }
  }
}
```

> **Security:** the gateway endpoint is a public HTTPS URL. Without signature
> verification, anyone could POST an arbitrary `user_id` and cause the agent to
> dump another person's health history into a prediction row. Verification
> happens **before any field is read**. See NFR-3.1.

### 3.2 Monitoring Windows, Not Fire-and-Forget Jobs

Events are windows (start → watch → stop), not instants. A plain job queue runs
a task once and exits.

**We do not hold a worker for the duration of the window.** A 45-minute event
occupying a worker would exhaust the pool. Instead, each re-evaluation is its own
short job:

```
event start → run initial analysis
            → enqueue next re-evaluation at T+n minutes
            → worker exits

(repeat until)

event stop  → final analysis, close session, cancel pending re-evaluations
            OR
timeout     → auto-close if open beyond expected_max_duration for the type
```

`expected_max_duration` per event type is a required backstop: an "eating"
session still open after 3 hours is a bug, not a long lunch. This matters more
once auto-detection lands, where nothing tells the system an event ended.

## 4. Data Model

Tables are grouped by **how the data behaves**, not by subject matter, because
behaviour determines storage strategy, retention, and who reads it.

### 4.1 Hot — high-volume, append-only

```sql
telemetry_raw            -- as uploaded by phone, batched
  user_id, ts, hr, hrv, temp, spo2,
  accel_x, accel_y, accel_z, gyro_x, gyro_y, gyro_z,
  source_device
  -- PARTITIONED BY day; SHORT retention (7–30 days)

telemetry_features       -- 1-minute aggregates — the workhorse
  user_id, minute_ts,
  hr_mean, hr_std, hr_slope, hr_delta_baseline,
  hrv_mean, hrv_delta_baseline,
  temp_mean, temp_delta, spo2_mean,
  motion_energy, motion_variance, motion_class,
  -- LONG retention
```

**Why the split.** At 1 Hz × 8 channels, one user generates ~86,400 rows/day;
10,000 users is ~864M rows/day. Nothing good happens if the detector and the
training pipeline both query that.

`telemetry_features` at one row/user/minute is ~1,440 rows/user/day — ~14M/day
at 10k users, entirely manageable. It is what the detector evaluates, what the
ML trains on, and what the agent reads for event windows. Raw telemetry is kept
only long enough to debug and to re-derive features if definitions change.

### 4.2 Warm — per-user state

```sql
events                   -- THE trigger table (P1)
  id, user_id, event_type,
  status,                -- started | candidate | confirmed | rejected | ended | expired
  source,                -- manual | voice | auto
  confidence,            -- null for manual
  started_at, ended_at, expected_max_duration,
  metadata jsonb

user_baselines           -- personal reference points, recomputed nightly
  user_id, metric, mean, std, computed_at, sample_days

detector_state           -- per-user watermark + warm-up status
  user_id, last_processed_ts, baseline_ready, shard_key

pending_approvals        -- human-in-the-loop (see Agent LLD §7)
  id, user_id, thread_id, question, options, status, expires_at
```

### 4.3 Cold — reference data (agent only; detector never reads these)

```sql
user_profile             -- demographics, conditions, medications
user_genetics            -- variants, metaboliser status, family history
user_allergies           -- safety-critical; deterministic fetch only
lab_results              -- structured values extracted from uploads
documents                -- uploaded file metadata + extraction status
therapy_sessions         -- therapy machine output
environment_readings     -- temp, humidity, UV, AQI by location + time
predictions              -- agent output
alerts                   -- delivered notifications
audit_log                -- every agent data access, by user_id + session_id
```

> The detector reads **only** `telemetry_raw`, `telemetry_features`,
> `user_baselines`, and `detector_state`. Genetics and lab reports do not help
> answer "did something just happen?" Keeping that dependency list short is what
> makes the detector fast and independently testable.

### 4.4 Event Status Lifecycle

```
   manual/voice                    auto-detected
        │                                │
        ▼                                ▼
    started ──────┐              candidate ──┬── user confirms ──▶ confirmed
        │         │                          │                        │
        │         │                          └── user rejects ──▶ rejected
        │         │                                              (training label)
        ▼         ▼                                                   │
      ended    expired  ◀── exceeded expected_max_duration ───────────┘
```

`rejected` is not a failure state — it is a labelled negative, and one of the
most valuable rows in the system.

## 5. The Analytics Layer

The layer that keeps the system honest, and the direct expression of P2.

```
        Supabase (telemetry_features, events, lab_results, …)
                              │
                              ▼
            ┌─────────────────────────────────────┐
            │         ANALYTICS                   │   pure Python, NO LLM
            │  sleep duration · HRV trends ·      │   deterministic
            │  baseline deltas · streaks ·        │   testable
            │  readiness scores · adherence ·     │   cacheable
            │  event before/during/after deltas   │   fast
            └─────────────────────────────────────┘
                     │                      │
          ┌──────────┘                      └──────────┐
          ▼                                            ▼
  ┌────────────────┐                          ┌──────────────────┐
  │  REST for UI   │                          │   Agent tools    │
  │ charts, stats  │                          │ (LLM calls these)│
  └────────────────┘                          └──────────────────┘
```

**The rule: both consumers call the same code.** If `/api/sleep-summary`
computes sleep hours one way and the agent's `get_sleep_summary` tool computes
it another, you will eventually show 6.2 hours on a chart while the chatbot says
6.8 — and users lose trust in the entire product. One implementation, two
callers.

This also means the UI gets fast, cheap, deterministic data for everything it
displays without ever invoking an LLM — which covers most of a health app's
surface area.

### 5.1 Division of Labour

| Task | Owner |
|---|---|
| Sleep duration, averages, trends, deltas | Analytics — pure code |
| Baseline comparison, threshold checks | Analytics — pure code |
| Readiness / recovery scores | Analytics — pure code |
| Event detection | Detector — ML, no LLM |
| Parsing uploaded lab reports | Extraction — OCR/parser; LLM for messy fields only |
| **Deciding** an alert should fire | Analytics — deterministic rule |
| **Wording** that alert | LLM |
| Weekly narrative report | LLM over pre-computed numbers |
| Chat Q&A | LLM calling analytics as tools |
| Explaining *why* something changed | LLM — genuine reasoning |

The alert row is the template for the whole system: the *decision* is a rule
(`sleep < 6h for 3 consecutive nights`), so it fires reliably and is unit-
testable; only the *phrasing* is generative.

### 5.2 Packaging

Analytics starts as a **shared library** imported by the gateway, agent workers,
and scheduler — same code, one less service to operate. Extract it into its own
deployed service only when something concrete forces the split (independent
scaling needs, or a non-Python consumer).

## 6. Service Topology

| Service | Type | Responsibility | Scales by |
|---|---|---|---|
| **Gateway** | FastAPI | Webhook verification, enqueue, chat SSE, REST for UI. Deliberately thin. | replicas |
| **Analytics** | library | Deterministic computation. Shared by all consumers. | n/a |
| **Agent workers** | queue consumer | LLM orchestration. Expensive, slow, isolated. | replicas |
| **Detector worker** | tick loop | Feature computation + event detection. Never LLM. | replicas (sharded) |
| **Extraction worker** | queue consumer | Documents → structured rows. | replicas |
| **Scheduler** | cron | Enqueues digests, reports, threshold sweeps. | single |
| **Redis** | infra | Job queue (2 lanes) + detector windows + cache. | single instance initially |
| **Supabase** | managed | Postgres, auth, storage, Realtime. | managed |

The separation is what makes this both fast to build and fast at runtime: the
gateway does almost nothing (so it never blocks), the detector does only
arithmetic (so it never calls an LLM), and the agent runs only on real events
(so idle time is free). Each is independently buildable, deployable, and
debuggable.

### 6.1 Queue Lanes

Two lanes from day one:

| Lane | Contents | Priority |
|---|---|---|
| `realtime` | Event analysis, mid-event alerts, HITL resumes | High |
| `batch` | Daily digests, weekly reports, document extraction, retraining | Low |

Retrofitting priority separation under production load is painful; the cost of
having it from the start is negligible.

### 6.2 Why Polling for Telemetry, Webhooks for Events

| | Events | Telemetry |
|---|---|---|
| Volume | ~5 rows/user/day | continuous |
| Latency need | seconds | ~1 minute acceptable |
| Mechanism | **Webhook** | **Polling (60 s tick)** |

A webhook per sensor batch would mean millions of HTTP calls/day with no
batching and no backpressure. Polling is unglamorous and strictly better for
this shape: it batches naturally, load is predictable, and a slow tick simply
picks up more rows next time rather than creating a pile-up of concurrent
requests.

## 7. Deployment

**Railway, Docker, isolated.** No frontend client holds the agent's address.

```
Railway project
├── gateway            (FastAPI, public HTTPS — webhook + REST + chat only)
├── agent-worker       (queue consumer, N replicas)
├── detector-worker    (tick loop, N replicas, user-sharded)
├── extraction-worker  (queue consumer)
├── scheduler          (cron)
└── redis              (managed add-on)

External: Supabase (managed), LLM APIs, web search, MCP servers
```

Only the gateway is publicly reachable, and its public surface is limited to
verified webhooks, authenticated REST for the UI, and the chat stream.

### 7.1 Session Isolation — Explicit Decision

**We do not use VM-per-session isolation** (as in AWS Bedrock AgentCore's
Firecracker microVMs).

That mechanism exists to solve one problem: safely running **untrusted code**.
Our tools are database queries, web search, document retrieval, and LLM calls —
all bounded operations against systems we control. A microVM protects against a
malicious *process*; it does nothing about the risk we actually have, which is
**user A's data appearing in user B's context**. That is a logic bug, and no
amount of VM isolation catches it.

What we use instead:

- **Stateless workers** — context loaded fresh per job, nothing retained.
- **A single scoped context loader** — every query scoped by the verified
  `user_id`; one auditable place where scoping can go wrong.
- **Per-job context objects** — never process-global.
- **Namespaced long-term memory** — cross-user retrieval structurally
  impossible.

**When this decision should be revisited:** the moment a tool executes
LLM-generated code (e.g. "write Python to analyse this user's HRV trend"). That
is genuine untrusted execution and needs a real sandbox. Railway does not offer
microVMs, but it does not need to — E2B, Daytona, Modal, or Vercel Sandbox
provide ephemeral isolated execution behind an API call. The agent stays on
Railway and calls out for that one tool. **Add it when code execution is added,
not before.**

## 8. Build Order

Each step is independently verifiable, and each produces something demonstrable.

1. **Supabase schema** — tables, RLS for the mobile app, webhook configuration.
2. **Gateway + queue + trivial worker** — worker only logs. Proves the full
   trigger path end-to-end with a button press. *Highest-value first step: it
   de-risks the integration contract before any intelligence is built.*
3. **Telemetry ingestion + feature computation + baselines.**
4. **Analytics library** + REST endpoints for the UI.
5. **Real agent** (see Agent LLD).
6. **Scheduler** — digests, reports, threshold alerts.
7. **Document extraction.**
8. **Voice** — STT + backend intent parsing → same `events` table.
9. **Detector** — shadow mode → candidate events → ML (see Detector LLD).

Steps 8 and 9 are purely additive by construction: both are new *writers* to
`events`, and nothing downstream changes.

## 9. Cross-Cutting Concerns

**Observability.** Every job carries `user_id`, `session_id`, and `event_id`
through structured logs. Track per-session token spend, tool-call counts, and
wall-clock duration — cost regressions are otherwise invisible until the bill.

**Idempotency.** Webhooks retry. Jobs are keyed by `(event_id, status,
attempt_reason)` so a duplicate delivery does not produce duplicate predictions.

**Failure handling.** Queue retries with exponential backoff; a dead-letter lane
for repeated failures; a failed agent run must never leave a half-finished
prediction visible to the user.

**Backfill.** Feature definitions will change. Retaining raw telemetry for a
bounded window makes recomputation possible; the extraction job must be
versioned so training and serving always agree (see Detector LLD §8).

## 10. Related Documents

- [PRD](./2026-09-12-prd.md)
- [Detector Low-Level Design](./2026-09-12-detector-lld.md)
- [Agent Low-Level Design](./2026-09-12-agent-lld.md)
