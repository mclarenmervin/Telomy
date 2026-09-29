# Activity Analysis Agent — Design

**Status:** approved design, pending implementation plan
**Date:** 2026-09-29
**Supersedes:** nothing. Extends [Agent LLD](../../specs/2026-09-12-agent-lld.md)
and [Platform HLD](../../specs/2026-09-12-platform-hld.md).

## 1. Goal

When a user finishes a tracked activity (running, cycling, yoga, …), produce a
personalised, structured analysis of that session — what happened, what changed
against their own history, what went well, what to watch, what to try next —
and deliver it to the app without the user waiting on it.

The work runs entirely in the background. The user taps stop, carries on using
the app, and the report appears when it is ready.

This implements a scoped slice of Build Order step 5 (real agent) plus the
report-delivery half of step 6.

## 2. Scope

### In scope (Phase 1)

- Trigger on completed activity sessions.
- A separately deployed agent service with its own queue lane.
- Deterministic analysis of the session against the user's own history.
- A single LLM narration step producing a personalised report.
- Input and output guardrails.
- Short-term memory (Postgres checkpointer) keyed so a future chat can attach.
- Closure-bound memory tools.
- Hard budget caps with clean partial-result degradation.
- Durable, queryable storage of every report.

### Explicitly out of scope

| Excluded | Why | Lands in |
|---|---|---|
| Live / periodic mid-session reports | The phone holds samples in local memory and writes nothing to Supabase until the session ends. There is no mid-session signal to react to. | Needs a mobile-side change first |
| Auto-detection of events | Not wanted — the user taps the activity explicitly | — |
| Chat about a report | No chat entry point exists yet | Phase 3 |
| Semantic / vector memory | No embedding pipeline; deterministic queries are sufficient for this job | Phase 2 |
| Document, therapy, genetics **sub-agents** | Their *data* is reachable in Phase 1 via tools (§17.2) — a dedicated reasoning agent per domain is what waits, for the accuracy reason in §16.2 | Phase 2 |
| `web_search` | Untrusted external content in a health report; injection vector; competes with the 60s cap | Deferred, needs sanitisation |
| Re-running an analysis | Sessions are final once analysed | — |

## 3. Decisions

Each of these was decided deliberately; do not silently reverse one.

| # | Decision | Rationale |
|---|---|---|
| D1 | Trigger from `activity_sessions` INSERT, not `events` | Mobile already writes exactly one complete row at session end. Requires zero mobile change. |
| D2 | Accept this as a second trigger path alongside `events` | Deliberate, documented exception to P1 ("one event contract"). The alternative was a mobile change we do not want to block on. |
| D3 | Reuse `predictions.event_id` to hold the triggering row id | The column means "id of the row that triggered this"; `kind` disambiguates. **Correction to an earlier draft: one small migration IS required** — `predictions.kind` carries `check (kind in ('ack','analysis'))`, so `'activity_summary'` must be added to the constraint (`db/003_activity_summary.sql`). No new table or column. |
| D4 | Own deployable service (`activity-worker`), own queue lane | Independent failure domain, deploy and restart independently. Shares only `common/`. |
| D5 | Supervisor-shaped graph, but **one** reasoning node in Phase 1 | Evaluated explicitly for accuracy (§16) and chosen *because* it is more accurate, not merely cheaper. Splitting session-vs-trend analysis would prevent the cross-observation that matters most. `create_supervisor` accepts compiled agents, so this is additive later at zero rewrite cost. |
| D6 | OpenAI via `init_chat_model`; **delete** the custom `llm.py` wrapper | A hand-rolled provider Protocol duplicates a framework built-in. See §15. |
| D7 | 60s hard wall-clock cap → partial result | Normal runs finish well inside it; the cap exists to bound hangs and loops, not to hit routinely. |
| D8 | The numeric score is computed in Python, never by the LLM | A model-chosen number drifts between runs, which destroys comparability and makes trends meaningless. P2. |
| D9 | `thread_id = activity_sessions.id`, checkpoints retained | Makes Phase 3 chat resume the original thread with full context, no recomputation. |
| D10 | Phase 1 keeps service-role credentials | Status quo per CLAUDE.md. The RLS-enforced read path is a named Phase 2 hardening item, not a Phase 1 blocker. **See §12.** |
| D11 | Use LangChain/LangGraph built-ins wherever they exist; write custom code only for the deterministic health math | Every custom wrapper is code we own, test and maintain for no gain. Full mapping in §15. |
| D12 | The arithmetic path stays a plain `StateGraph`; only the narration step is a prebuilt agent | A ReAct agent that could choose whether to do the math would put the score at the model's discretion, breaking P2 and D8. |

## 4. Architecture

```
╔═ BOUNDARY 1 — USER-AUTHENTICATED ══════════════════════════════════╗
║  Mobile app (holds Supabase user JWT)                              ║
║      │ _stop() → INSERT activity_sessions                          ║
║      ▼                                                              ║
║  Supabase Postgres                                                  ║
║  RLS: with check (auth.uid() = user_id)   ◀── IDENTITY PROVEN HERE  ║
║  A row stamped with another user's id is impossible.               ║
╚══════╪══════════════════════════════════════════════════════════════╝
       │ DB webhook (INSERT), header: x-webhook-secret
       ▼
╔═ BOUNDARY 2 — SERVER-TO-SERVER, NO USER SESSION ═══════════════════╗
║  gateway  (only public surface)                                    ║
║    1. verify secret  ← BEFORE reading any field                    ║
║    2. then read user_id + session_id from verified payload         ║
║    3. enqueue, return 202                                          ║
║      ▼                                                              ║
║  Redis — lane: activity                                            ║
║      ▼                                                              ║
║  activity-worker  (own container)                                  ║
║                                                                     ║
║   ENTRY ─▶ LOAD CONTEXT ─▶ ANALYZE ─▶ NARRATE ─▶ GUARD ─▶ PERSIST  ║
║     │           │             │          │         │         │     ║
║  bind        scoped        pure       1 LLM   determin-   single   ║
║  user_id     loader       Python      call     istic      upsert   ║
║  (once)                  (all math)                                ║
║                                                                     ║
║  reads: scoped context loader     write: service-role, persist only ║
╚═════════════════════════════════════════════════════════════════════╝
       │ predictions row (kind='activity_summary')
       ▼
  Supabase Realtime ─▶ mobile app (subscribed; report appears)
```

