# healthagent

Event-driven health intelligence platform. Correlates **life events** (eating,
drinking, smoking, exercise, therapy) with **continuous wearable telemetry**,
then explains what those events do to the user's body — using their genetics,
lab reports, therapy history, and environment as context.

**This repo is backend + agent only.** The mobile app is built by a separate
team. The two sides integrate *exclusively* through Supabase tables.

---

## Design Documents

Read these before making architectural changes.

| Doc | Covers |
|---|---|
| [PRD](docs/specs/2026-09-12-prd.md) | Requirements, event taxonomy, phasing, risks |
| [Platform HLD](docs/specs/2026-09-12-platform-hld.md) | Entry points, data model, service topology, analytics layer |
| [Detector LLD](docs/specs/2026-09-12-detector-lld.md) | Feature computation, ML methodology, evaluation |
| [Agent LLD](docs/specs/2026-09-12-agent-lld.md) | State schema, memory, sub-agents, HITL, guardrails |

## Stack

Python · LangGraph · FastAPI · Redis · Supabase (Postgres/Auth/Storage/Realtime)
· Docker on Railway

---

## The Five Principles

Most decisions in this codebase follow from these. A change that conflicts with
one is a signal to reconsider the change.

**P1 — One event contract.**
`events` is the single table that triggers analysis. Button press, voice command,
and ML detection all produce the *same row shape*. Downstream code never knows
which fired. This is what makes new input methods purely additive.

**P2 — Compute deterministically; let the LLM narrate.**
"Did they sleep 8 hours?" is subtraction. Every number is computed in ordinary
Python; the LLM turns already-computed facts into language. Never ask an LLM to
do arithmetic over sensor data.

**P3 — Stateless workers, state in Postgres.**
No worker holds user state between jobs. This is simultaneously the scaling
story, the isolation story, and the resumability story.

**P4 — Ingest path is never coupled to compute path.**
The gateway acknowledges in milliseconds; work happens on a durable queue.

**P5 — The agent is invisible to the frontend.**
Mobile integrates with Supabase tables only. The agent has no public address.

---

## Architecture at a Glance

```
   ① BUTTON      ② VOICE       ③ DETECTOR          ← three writers
   (phase 1)     (phase 2)     (phase 3)
       └─────────────┴──────────────┘
                     ▼
              events table                          ← ONE contract (P1)
                     ▼
        webhook → Redis queue → agent worker
                     ▼
         predictions / alerts → Supabase Realtime → app
```

Separately and continuously:

```
Ring/band ──BLE──▶ Phone ──batch──▶ telemetry_raw
                                         ▼
                        Detector worker (60s tick, user-sharded)
                                         ▼
                     telemetry_features  +  Redis rolling window
```

### Services

| Service | Role |
|---|---|
| `gateway` | FastAPI. Webhook verification, enqueue, chat SSE, REST for UI. Thin by design. |
| `analytics` | **Library**, not a service (initially). Deterministic computation. |
| `agent-worker` | Queue consumer. LangGraph orchestration. |
| `detector-worker` | 60s tick loop. Sensor math only — never an LLM. |
| `extraction-worker` | Documents → structured rows. |
| `scheduler` | Cron: digests, reports, threshold sweeps. |
| `redis` | Queue (2 lanes: `realtime`, `batch`) + detector windows + cache. |

---

## Non-Negotiable Rules

These exist because violating them causes data leaks, silent model failure, or
runaway cost. They are not style preferences.

### Security

- **Verify the webhook secret before reading any field.** The gateway is a public
  URL; an unverified request could supply an arbitrary `user_id` and cause the
  agent to dump another person's health history.
- **The agent uses service-role credentials that bypass RLS by design.** RLS
  protects the mobile app, not us. *Application code is solely responsible for
  tenant isolation.*
- **All user data is read through the single scoped context loader.** Never
  construct a raw user-scoped query elsewhere. One auditable place.
- **Tools must never accept `user_id` as a parameter** — it comes from state.
  This makes cross-tenant access impossible by construction:

  ```python
  # CORRECT
  def get_sleep_summary(days: int, *, state): 
      return analytics.sleep_summary(user_id=state["user_id"], days=days)

  # FORBIDDEN — the model could supply any id
  def get_sleep_summary(user_id: str, days: int): ...
  ```

- **Long-term memory is namespaced `("memories", user_id)`.** The namespace *is*
  the isolation boundary.
- **Safety-critical facts (allergies, conditions, medications) are fetched
  deterministically**, never via similarity search. A vector store must never
  decide whether to mention a penicillin allergy.

### Analytics

- **One implementation, two callers.** The agent's `get_sleep_summary` tool and
  the UI's `/api/sleep-summary` endpoint call the *same code*. If they diverge, a
  chart shows 6.2 hours while the chatbot says 6.8, and trust collapses.
- **Alert *decisions* are deterministic rules; only the *wording* is LLM.**
  `sleep < 6h for 3 nights` is a unit-testable rule that fires reliably.

### Detector

- **Never call an LLM in the telemetry path.** Continuous inference over a sensor
  stream for every user is catastrophically expensive and the wrong tool.
- **One shared feature module** used by both the detector and the training
  extraction job. Divergence causes training/serving skew — silent model
  degradation that takes weeks to diagnose.
- **Split evaluation data by user, never by window.** Same-user windows in train
  and test produce ~95% accuracy that collapses in production. Hold out entire
  people.
- **Never track accuracy.** >95% of windows are "nothing happening"; a model that
  always predicts nothing scores brilliantly and is useless. Track precision and
  recall per class.
- **Baselines exclude known event windows.** Otherwise the baseline drifts toward
  the thing being detected.
- **Everything is measured as deviation from personal baseline.** A resting HR of
  85 is alarming for an athlete and normal for someone else.

### Agent

- **`user_id` is written once at entry and never mutated.** Test this.
- **Populate `analytics` before any LLM runs.** The model reasons over computed
  facts, not raw data.
- **Never block a worker on human input.** On `interrupt()`, the checkpointer
  persists state and the worker is *released*; a resume job re-enters on any
  worker. Holding workers would exhaust the pool in minutes.
- **Hard budget caps per session** (tokens, tool calls, wall-clock, depth).
  Agents loop; one pathological session can cost hundreds of dollars unnoticed.
- **Guardrails run deterministically after the LLM.** Never let the LLM be the
  only thing deciding whether output is safe.
- **Not every sub-agent needs an LLM.** Document and therapy agents are mostly
  retrieval. Fewer LLM hops = faster, cheaper, easier to debug.
- **Analytics is a tool, not an agent.** It is deterministic; wrapping it in an
  LLM adds latency and error for nothing.

---

## Key Decisions Already Made

Do not re-litigate these without reading the rationale in the linked docs.

| Decision | Rationale |
|---|---|
| **No VM-per-session isolation** (unlike AWS AgentCore) | MicroVMs solve *untrusted code execution*. Our tools are bounded DB/API calls. Our actual risk is cross-tenant data in context — a logic bug no VM catches. [Platform HLD §7.1](docs/specs/2026-09-12-platform-hld.md) |
| **Webhooks for events, polling for telemetry** | A webhook per sensor batch = millions of calls/day, no batching, no backpressure. Polling batches naturally. |
| **`telemetry_raw` (short retention) + `telemetry_features` (long)** | 1 Hz × 8 channels × 10k users ≈ 864M rows/day. 1-min features ≈ 14M/day. Features are what ML and the detector consume. |
| **Detector is backend, not on-device** | On-device drains battery, needs app releases to update, dies when backgrounded. |
| **Detector targets 4–6 Tier A events, not all 15** | 200 events ÷ 15 types ≈ 13/type — not enough to generalise. Need 30–50+ per type across many people. |
| **Chat bypasses the job queue** | A human is waiting. Routing it behind ten thousand weekly reports makes it unusable. |
| **Two queue lanes from day one** | Retrofitting priority under load is painful; the upfront cost is negligible. |
| **Auto-detected events require confirmation** | Saves tokens on false positives, gives users control, and *every tap is a labelled training sample*. |

---

## Event Taxonomy

Detector effort is allocated by physical detectability. Full triage in
[PRD §8](docs/specs/2026-09-12-prd.md).

| Tier | Events | Detector target? |
|---|---|---|
| **A** | Sleep, exercise, alcohol, sauna, cold plunge | **Yes** |
| **B** | Eating, caffeine | Partial |
| **C** | Smoking, red light therapy, specific foods | **No** — manual/voice only |

Tier C events stay fully supported as manual input and remain valuable *agent*
context. The agent reasons over all events; the detector only auto-catches Tier A.

---

## Build Order

Each step is independently verifiable.

1. Supabase schema — tables, RLS, webhook config
2. **Gateway + queue + trivial logging worker** — proves the trigger path end to
   end before any intelligence exists. Highest-value first step.
3. Telemetry ingestion + feature computation + baselines
4. Analytics library + REST endpoints
5. Real agent
6. Scheduler — digests, reports, alerts
7. Document extraction
8. Voice — STT + backend intent parsing → same `events` table
9. Detector — shadow mode → candidates → ML

Steps 8 and 9 are additive by construction: both are new *writers* to `events`.

---

## Blocking Open Questions

Resolve before the corresponding implementation step:

1. **Which wearable(s)?** Exact channels, sampling rates, API access. Determines
   detector feasibility and storage sizing. *Blocks steps 3 and 9.*
2. **Which 4–6 events are the detector's initial targets?** *Blocks step 9.*
3. Which therapy machines expose integrable data, and how?
4. Genetics source — consumer export, clinical panel, or self-reported?
5. Regulatory posture: wellness positioning vs. regulated claims.
6. Retention policy for raw telemetry and features.

---

## Conventions

- Structured logs carry `user_id`, `session_id`, `event_id` on every line.
- Jobs are idempotent — keyed by `(event_id, status, attempt_reason)`. Webhooks
  retry.
- Feature definitions are versioned; a model records its feature version and
  refuses to load against a mismatch.
- Models are versioned and promoted only after beating a **frozen held-out user
  set**. Rollback must always be available.
- A failed run must never leave a half-finished prediction visible to the user —
  predictions are written transactionally at the persist step.