## 5. Authentication and isolation

The agent never authenticates a human — by the time it runs there is no user
session in the path. Identity is **proven upstream and inherited**.

| Layer | Mechanism | Guarantees |
|---|---|---|
| Channel | Shared webhook secret, verified before any field is read | The payload genuinely came from Supabase |
| Identity | `user_id` from the verified payload, written to state once, never mutated | Trustworthy by transitivity: RLS already refused any forged `user_id` at insert |
| Tool | `user_id` **absent from every model-visible schema** | A prompt injection has no field to attack |
| Data | One scoped context loader; no node or tool builds a raw query | Exactly one auditable place where scoping can break |

### 5.1 Tools never see `user_id` — `ToolRuntime` + `context_schema`

`user_id` lives in the agent's **runtime context**, declared via `context_schema`
and read inside tools through the injected `ToolRuntime`. `ToolRuntime` is excluded
from the schema shown to the model, so there is no argument slot for an injection
to fill:

```python
@dataclass
class ActivityContext:
    user_id: str
    session_id: str

@tool
def get_past_sessions(activity_type: str, runtime: ToolRuntime[ActivityContext]) -> list[dict]:
    """Past sessions of this activity type for the current user."""
    return loader.past_activity_sessions(
        user_id=runtime.context.user_id,   # from runtime context, never the model
        activity_type=activity_type,
    )
```

`ToolRuntime` carries `state`, `context`, `config`, `store`, `stream_writer`,
`tool_call_id`, `tools` and `execution_info` — so tools reach everything they need
without any identity argument. A per-job closure remains an acceptable fallback,
but `ToolRuntime` is the framework-native mechanism and is preferred.

This is enforced by test, not convention: a test asserts no tool's generated
JSON schema contains a `user_id` (or any id-shaped) property. See §11.

### 5.2 One loader, not two

`ContextLoader` currently lives at `app/agent/context_loader.py` and is used by
one agent. It becomes shared by two, so it **moves to `app/common/context_loader.py`**
and gains activity methods. A second loader must not be created — the whole
value of the rule is that there is exactly one place to audit.

## 6. Data flow

1. Mobile inserts one complete row into `activity_sessions` (unchanged, ships today).
2. Supabase DB webhook fires `POST /webhooks/activity-sessions`.
3. Gateway verifies the secret, then enqueues
   `{user_id, session_id, activity_type}` on the `activity` lane and returns 202.
   Nothing in the request path blocks on analysis (P4).
4. `activity-worker` dequeues and invokes the graph.
5. Graph upserts one `predictions` row.
6. Realtime delivers it; the app renders it whenever it arrives.

## 7. Graph

| Node | LLM? | Work |
|---|---|---|
| `entry` | no | Validate payload shape; bind `user_id`, `session_id`; allowlist `activity_type`; initialise budget |
| `load_context` | no | Via scoped loader: this session, user profile, prior sessions of same type, prior reports |
| `analyze` | no | All arithmetic: aggregates, baseline, deltas, z-scores, score, data quality |
| `narrate` | **yes (1 call)** | A prebuilt `create_agent` invoked as a single node: tools, middleware, structured output and checkpointing all come from the framework. Turns computed facts into the report envelope |
| `guardrails` | no | Deterministic output checks |
| `persist` | no | Single idempotent upsert |

Phase 2 adds sub-agents between `load_context` and `narrate` by introducing a
supervisor fan-out; no existing node changes shape.

### 7.1 Raw samples never enter a prompt

`activity_sessions.samples` is roughly one sample per second — a 45-minute run
is ~2,700 objects. The `analyze` node reduces these to aggregates; **the LLM
sees only aggregates, never the sample array.** This is both a token-cost and a
correctness rule (P2: never ask a model to do arithmetic over sensor data).

### 7.2 Dynamic prompt

Built with the **built-in `@dynamic_prompt` middleware decorator**, which receives
the `ModelRequest` (carrying state and runtime) and returns the system prompt
string. No custom prompt plumbing:

```python
@dynamic_prompt
def activity_prompt(request: ModelRequest) -> str:
    ctx = request.runtime.context
    return render(name=ctx.display_name, analysis=request.state["analysis"], ...)
```

Content: the user's name from `user_preferences.profile`, activity type, computed
metrics, baseline comparison, prior-report continuity. No user-supplied text
reaches the prompt without sanitisation (§10.1).

### 7.3 Cold start

Comparative claims require history. With fewer than **3** prior sessions of the
same activity type, the report omits `score` and the comparison section, and
states plainly that it is still learning the user's baseline. Never fabricate a
baseline from one data point.

## 8. Report contract

Stable envelope, flexible body — so one frontend renderer serves every event
type and a new type never breaks the UI.

```json
{
  "schema_version": 1,
  "score_version": 1,
  "event_type": "running",
  "score": { "value": 72, "scale": 100, "label": "solid",
             "basis": "vs your last 5 runs" },
  "headline": "Your steadiest run this month — heart rate held 8 bpm lower at the same pace.",
  "sections": [
    { "id": "what_happened",  "title": "What happened",          "body": "…" },
    { "id": "what_changed",   "title": "What changed",           "body": "…" },
    { "id": "what_went_well", "title": "What went well",         "body": "…" },
    { "id": "watch_outs",     "title": "Worth watching",         "body": "…" },
    { "id": "improve",        "title": "What to try next time",  "body": "…" }
  ],
  "metrics": [
    { "key": "avg_hr", "label": "Average heart rate", "value": 142,
      "unit": "bpm", "baseline": 150, "delta": -8, "direction": "better" }
  ],
  "data_quality": "full",
  "history_used": { "sessions_compared": 5, "window_days": 30 },
  "data_gaps": [
    { "source": "lab_results", "status": "empty" },
    { "source": "documents",   "status": "unconfigured" }
  ]
}
```

Rules:

- `sections[]` **ids are fixed**; bodies are free text. Different event types
  fill the same slots with different content.
- `metrics[]` is one normalised shape regardless of which metrics exist.
- `score` is per event type and carries its own `basis`; scores are **not**
  comparable across types.
- `score_version` is recorded so a future scoring change stays interpretable.
- `headline` is the list-view line for browsing past days.
- **`data_gaps[]` makes absence machine-readable** (§17.2.1). It lets the UI invite
  the user to connect a missing source, gives the team a concrete list of what to
  populate next, and keeps absence *out* of the prose — no "you have no X" noise in
  every report. Gaps are mentioned in prose only when actionable.

Stored as: `predictions.analysis` = this object, `predictions.summary` =
`headline`, `kind = 'activity_summary'`.

## 9. Memory and thread model

| Tier | Mechanism | Phase |
|---|---|---|
| Short-term | LangGraph Postgres checkpointer, `thread_id = session_id` | 1 |
| History retrieval | Closure-bound deterministic queries | 1 |
| Long-term semantic | LangGraph `BaseStore`, namespace `("memories", user_id)` | 2 |

**On Mem0** (evaluated, not adopted): Mem0 is a capable memory layer — self-hostable,
pgvector-backed, with automatic LLM-driven fact extraction. Two reasons it is not
the Phase 1 choice, and a caution for Phase 2:

1. Semantic memory is Phase 2 by definition, so Mem0 is out of scope now regardless.
2. Mem0 scopes reads by a **`user_id` filter argument** (`search(q, filters={"user_id": …})`).
   LangGraph's `Store` scopes by **namespace tuple**, where the user is part of the key.
   For our threat model the namespace is structurally stronger — the same reason
   §5.1 keeps `user_id` out of tool arguments. Prefer `Store` unless Mem0's
   automatic extraction is specifically wanted.
3. Mem0's extraction step costs extra LLM calls per write, which competes with the
   60s budget (D7), and self-hosting it adds a service plus its own pgvector Postgres.

Checkpoints are **retained after the job completes**, not discarded. This is
what allows Phase 3 chat ("why was my heart rate lower that day?") to resume
the same thread with the loaded context and computed analysis already present.
Retention policy is an open item (§12).

Reports are durably queryable by `(user_id, created_at)` — already indexed —
so "show me three days ago" is a single scoped query returning the full
structured report, not just prose.

## 10. Guardrails

### 10.1 Input

- Webhook secret verified before any field is read.
- `activity_type` validated against an allowlist.
- `samples` size-capped and downsampled before use; malformed entries dropped.
- Any free text originating from user input is sanitised before entering a
  prompt and is treated as data, never instructions.

### 10.2 Output

Reuses the existing deterministic post-LLM module unchanged: blocks diagnostic
language, medication/dosage advice and treatment prescription; forces
escalation wording on clinically dangerous values; flags missing uncertainty on
correlational claims. Flags recorded in `predictions.guardrail_flags`.

## 11. Failure handling, budgets, idempotency

**Budgets** (Agent LLD §8.4), enforced per session:

All verified present in `langchain.agents.middleware` at the pinned versions (§15).

| Cap | Phase 1 value | Enforced by |
|---|---|---|
| LLM calls | `run_limit=2` | `ModelCallLimitMiddleware(run_limit=2, exit_behavior="end")` |
| Tool calls | `run_limit=8` | `ToolCallLimitMiddleware(run_limit=8, exit_behavior="end")` |
| Wall clock | 60s | job-level timeout — **ours**, no middleware provides this |
| Transient LLM failure | 2 retries, backoff | `ModelRetryMiddleware` |
| Provider degradation | secondary model | `ModelFallbackMiddleware` (optional) |

`exit_behavior="end"` is precisely the required semantics: the agent stops and
returns what it has rather than erroring, so the partial-result path below is the
framework's own behaviour rather than custom handling.

Exceeding any cap **terminates cleanly with a partial result**: the
deterministic sections and metrics are written with reduced `data_quality` and
an honest note that the narrative could not be completed. The user never sees
an empty screen forever, and the worker is always released.

**Idempotency.** Webhooks retry. The job is keyed `(session_id, kind)` and
persistence is a single upsert against the existing
`unique (event_id, kind)` constraint. A failed run never leaves a
half-written report visible — the row is written once, at the end.

## 12. Open items

1. **RLS-enforced read path (the "keycard").** Phase 1 uses service-role, which
   bypasses RLS, so tenant isolation rests on application code. A hardening
   step mints a short-lived per-job token (`sub = user_id`,
   `role = authenticated`) for **reads**, keeping service-role for the single
   `predictions` write — making the database reject wrong-user reads even if
   code is buggy. **Blocked on:** confirming whether the Supabase project uses
   the legacy shared HS256 secret or asymmetric signing keys.
2. **Checkpoint retention period.** Unbounded retention is the Phase 3 enabler
   but grows without limit.
3. **Score formula.** The precise composite and weights must be pinned in the
   implementation plan, with unit tests proving determinism.
4. **Prompt-cache parameter shape.** `ChatOpenAI` exposes `prompt_cache_options:
   dict[str, Any]`, while the docs describe a `prompt_cache_key`. Confirm the exact
   key at implementation time. OpenAI caching is implicit, so this is an
   optimisation, not a requirement.
5. **Checkpointer connection path.** `PostgresSaver` needs a direct Postgres
   connection (psycopg), whereas all current DB access goes through the Supabase
   REST client. This introduces a second connection path, needs the direct
   connection string, and Supabase's transaction-mode pooler is known to be
   awkward with prepared statements. Confirm the connection mode works before
   committing to `PostgresSaver`; a Redis-backed saver is a fallback since Redis
   is already in the stack.
6. **Dependency surface.** Phase 1 adds `langchain`, an OpenAI provider package,
   `langgraph-checkpoint-postgres` and `psycopg` to a requirements file that
   currently pins only `langgraph`. More built-ins means less code we own but a
   much larger tree on a fast-moving API. Pin exact versions.

## 13. Testing strategy

Mirrors the existing suite (`FakeSupabase`, `fakeredis`; no live services).

| Area | Must prove |
|---|---|
| Webhook | Rejects bad/missing secret before reading any field; enqueues on success; returns 202 |
| Handler | Dequeue → invoke; malformed job fails safely |
| Analysis | Aggregates, deltas, z-scores, data quality, and score are correct and **deterministic** on fixed input |
| Cold start | <3 prior sessions omits score and comparison |
| Prompt | Includes the user's name; **never** includes the raw sample array |
| Tools | **No tool schema exposes a `user_id`-shaped field** |
| Isolation | Another user's session produces nothing |
| State | `user_id` is never mutated after entry |
| Guardrails | Unsafe narration is replaced; flags recorded |
| Budget | Cap breach yields a partial result, not a hang |
| Persist | Upsert is idempotent under repeated delivery |
| Report | Envelope validates; unknown event type still renders required slots |
| **Absence contract** | `empty` vs `unconfigured` vs `error` are distinct; an `unconfigured` result is **never** narrated as the user lacking data (§17.2.1) |
| **`data_gaps`** | Populated from tool statuses; absent sources appear once, not repeated in prose |
| **Insight rules** | Same input fires the same rules every time; each rule unit-tested independently of the LLM (§17.4) |
| **Argument clamping** | Out-of-range `days`/`limit`/`window_days` are clamped, not passed through; `kind` rejected unless allowlisted (§18.3) |
| **Result size caps** | A large result set is truncated before reaching the prompt |
| **Payload distrust** | `samples` are re-read from the row by id, not taken from the webhook payload; a payload `user_id` that does not match the row is rejected (§18.2) |
| **Numeric fidelity** | Figures in prose reconcile against computed metrics (§18.4) |

## 14. Phasing

- **Phase 1 (this design)** — trigger → analysis → narration → guardrails →
  stored structured report. Complete and shippable on its own.
- **Phase 2** — RLS-enforced reads; semantic long-term memory and `REFLECT`
  write-back; document/therapy sub-agents as their tables land.
- **Phase 3** — chat entry point, resuming the retained thread per report; HITL
  interrupts.

## 15. Framework usage — verified against installed packages

Everything below was confirmed by installing the packages and introspecting them,
not read from documentation. **Verified 2026-09-29** at:

```
langchain 1.4.3 · langchain-core 1.6.5 · langchain-openai 1.6.6
langgraph 1.2.12 · langgraph-prebuilt 1.1.0
langgraph-checkpoint 4.2.0 · langgraph-checkpoint-postgres 3.1.2
openai 3.20.0 · psycopg 3.3.6
```

`requirements.txt` already pins `langgraph==1.2.12`, which **is** the current
latest. The gap is not the version — it is that the code imports only `StateGraph`
and uses none of the rest.

### 15.1 Python version trap — read this first

LangChain 1.x and LangGraph 1.x require **Python ≥ 3.10**. On Python 3.9, pip
silently resolves to `langchain 0.3.30` / `langgraph 0.6.11`, where
`create_agent` and `langchain.agents.middleware` **do not exist** — the failure
looks like a missing feature, not a version problem. This was hit during research.

`docker/Dockerfile.worker` uses `python:3.12-slim`, so containers are fine. macOS
system `python3` is 3.9 — local venvs must be created with an explicit 3.12
interpreter.

### 15.2 What replaces what

| Concern | Verified API | Replaces |
|---|---|---|
| Chat model | `from langchain_openai import ChatOpenAI` | the custom `LLM` Protocol + `OpenAILLM` — **delete `app/agent/llm.py`** |
| Agent construction | `create_agent(model, tools, *, system_prompt, middleware, response_format, state_schema, context_schema, checkpointer, store, interrupt_before, interrupt_after)` | a hand-built tool-calling loop |
| Identity injection | `context_schema=` + `ToolRuntime.context` | closures / custom arg filtering |
| Dynamic prompt | `@dynamic_prompt` middleware decorator | custom prompt assembly plumbing |
| Structured report | `response_format=<PydanticModel>` | hand-parsing JSON out of prose |
| LLM-call budget | `ModelCallLimitMiddleware(run_limit, thread_limit, exit_behavior)` | custom counters |
| Tool-call budget | `ToolCallLimitMiddleware(tool_name, run_limit, thread_limit, exit_behavior)` | custom counters |
| Retry / fallback | `ModelRetryMiddleware`, `ModelFallbackMiddleware`, `ToolRetryMiddleware`, `ToolErrorMiddleware` | custom error handling |
| Context trimming | `SummarizationMiddleware`, `ContextEditingMiddleware` | custom truncation |
| Threads / short-term memory | `PostgresSaver.from_conn_string(conn, pipeline=False)`, `AsyncPostgresSaver` | custom session storage |
| Long-term memory (Ph 2) | `PostgresStore`; `store.put(namespace, key, value, index, ttl)` / `store.search(prefix, query=, filter=, limit=)` | custom retrieval — **and Mem0 (§9)** |
| HITL (Ph 3) | `HumanInTheLoopMiddleware(interrupt_on=…)`, `interrupt(value, response_schema=)` | custom approval plumbing |
| Agent handoff (Ph 2) | `Command(goto=…, update=…, graph=Command.PARENT)` | custom routing |
| Streaming (Ph 3) | stream modes `values · updates · checkpoints · tasks · debug · messages · custom` | custom token plumbing |

Custom middleware, where ever needed, uses the built-in hooks:
`before_agent`, `before_model`, `wrap_model_call`, `after_model`,
`wrap_tool_call`, `after_agent`.

### 15.3 Where built-ins do *not* cover us

Honest gaps — these stay custom:

- **Medical-safety guardrails.** No built-in judges medication or diagnostic
  language. `PIIMiddleware` covers only `email`, `credit_card`, `ip`,
  `mac_address`, `url` (strategies `block · redact · mask · hash`), none of which
  are clinical. Our §10.2 rules remain ours. A custom `detector` callable could
  extend `PIIMiddleware` later if we want identifier redaction.
- **Wall-clock cap.** No middleware enforces elapsed time; the 60s bound is a
  job-level timeout we implement.
- **All health analytics and the score.** Deliberately ours (D8, D12).
- **Supervisor / swarm.** Separate packages (`langgraph-supervisor 0.0.31`,
  `langgraph-swarm 0.1.0`), not installed. Comparison and verdict in §16.

### 15.4 Prompt caching

OpenAI caching is **implicit** — cost savings apply automatically on prefix hits
with no configuration. `ChatOpenAI` additionally exposes
`prompt_cache_options: dict[str, Any] | None` for explicit control, plus
`stream_usage` and a `cache` field for a full response cache.

Practical consequence for prompt design: put the **stable** content first (role
instructions, report-format rules) and the **variable** content last (this
session's metrics), so the cacheable prefix is as long as possible. Exact
parameter shape is open item §12.4.

### 15.5 Module layout

Adopt the convention from LangGraph's application-structure guide *within* the new
package, rather than restructuring the repo — healthagent is a multi-service
backend (gateway + workers), not a single LangGraph app, so its existing
`app/<service>/` split stays:

```
app/
├── activity_agent/
│   ├── __init__.py
│   ├── agent.py        # graph construction (the "agent.py" of the guide)
│   ├── state.py        # state + context_schema dataclass
│   ├── nodes.py        # deterministic nodes
│   ├── tools.py        # ToolRuntime-based memory tools
│   ├── prompts.py      # @dynamic_prompt
│   └── report.py       # Pydantic response_format model
├── activity_worker/    # deployable consumer
├── analytics/
│   └── activity_analysis.py
└── common/
    ├── context_loader.py   # moved here (§5.2)
    └── checkpointer.py
```

**`langgraph.json` is optional and not required for Phase 1.** It exists to
declare graphs for LangGraph Platform deployment (`{"dependencies": […],
"graphs": {"name": "./path.py:var"}, "env": "./.env"}`). We deploy our own worker
on Railway, so it buys nothing operationally — but adding it enables
`langgraph dev` and LangGraph Studio for local graph debugging, which is worth
having. Add it for the developer tooling, not for deployment.

### 15.6 Verify before building

These APIs move quickly — `create_agent` superseded an earlier prebuilt, and
`ToolRuntime` superseded `InjectedState` as the idiomatic injection point (both
still exist). The implementation plan should re-run this introspection against the
pinned versions as its first task, rather than trusting this table.

## 16. Multi-agent: supervisor vs swarm, and why Phase 1 is single-agent

Researched by installing both packages and introspecting them (2026-09-29):
`langgraph-supervisor 0.0.31`, `langgraph-swarm 0.1.0`.

### 16.1 The difference

| | Supervisor | Swarm |
|---|---|---|
| Shape | Centralised hierarchy | Decentralised peers |
| Routing | A supervisor **LLM** routes — `create_supervisor(agents, *, model=…)` | No central brain — **no `model` parameter exists** |
| Control | Sub-agent → hands back to supervisor (`add_handoff_back_messages`) | A hands off directly to B; B takes over |
| Key state | — | `SwarmState.active_agent` |
| Entry | Always the supervisor | `default_active_agent`, then whoever is active |
| Extra cost | +1 LLM call per routing decision | No routing hop |

`SwarmState.active_agent` is the decisive detail: swarm exists so that **the
user's next message resumes with whichever agent took over**. A one-shot
background job has no next turn, so that machinery is inert.

**Verdict: swarm is a chat pattern — irrelevant until Phase 3 at the earliest.
If a multi-agent topology is ever added here, it is supervisor.**

Caveats on the package: it sits at 0.0.31 against langgraph 1.2.12, and its
signature still uses the older `prompt` / `pre_model_hook` / `post_model_hook`
idiom rather than the `middleware` system (§15.2). Fan-out can be hand-rolled with
`Command(goto=…)` if that mismatch becomes a problem.

### 16.2 Why Phase 1 is single-agent — an accuracy argument, not a cost one

1. **Accuracy does not live in the topology.** Every number is computed in Python
   (P2, D8). Orchestration cannot make arithmetic more correct; the ceiling is set
   by the analytics code and the data.
2. **Splitting analysts destroys the most valuable insight.** A session analyst
   sees this run but not the multi-week arc; a trend analyst sees the arc but not
   this run. Neither can say *"this run bucked your declining trend"* — the
   cross-observation exists only when one reasoner holds both at once. Splitting
   discards it, then asks a supervisor to reassemble it from two partial
   narratives.
3. **Each hop is a drift opportunity.** More LLM hops means more chances to
   paraphrase a number wrongly or drop a caveat, and when two sub-narratives
   conflict the supervisor has no ground truth to arbitrate with.
4. **Routing non-determinism varies report shape** between runs of the same
   session, which reads as unreliability in a health product.
5. **Nothing is lost by waiting.** `create_supervisor(agents=[…])` takes compiled
   agents, so the Phase 1 agent becomes a sub-agent later unchanged.

**Multi-agent becomes the accuracy win when inputs are heterogeneous and need
different competencies** — reading a lab PDF versus correlating therapy sessions
versus weighing research evidence.

**Correction to an earlier draft of this spec:** those tables *do* exist. They are
created in the mobile migration by a `do $$ … loop` with
`execute format('create table if not exists …')`, which a `grep "^create table"`
misses. `lab_results`, `therapy_sessions`, `genetic_records`, `medications`,
`meals`, `workouts`, `hydration_logs`, `environment_logs` and others are all
present — sharing one generic shape (`title`, `recorded_at`, `notes`,
`fields jsonb`), not the typed schema the Agent LLD envisioned.

This does not change the decision, but it changes the reason. The argument for a
single agent rests on point 2 above — splitting analysts destroys the
cross-observation — not on data availability. Phase 1 reaches all of this data
through tools (§17.2); what waits is a dedicated *reasoning agent* per domain.
If these tables turn out to hold substantial data, a clinical-context specialist
becomes defensible sooner than otherwise.

### 16.3 What accuracy actually depends on in Phase 1

- Deterministic analytics and score, unit-tested for determinism (§13)
- `response_format` Pydantic schema pinning output shape so it cannot drift
- Raw samples never in the prompt (§7.1) — reasoning over aggregates, not 2,700 points
- The cold-start rule, ≥3 prior sessions (§7.3)
- Deterministic post-LLM guardrails (§10.2)
- **The single agent receiving both session and trend data**, so cross-observations
  are possible
- Low temperature; `ModelRetryMiddleware` so transient failures do not degrade into
  partial reports

## 17. Tools

### 17.1 The rule

**A required input is never a tool.** The model can decline to call a tool, so
anything needed for every report is loaded into the prompt; tools exist only for
what the model might *optionally* want.

**Prompt-loaded, deliberately not tools:** this session's computed stats, score and
`data_quality`; baseline and trend across recent same-type sessions (both together,
so cross-observations are possible — §16.2); profile basics; and **safety facts
(medications, conditions), which CLAUDE.md requires be fetched deterministically
and always included** — a skippable tool is the wrong mechanism for those.

### 17.2 The tool set

| Tool | Purpose |
|---|---|
| `get_past_sessions(activity_type\|None, limit, window_days)` | Deeper or wider history; cross-type lookups. Per-session aggregates, **never raw samples** (§7.1) |
| `get_logs(kind, days)` | One tool over every generic-shape table via an allowlisted `kind`: `lab_results`, `therapy_sessions`, `genetic_records`, `environment_logs`, `meals`, `workouts`, `hydration_logs`, `plans`, `progress_checkins`, `consultations`, `timeline_events`. **The correlation engine.** `medications` excluded — loaded deterministically as a safety fact |
| `get_documents(kind, limit)` | Object-storage documents. **No storage backend is wired yet** (verified: no R2/S3/Supabase Storage in either codebase), so this returns `unconfigured` until one exists. Returns metadata and extracted text only — never raw file bytes, which are an injection vector (§10.1) |
| `get_past_reports(activity_type, limit)` | Continuity with previously given advice |
| `get_measurements(measurement_type, days)` | Typed rows from `health_measurements` (value, unit, quality) |
| `get_daily_snapshot(days)` | `wearable_daily_reports.snapshot` — sleep/readiness around the session |
| `compare_window(window_days)` | **Deterministic recompute** of baseline deltas over a different window — analytics as a tool (Agent LLD §4.1), so the model never does arithmetic itself |

All take no `user_id` (§5.1), route through the one scoped loader (§5.2), and never
return raw sample arrays.

**Full coverage is achieved by widening one allowlist, not by adding twelve tools.**
Every clinical table shares an identical generic shape, so separate tools would be
near-duplicates. Tool schemas are re-sent on *every* model call, making redundant
tools a permanent token tax and extra room to wander, for identical capability.
`LLMToolSelectorMiddleware(max_tools=…, always_include=[…])` is available as a
built-in should the surface still grow too wide.

### 17.2.1 Absence is a first-class result

Tools never gate on whether data exists — they always exist and report what they
found. Critically, they distinguish **two things that are easy to conflate**:

```python
{"status": "ok",           "items": [...]}
{"status": "empty",        "items": []}                      # genuine absence
{"status": "unconfigured", "reason": "no storage backend"}    # could NOT look
{"status": "error",        "reason": "..."}
```

`empty` means the user genuinely has no such data. `unconfigured` / `error` mean we
could not look. **Collapsing these is the most damaging failure mode in the system:**
a broken credential would read as "you have no lab data", and the agent would
confidently narrate around data that actually exists.

Hard prompt rule: `unconfigured` and `error` must **never** be narrated as the user
lacking something.

### 17.3 Considered and declined

| Tool | Why not |
|---|---|
| `web_search` | Untrusted content in a health context, an injection vector, and latency against the 60s cap. Deterministic insight rules (§17.4) serve the need safely |
| Memory **writes** | Phase 2 with `REFLECT`. Writes carry more isolation risk than reads; pointless before there is a reader |
| Ask-the-user | No human is present in a background job |

### 17.4 Insight rules — the `improve` section must not be freelanced

Every other report section traces to data. `improve` would otherwise trace only to
the model's parametric knowledge: unverifiable, inconsistent between runs, and
quietly risky in a health product.

Apply the pattern this codebase already uses for alerts — *"alert **decisions** are
deterministic rules; only the **wording** is LLM."* A small unit-tested rules layer
decides **which** observations fire; the LLM only phrases them. Same input, same
rules fired, every time.

## 18. Edge cases

### 18.1 Data shape

| Case | Required handling |
|---|---|
| **Ragged samples** — mobile omits null keys, so fields vary per sample | Aggregate per-field presence; never assume uniform rows |
| **Empty `samples`** (ring dropped) | Still produce a useful report from duration; `data_quality='none'` |
| **Forgot to stop** — a 14-hour "run" | Outlier-reject from baselines, or it poisons every future comparison |
| **Accidental tap** — near-zero duration | Minimum-duration threshold below which no report is generated |
| **`activity_type='other'`** | Heterogeneous; treat as no baseline rather than a meaningless one |
| **Backdated upload** | Must not be narrated as "your latest run" |

### 18.2 Infrastructure

| Case | Required handling |
|---|---|
| **Payload size** — ~10,800 samples for a 3-hour session | **Do not trust the webhook payload for `samples`; re-read the row by id.** This also verifies the row belongs to the claimed `user_id` rather than trusting a payload field |
| **Bulk sync storm** — offline phone flushes six sessions at once | Per-user throttling or coalescing, or six concurrent agent runs and a cost spike |
| **Account deleted before processing** | Cascade removes the row; loader returns nothing; exit cleanly and write nothing |
| **Duplicate delivery** | Idempotent upsert on `(event_id, kind)` (§11) |

### 18.3 Model-supplied arguments

- **Clamp every numeric argument** server-side — `days`, `limit`, `window_days`.
  An unbounded `days=100000` is both a slow query and a token blowout.
- **Cap result size, not just `limit`** — a thousand `meals` rows would blow the
  context regardless of the requested limit.
- **Enforce `kind` against the allowlist in code**, not only via the schema.

### 18.4 Output fidelity

- **Numeric cross-check.** Figures in the prose should be verifiable against the
  computed metrics. A cheap deterministic check catches the most damaging failure
  mode: a confidently-wrong number.
- **`data_quality` gates claim strength.** At `data_quality='none'`, confident
  physiological claims must be *impossible*, not merely discouraged.

## 19. Module layout and graph flow

### 19.1 Target layout

`★ new · ✎ changed · ⇄ moved · ✗ deleted`

```
healthagent/
├── langgraph.json                    ★ optional — enables `langgraph dev` / Studio
├── requirements.txt                  ✎ +langchain, langchain-openai,
│                                        langgraph-checkpoint-postgres, psycopg
├── docker-compose.yml                ✎ + activity-worker service
├── docker/Dockerfile.activity-worker ★
├── db/003_activity_summary.sql       ★ extend predictions.kind CHECK (D3)
├── app/
│   ├── common/
│   │   ├── config.py                 ✎ + DB conn string, budget settings
│   │   ├── context_loader.py         ⇄ from app/agent/ — now shared (§5.2)
│   │   └── checkpointer.py           ★ PostgresSaver factory
│   ├── analytics/
│   │   ├── activity_analysis.py      ★ aggregates, baseline, deltas, score
│   │   └── insight_rules.py          ★ deterministic advice decisions (§17.4)
│   ├── event_agent/                  ⇄ renamed from app/agent/ (two agents now)
│   │   ├── guardrails.py             ← reused unchanged by the activity agent
│   │   └── llm.py                    ✗ deleted — replaced by ChatOpenAI (§15.2)
│   ├── activity_agent/               ★ LangGraph app-structure convention (§15.5)
│   │   ├── agent.py                  # graph assembly
│   │   ├── state.py                  # ActivityState + ActivityContext
│   │   ├── nodes.py                  # deterministic nodes
│   │   ├── tools.py                  # 7 ToolRuntime tools + absence envelope
│   │   ├── prompts.py                # @dynamic_prompt
│   │   ├── report.py                 # Pydantic response_format model
│   │   └── persist.py
│   ├── activity_worker/              ★ separate deployable (D4)
│   ├── gateway/activity_webhooks.py  ★
│   └── gateway/main.py               ✎ mount activity router
└── tests/                            ✎ ~10 new modules mirroring the above
```

The `app/agent/` → `app/event_agent/` rename is optional but recommended: with two
agents, `agent/` beside `activity_agent/` reads badly. It touches imports and a few
test files.

### 19.2 Graph flow

```
  Supabase: INSERT activity_sessions
       │  DB webhook + x-webhook-secret
       ▼
  gateway/activity_webhooks.py
    verify secret ──► reject (before any field is read)
    enqueue {user_id, session_id} ──► 202
       │
       ▼  Redis lane: activity
  activity_worker ──► invoke graph (thread_id = session_id)

╔════════════ StateGraph — ours, deterministic ════════════╗
║  entry          bind user_id+session_id into context;    ║
║    │            allowlist activity_type; init budget     ║
║    ▼                                                     ║
║  load_session   re-read row BY ID scoped to user_id      ║
║    ├──► END     missing row · user mismatch · too short  ║
║    │            →  write nothing                         ║
║    ▼                                                     ║
║  load_context   profile · safety facts (always) ·        ║
║    │            baseline · trend · prior headline;       ║
║    │            records data_gaps{empty|unconfigured}    ║
║    ▼                                                     ║
║  analyze        PURE PYTHON — ragged-safe aggregates,    ║
║    │            outlier-rejected baseline, deltas, z,    ║
║    │            score (omitted if <3 sessions), quality  ║
║    ▼                                                     ║
║  insight_rules  PURE PYTHON — which observations fire    ║
║    ▼                                                     ║
║  ┌────────── narrate = create_agent(...) ───────────┐    ║
║  │ ChatOpenAI · @dynamic_prompt                     │    ║
║  │ response_format=ActivityReport (Pydantic)        │    ║
║  │ 7 tools, ToolRuntime-bound, no user_id           │    ║
║  │ middleware: ModelCallLimit(2) · ToolCallLimit(8) │    ║
║  │             · ModelRetry                         │    ║
║  │ sees ONLY computed facts, never raw samples      │    ║
║  └───────────────────┬──────────────────────────────┘    ║
║    budget hit/no LLM │                                   ║
║       ┌──────────────┴──── partial path ────┐            ║
║       ▼                                     ▼            ║
║  verify        numeric fidelity vs        (deterministic  ║
║    │           metrics; quality gates      sections only)║
║    ▼           claim strength               │            ║
║  guardrails    deterministic medical safety ◄┘           ║
║    ▼           (reused module, unchanged)                ║
║  persist       ONE idempotent upsert                     ║
║                event_id=session_id, kind=activity_summary║
╚══════════════════════════════════════════════════════════╝
       │  checkpoint RETAINED (thread_id = session_id)
       ▼      └─► Phase 3 chat resumes this thread
  predictions ──► Supabase Realtime ──► mobile app
```

### 19.3 Invariants the flow enforces

1. **Exactly one node calls a model.** Everything before `narrate` is arithmetic;
   everything after is deterministic checking. This is what keeps the score
   comparable across runs (D8).
2. **Two exits write nothing.** A missing row, a user mismatch, or an
   accidental-tap session yields no report rather than a bad one.
3. **The partial path always reaches `persist`.** A budget breach or a missing API
   key still produces the deterministic sections — never an empty screen (§11).

## 20. Implementation notes (as built, 2026-09-29)

Decisions taken during implementation that a future change should not silently reverse.
Corrections to earlier sections of this document are marked.

### 20.1 Corrections to this spec

- **§D3 said "no schema migration".** Wrong: `predictions.kind` carries a CHECK
  constraint, so `db/003_activity_summary.sql` was required.
- **§16.2 said the clinical tables do not exist.** Wrong: `lab_results`,
  `therapy_sessions`, `genetic_records`, `medications` and others are created by a
  `do $$ … loop` in the mobile migration. The single-agent decision stands on the
  cross-observation argument alone.
- **§15.2 said to delete `app/agent/llm.py`.** Kept: the legacy event agent depends on
  it, and migrating that agent is not part of this feature. The activity agent uses
  `ChatOpenAI` directly. The `app/agent` → `app/event_agent` rename was likewise skipped.

### 20.2 Safety thresholds are v1 and want clinical review

`app/activity_agent/agent.py` escalates only on **SpO2 < 90** or **max HR > 200**. The
event agent's `HEART_RATE_HIGH = 150` must not be reused here: a mean of 150–175 bpm is
ordinary for a tempo run, and reusing it put a chest-pain warning on every hard workout —
repeated in all five sections, because the reused module's escalation does not depend on
the text. The escalation line is appended **once**, to `watch_outs`.

`app/analytics/insight_rules.py` thresholds (`HR_ELEVATED_DELTA = 15`,
`SPO2_WATCH_MIN = 92`, `SHORT_SESSION_RATIO = 0.7`) are also v1 placeholders.

### 20.3 Two duration gates, not one

- `is_plausible_session` (120s–6h) decides **baseline eligibility** only.
- `is_analyzable` (≥30s) decides **whether to report at all**.

Conflating them meant a genuine seven-hour ride — the session a user most wants
explained — produced silence, and a 90-second mobility block produced nothing. A session
beyond 6h is still reported, with `duration_suspect: true`.

### 20.4 `verify_numbers` tolerance is deliberate

`_allowed_numbers` admits the truncated, rounded and one-decimal forms of every computed
value, and both `floor(s/60)` and `round(s/60)` for duration. This is not laxity: the
prompt presents `round(s/60)`, so allowing only the floor flagged a correct restatement on
roughly half of real sessions, and a flag that fires on healthy reports carries no signal.

Conversely, a small number **carrying a unit** ("3 bpm lower") is never exempted, because
an invented delta is the likeliest fabrication in this domain. Bare small counts
("3 sessions") still are.

### 20.5 The fallback path must stay visible

When no API key is configured, narration throws, or a budget cap ends the run, the report
is deterministic prose, `data_quality` is downgraded to `partial`, and
`narration_incomplete` is recorded in `guardrail_flags`. Without this, an expired API key
in production yields terse reports stamped `full` with no flags — invisible in dashboards
and to the user.

### 20.6 The wall-clock deadline is ours

No middleware enforces elapsed time. `app/activity_worker/handlers.py` runs the graph on a
helper thread and abandons the wait at `wall_clock_seconds`, so a hung model or database
call cannot stall the single-threaded lane. The thread is orphaned deliberately.

Failures re-enqueue once (`MAX_ATTEMPTS = 2`) — Supabase already received its 202 and will
never retry on our behalf, so without this a transient blip lost the report silently.

### 20.7 Known gaps, deliberately deferred

- The history window uses `datetime.now()`, so replaying a session on a different day can
  select a different baseline set. Anchor to `session["started_at"]` to make the
  determinism guarantee in D8 total.
- FastAPI validates the webhook body before the handler's secret check, so a malformed
  unauthenticated request receives 422 with schema detail rather than 401. No user data is
  touched. Matches the pre-existing events webhook.
- The report envelope carries no duration field; the UI must read it from prose.
- User-authored text (display name, `notes`, `fields`) is labelled as data in the prompt
  but not structurally delimited. Blast radius is the user's own report.
- ~~`build_checkpointer` holds one connection open for process lifetime with no
  reconnect.~~ **Fixed 2026-09-30, and it was not minor.** Live testing reproduced it:
  after roughly thirty minutes idle, Supabase's pooler closed the connection and *every*
  subsequent job failed with `psycopg.OperationalError: consuming input failed: SSL error:
  unexpected eof while reading` inside the checkpointer's `get_tuple`, until the worker
  was restarted. `build_checkpointer` now uses a `ConnectionPool` with
  `check=ConnectionPool.check_connection`, which validates a connection on checkout and
  replaces a dead one, plus TCP keepalives. The pool replicates what
  `from_conn_string` sets (`autocommit`, `dict_row`, `prepare_threshold=0`).
- No per-user throttling: a bulk sync of six sessions runs six agent invocations.
