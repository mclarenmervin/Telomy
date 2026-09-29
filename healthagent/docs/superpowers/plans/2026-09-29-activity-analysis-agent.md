# Activity Analysis Agent — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a user finishes a tracked activity, produce a personalised structured
report in the background and deliver it to the app via Supabase Realtime.

**Architecture:** A Supabase DB webhook on `activity_sessions` INSERT hits the gateway,
which verifies a shared secret and enqueues onto a dedicated Redis lane. A separately
deployed `activity-worker` runs a LangGraph `StateGraph` whose nodes are deterministic
Python except one `create_agent` narration step; the result is upserted into
`predictions` where the app is already subscribed.

**Tech Stack:** Python 3.12, LangGraph 1.2.12, LangChain 1.4.3, langchain-openai 1.6.6,
`langgraph-checkpoint-postgres` 3.1.2, FastAPI, Redis, supabase-py, pytest, fakeredis.

**Spec:** [2026-09-29-activity-analysis-agent-design.md](../specs/2026-09-29-activity-analysis-agent-design.md)

## Global Constraints

- **Python ≥ 3.10 required.** On 3.9 pip silently installs langchain 0.3.x / langgraph 0.6.x
  where `create_agent` and `langchain.agents.middleware` do not exist (spec §15.1).
  Containers use `python:3.12-slim`; local venvs must be created with an explicit 3.12+.
- Pinned versions: `langgraph==1.2.12`, `langchain==1.4.3`, `langchain-openai==1.6.6`,
  `langgraph-checkpoint-postgres==3.1.2`, `psycopg==3.3.6`.
- **No tool may accept `user_id` (or any id) as a parameter.** Identity comes from
  `ToolRuntime.context` only (spec §5.1).
- **All user data is read through the single `ContextLoader`.** No node or tool builds a
  raw query (spec §5.2).
- **Raw `samples` never enter a prompt.** The LLM sees computed aggregates only (spec §7.1).
- **The score is computed in Python, never by the LLM** (spec D8).
- Budgets: 60s wall clock, `ModelCallLimitMiddleware(run_limit=2)`,
  `ToolCallLimitMiddleware(run_limit=8)`, both `exit_behavior="end"` (spec §11).
- Every log line carries `user_id` and `session_id`.
- Persistence is one idempotent upsert on `(event_id, kind)`; a failed run leaves no
  half-written report visible (spec §11).
- `unconfigured` / `error` tool results must **never** be narrated as the user lacking
  data (spec §17.2.1).

## Review Focus

Five failure modes the spec implies; each has its test added to the owning task.

1. **Ragged samples** — mobile omits null keys, so `hrv` is present in some samples and
   absent in others. Aggregates must compute per-field, not assume uniform rows. → Task 4
2. **`unconfigured` mistaken for absence** — a missing storage backend must not read as
   "you have no lab results". → Task 6
3. **Forgot-to-stop session** — a 14-hour "run" must be outlier-rejected from the baseline
   rather than silently poisoning every future comparison. → Task 4
4. **Payload `user_id` ≠ row `user_id`** — the webhook payload must not be trusted; the row
   is re-read by id scoped to the claimed user, and a mismatch writes nothing. → Task 8
5. **Model cites a number absent from the metrics** — prose figures must reconcile against
   computed values, or the report is downgraded. → Task 9

---

## File Structure

| File | Responsibility |
|---|---|
| `db/003_activity_summary.sql` | Extend `predictions.kind` CHECK to allow `activity_summary` |
| `app/common/config.py` | ✎ add `supabase_db_url`, budget settings |
| `app/common/context_loader.py` | ⇄ moved from `app/agent/`; gains activity reads + absence envelope |
| `app/common/checkpointer.py` | `PostgresSaver` factory with a documented fallback |
| `app/analytics/activity_analysis.py` | Aggregates, baseline, deltas, score — pure |
| `app/analytics/insight_rules.py` | Which observations/advice fire — pure |
| `app/activity_agent/state.py` | `ActivityState`, `ActivityContext` |
| `app/activity_agent/report.py` | Pydantic `ActivityReport` for `response_format` |
| `app/activity_agent/tools.py` | 7 `ToolRuntime` tools |
| `app/activity_agent/prompts.py` | `@dynamic_prompt` builder |
| `app/activity_agent/nodes.py` | Deterministic nodes |
| `app/activity_agent/agent.py` | Graph assembly |
| `app/activity_worker/{main,handlers}.py` | Deployable queue consumer |
| `app/gateway/activity_webhooks.py` | `POST /webhooks/activity-sessions` |
| `docker/Dockerfile.activity-worker` | Container for the new worker |

---

### Task 1: Dependencies, config, and model verification

Surfaces the two external unknowns immediately: the exact model id, and whether the
pinned stack installs at all.

**Files:**
- Modify: `requirements.txt`
- Modify: `app/common/config.py`
- Test: `tests/test_config.py`

**Interfaces:**
- Produces: `Settings.supabase_db_url: str | None`, `Settings.llm_model: str`,
  `Settings.max_llm_calls: int`, `Settings.max_tool_calls: int`,
  `Settings.wall_clock_seconds: int`

- [ ] **Step 1: Confirm the local interpreter is 3.12+**

```bash
python3.12 -V || python3.11 -V   # must print 3.1x, NOT 3.9
```
If only 3.9 is available, stop and install 3.12 — every later task depends on it.

- [ ] **Step 2: Pin the new dependencies**

Append to `requirements.txt`:
```
langchain==1.4.3
langchain-openai==1.6.6
langgraph-checkpoint-postgres==3.1.2
psycopg==3.3.6
psycopg-pool==3.3.3
```

- [ ] **Step 3: Install and verify the 1.x imports exist**

```bash
pip install -r requirements.txt
python -c "
from langchain.agents import create_agent
from langchain.agents.middleware import (ModelCallLimitMiddleware,
    ToolCallLimitMiddleware, ModelRetryMiddleware, dynamic_prompt)
from langchain.tools import tool, ToolRuntime
from langchain_openai import ChatOpenAI
from langgraph.checkpoint.postgres import PostgresSaver
print('all imports OK')
"
```
Expected: `all imports OK`. An ImportError here means Python 3.9 — see Step 1.

- [ ] **Step 4: Discover the real low-cost model id**

Do not guess the id. Ask the API:
```bash
python -c "
import os
from openai import OpenAI
ids = sorted(m.id for m in OpenAI(api_key=os.environ['OPENAI_API_KEY']).models.list())
print('\n'.join(i for i in ids if 'mini' in i or 'nano' in i))
"
```
Pick the cheapest current mini/nano chat model from the printed list and set it in `.env`:
```
LLM_MODEL=<id from the list>
LLM_PROVIDER=openai
```

- [ ] **Step 5: Write the failing config test**

```python
def test_settings_expose_db_url_and_budgets(monkeypatch):
    for k, v in {
        "SUPABASE_URL": "https://x.supabase.co", "SUPABASE_SERVICE_KEY": "k",
        "WEBHOOK_SECRET": "s", "SUPABASE_DB_URL": "postgresql://u:p@h:5432/db",
    }.items():
        monkeypatch.setenv(k, v)
    s = get_settings()
    assert s.supabase_db_url == "postgresql://u:p@h:5432/db"
    assert s.max_llm_calls == 2
    assert s.max_tool_calls == 8
    assert s.wall_clock_seconds == 60


def test_db_url_is_none_when_unset(monkeypatch):
    for k in ("SUPABASE_URL", "SUPABASE_SERVICE_KEY", "WEBHOOK_SECRET"):
        monkeypatch.setenv(k, "x")
    monkeypatch.delenv("SUPABASE_DB_URL", raising=False)
    assert get_settings().supabase_db_url is None
```

- [ ] **Step 6: Run it and watch it fail**

Run: `pytest tests/test_config.py -v`
Expected: FAIL — `Settings` has no attribute `supabase_db_url`.

- [ ] **Step 7: Extend Settings**

In `app/common/config.py`, add to the dataclass and `get_settings()`:
```python
    supabase_db_url: str | None = None
    activity_queue_name: str = "activity:realtime"
    max_llm_calls: int = 2
    max_tool_calls: int = 8
    wall_clock_seconds: int = 60
```
```python
        supabase_db_url=os.environ.get("SUPABASE_DB_URL") or None,
        activity_queue_name=os.environ.get("ACTIVITY_QUEUE_NAME", "activity:realtime"),
        max_llm_calls=int(os.environ.get("MAX_LLM_CALLS", "2")),
        max_tool_calls=int(os.environ.get("MAX_TOOL_CALLS", "8")),
        wall_clock_seconds=int(os.environ.get("WALL_CLOCK_SECONDS", "60")),
```

- [ ] **Step 8: Run tests to verify they pass**

Run: `pytest tests/test_config.py -v` → PASS

- [ ] **Step 9: Commit**

```bash
git add requirements.txt app/common/config.py tests/test_config.py
git commit -m "feat: pin LangChain 1.x stack and add activity agent settings"
```

---

### Task 2: Migration and checkpointer connectivity

Both DB-touching risks, resolved before anything is built on them.

**Files:**
- Create: `db/003_activity_summary.sql`
- Create: `app/common/checkpointer.py`
- Test: `tests/test_checkpointer.py`

**Interfaces:**
- Produces: `build_checkpointer(settings) -> BaseCheckpointSaver`

- [ ] **Step 1: Write the migration**

`db/003_activity_summary.sql`:
```sql
-- predictions.kind gains 'activity_summary' (design §D3). No new table or column:
-- event_id holds the id of whichever row triggered the prediction.
alter table predictions drop constraint if exists predictions_kind_check;
alter table predictions add constraint predictions_kind_check
  check (kind in ('ack', 'analysis', 'activity_summary'));
```

- [ ] **Step 2: Apply it against the real project and confirm**

Run it in the Supabase SQL editor, then verify the constraint accepts the new value:
```sql
select pg_get_constraintdef(oid) from pg_constraint
where conname = 'predictions_kind_check';
```
Expected: the definition lists `activity_summary`.

- [ ] **Step 3: Prove PostgresSaver can connect (this is the risk)**

Supabase's transaction-mode pooler is awkward with prepared statements (spec §12.5).
Find out now:
```bash
python -c "
import os
from langgraph.checkpoint.postgres import PostgresSaver
with PostgresSaver.from_conn_string(os.environ['SUPABASE_DB_URL']) as cp:
    cp.setup()
    print('checkpointer OK')
"
```
Expected: `checkpointer OK` and `checkpoint*` tables created.
**If it fails on prepared statements:** switch `SUPABASE_DB_URL` to the direct
(non-pooler, port 5432) connection string, or append `?sslmode=require`. If it still
fails, record the error in spec §12.5 and use `InMemorySaver` for the demo — the graph
is unchanged either way, only Phase 3 chat resumption is lost.

- [ ] **Step 4: Write the failing checkpointer test**

```python
def test_falls_back_to_memory_without_db_url():
    from langgraph.checkpoint.memory import InMemorySaver
    settings = SimpleNamespace(supabase_db_url=None)
    assert isinstance(build_checkpointer(settings), InMemorySaver)
```

- [ ] **Step 5: Run it and watch it fail**

Run: `pytest tests/test_checkpointer.py -v` → FAIL, module not found.

- [ ] **Step 6: Implement the factory**

`app/common/checkpointer.py`:
```python
from contextlib import ExitStack

from langgraph.checkpoint.memory import InMemorySaver
from app.common.logging_config import get_logger

logger = get_logger(__name__)
_stack = ExitStack()


def build_checkpointer(settings):
    """Postgres-backed when a DB url is configured, else in-memory.

    Checkpoints are retained after a job so Phase 3 chat can resume the thread.
    """
    if not settings.supabase_db_url:
        logger.warning("no SUPABASE_DB_URL; using in-memory checkpointer")
        return InMemorySaver()
    from langgraph.checkpoint.postgres import PostgresSaver

    saver = _stack.enter_context(PostgresSaver.from_conn_string(settings.supabase_db_url))
    saver.setup()
    return saver
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `pytest tests/test_checkpointer.py -v` → PASS

- [ ] **Step 8: Commit**

```bash
git add db/003_activity_summary.sql app/common/checkpointer.py tests/test_checkpointer.py
git commit -m "feat: allow activity_summary predictions and add checkpointer factory"
```

---

### Task 3: Move ContextLoader into `common/`

Two agents will share it, and the rule's value is having exactly one auditable place
(spec §5.2). Mechanical move, no behaviour change.

**Scope decisions made here, deliberately:**
- `app/agent/llm.py` is **kept**, not deleted. The spec calls for deleting it, but the
  legacy event agent's `narration.py` depends on it; migrating that agent is not part of
  this feature. The activity agent uses `ChatOpenAI` directly and never imports `llm.py`.
  Migrating the event agent is a follow-up.
- The `app/agent/` → `app/event_agent/` rename is **skipped** for the same reason — churn
  and risk against working code for a cosmetic gain.

**Files:**
- Create: `app/common/context_loader.py` (moved content)
- Delete: `app/agent/context_loader.py`
- Modify: `app/agent/graph.py`, `app/worker/main.py`, `tests/test_context_loader.py`,
  `tests/test_agent_graph.py`

**Interfaces:**
- Produces: `app.common.context_loader.ContextLoader` — same class, same methods.

- [ ] **Step 1: Confirm the current test suite is green before touching anything**

Run: `pytest -q`
Expected: all pass. If not, stop — do not refactor on a red suite.

- [ ] **Step 2: Move the file**

```bash
git mv app/agent/context_loader.py app/common/context_loader.py
```

- [ ] **Step 3: Update every importer**

```bash
grep -rl "app\.agent\.context_loader" app tests | xargs sed -i '' \
  's/app\.agent\.context_loader/app.common.context_loader/g'
grep -rn "app\.agent\.context_loader" app tests   # must print nothing
```

- [ ] **Step 4: Run the whole suite to prove nothing broke**

Run: `pytest -q`
Expected: same number of tests passing as Step 1.

- [ ] **Step 5: Commit**

```bash
git add -A app tests
git commit -m "refactor: move ContextLoader to common, shared by both agents"
```

---

### Task 4: Deterministic activity analysis

The accuracy foundation. Pure functions, no I/O, no LLM.

**Files:**
- Create: `app/analytics/activity_analysis.py`
- Test: `tests/test_activity_analysis.py`

**Interfaces:**
- Produces:
  - `MIN_BASELINE_SESSIONS = 3`, `MIN_DURATION_SECONDS = 120`,
    `MAX_PLAUSIBLE_DURATION_SECONDS = 21600`, `SCORE_VERSION = 1`
  - `aggregate_samples(samples: list[dict]) -> dict[str, dict]`
  - `is_plausible_session(session: dict) -> bool`
  - `build_baseline(past: list[dict]) -> dict | None`
  - `assess_data_quality(aggregates: dict) -> str`
  - `compute_score(aggregates: dict, baseline: dict | None, duration: int) -> dict | None`
  - `analyze_activity(session: dict, past: list[dict]) -> dict`

- [ ] **Step 1: Write the failing tests, including both Review Focus cases**

```python
from app.analytics.activity_analysis import (
    aggregate_samples, is_plausible_session, build_baseline,
    assess_data_quality, compute_score, analyze_activity,
)


def test_aggregates_are_ragged_safe():
    """Review Focus 1: mobile omits null keys, so fields vary per sample."""
    samples = [
        {"heartRate": 140, "hrv": 40},
        {"heartRate": 150},                 # no hrv
        {"heartRate": 160, "spo2": 97},     # no hrv, has spo2
    ]
    agg = aggregate_samples(samples)
    assert agg["heartRate"]["n"] == 3
    assert agg["heartRate"]["mean"] == 150
    assert agg["hrv"]["n"] == 1             # only the sample that had it
    assert agg["spo2"]["n"] == 1
    assert "stress" not in agg              # never present -> absent, not zero


def test_non_numeric_sample_values_are_ignored():
    agg = aggregate_samples([{"heartRate": "bad"}, {"heartRate": 100}])
    assert agg["heartRate"]["n"] == 1


def test_empty_samples_give_no_aggregates_and_quality_none():
    assert aggregate_samples([]) == {}
    assert assess_data_quality({}) == "none"


def test_forgot_to_stop_session_is_rejected_from_baseline():
    """Review Focus 3: a 14-hour run must not poison the baseline."""
    assert is_plausible_session({"duration_seconds": 1800}) is True
    assert is_plausible_session({"duration_seconds": 14 * 3600}) is False
    assert is_plausible_session({"duration_seconds": 5}) is False

    past = [
        {"duration_seconds": 1800, "summary": {"heartRate": 150}},
        {"duration_seconds": 1800, "summary": {"heartRate": 150}},
        {"duration_seconds": 1800, "summary": {"heartRate": 150}},
        {"duration_seconds": 14 * 3600, "summary": {"heartRate": 60}},  # outlier
    ]
    baseline = build_baseline(past)
    assert baseline["sessions_compared"] == 3        # outlier excluded
    assert baseline["heartRate"] == 150              # not dragged down by the 60


def test_baseline_needs_three_plausible_sessions():
    two = [{"duration_seconds": 1800, "summary": {"heartRate": 150}}] * 2
    assert build_baseline(two) is None


def test_score_is_omitted_without_a_baseline():
    assert compute_score({"heartRate": {"mean": 140}}, None, 1800) is None


def test_score_rewards_lower_heart_rate_at_equal_duration():
    baseline = {"heartRate": 150, "duration_seconds": 1800, "sessions_compared": 5}
    better = compute_score({"heartRate": {"mean": 140}}, baseline, 1800)
    worse = compute_score({"heartRate": {"mean": 165}}, baseline, 1800)
    assert better["value"] > worse["value"]
    assert 0 <= worse["value"] <= 100 and 0 <= better["value"] <= 100
    assert better["scale"] == 100 and better["basis"].startswith("vs your last 5")


def test_score_is_deterministic():
    baseline = {"heartRate": 150, "duration_seconds": 1800, "sessions_compared": 5}
    agg = {"heartRate": {"mean": 143}}
    assert compute_score(agg, baseline, 1800) == compute_score(agg, baseline, 1800)


def test_analyze_activity_assembles_metrics_and_history():
    session = {"activity_type": "running", "duration_seconds": 1800,
               "samples": [{"heartRate": 140}, {"heartRate": 144}]}
    past = [{"duration_seconds": 1800, "summary": {"heartRate": 150}}] * 3
    out = analyze_activity(session, past)
    hr = next(m for m in out["metrics"] if m["key"] == "heartRate")
    assert hr["value"] == 142 and hr["baseline"] == 150
    assert hr["delta"] == -8 and hr["direction"] == "better"
    assert out["data_quality"] in {"full", "partial"}
    assert out["history_used"]["sessions_compared"] == 3
```

- [ ] **Step 2: Run them and watch them fail**

Run: `pytest tests/test_activity_analysis.py -v`
Expected: FAIL — `ModuleNotFoundError: app.analytics.activity_analysis`

- [ ] **Step 3: Implement the module**

`app/analytics/activity_analysis.py`:
```python
"""Deterministic activity analysis. No I/O, no LLM — every number here is arithmetic."""
from statistics import mean

TRACKED_FIELDS = ("heartRate", "hrv", "spo2", "stress", "steps")
LOWER_IS_BETTER = frozenset({"heartRate", "stress"})
MIN_BASELINE_SESSIONS = 3
MIN_DURATION_SECONDS = 120
MAX_PLAUSIBLE_DURATION_SECONDS = 21600  # 6h — beyond this, assume "forgot to stop"
SCORE_VERSION = 1


def aggregate_samples(samples):
    """Per-field aggregates. Ragged-safe: each field uses only samples containing it."""
    out = {}
    for field in TRACKED_FIELDS:
        values = [
            s[field] for s in samples
            if isinstance(s.get(field), (int, float)) and not isinstance(s.get(field), bool)
        ]
        if values:
            out[field] = {
                "mean": round(mean(values), 1), "min": min(values),
                "max": max(values), "n": len(values),
            }
    return out


def is_plausible_session(session):
    seconds = session.get("duration_seconds") or 0
    return MIN_DURATION_SECONDS <= seconds <= MAX_PLAUSIBLE_DURATION_SECONDS


def build_baseline(past):
    """Mean of each field across plausible past sessions, or None if too few."""
    plausible = [p for p in past if is_plausible_session(p)]
    if len(plausible) < MIN_BASELINE_SESSIONS:
        return None
    baseline = {"sessions_compared": len(plausible)}
    durations = [p["duration_seconds"] for p in plausible]
    baseline["duration_seconds"] = round(mean(durations))
    for field in TRACKED_FIELDS:
        values = [
            p["summary"][field] for p in plausible
            if isinstance((p.get("summary") or {}).get(field), (int, float))
        ]
        if values:
            baseline[field] = round(mean(values), 1)
    return baseline


def assess_data_quality(aggregates):
    if not aggregates:
        return "none"
    return "full" if "heartRate" in aggregates and len(aggregates) >= 2 else "partial"


def compute_score(aggregates, baseline, duration_seconds):
    """0-100, per activity type. Deterministic by construction — never LLM-chosen."""
    if baseline is None or "heartRate" not in aggregates or "heartRate" not in baseline:
        return None
    hr, hr_base = aggregates["heartRate"]["mean"], baseline["heartRate"]
    # lower HR than baseline is better; clamp influence at 20% deviation
    hr_ratio = max(-0.2, min(0.2, (hr_base - hr) / hr_base))
    hr_points = hr_ratio / 0.2 * 30

    base_duration = baseline.get("duration_seconds") or duration_seconds or 1
    dur_ratio = max(0.5, min(1.5, (duration_seconds or 0) / base_duration))
    dur_points = max(-20.0, min(20.0, (dur_ratio - 1) * 40))

    value = int(max(0, min(100, round(50 + hr_points + dur_points))))
    label = "strong" if value >= 75 else "solid" if value >= 55 else "easy" if value >= 40 else "below par"
    return {
        "value": value, "scale": 100, "label": label,
        "basis": f"vs your last {baseline['sessions_compared']} sessions",
        "score_version": SCORE_VERSION,
    }


def analyze_activity(session, past):
    aggregates = aggregate_samples(session.get("samples") or [])
    baseline = build_baseline(past)
    duration = session.get("duration_seconds") or 0

    metrics = []
    for key, agg in aggregates.items():
        base = (baseline or {}).get(key)
        delta = round(agg["mean"] - base, 1) if base is not None else None
        direction = None
        if delta is not None and delta != 0:
            improved = delta < 0 if key in LOWER_IS_BETTER else delta > 0
            direction = "better" if improved else "worse"
        metrics.append({
            "key": key, "value": agg["mean"], "min": agg["min"], "max": agg["max"],
            "samples": agg["n"], "baseline": base, "delta": delta, "direction": direction,
        })

    return {
        "activity_type": session.get("activity_type"),
        "duration_seconds": duration,
        "aggregates": aggregates,
        "baseline": baseline,
        "metrics": metrics,
        "score": compute_score(aggregates, baseline, duration),
        "data_quality": assess_data_quality(aggregates),
        "history_used": {
            "sessions_compared": (baseline or {}).get("sessions_compared", 0),
        },
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `pytest tests/test_activity_analysis.py -v` → all PASS

- [ ] **Step 5: Commit**

```bash
git add app/analytics/activity_analysis.py tests/test_activity_analysis.py
git commit -m "feat: deterministic activity analysis with outlier-rejected baseline and score"
```

---

### Task 5: Deterministic insight rules

The `improve` and `watch_outs` content must be decided by rules, not invented by the
model (spec §17.4) — same pattern this codebase already uses for alerts.

**Files:**
- Create: `app/analytics/insight_rules.py`
- Test: `tests/test_insight_rules.py`

**Interfaces:**
- Produces: `Insight` (frozen dataclass: `id`, `section`, `fact`),
  `evaluate(analysis: dict) -> list[Insight]`

- [ ] **Step 1: Write the failing tests**

```python
from app.analytics.insight_rules import evaluate


def _analysis(**over):
    base = {"data_quality": "full", "duration_seconds": 1800,
            "baseline": {"heartRate": 150, "duration_seconds": 1800, "sessions_compared": 5},
            "aggregates": {"heartRate": {"mean": 150, "min": 120, "max": 170, "n": 100}},
            "metrics": [{"key": "heartRate", "value": 150, "baseline": 150,
                         "delta": 0, "direction": None}]}
    base.update(over)
    return base


def _ids(analysis):
    return {i.id for i in evaluate(analysis)}


def test_no_baseline_asks_for_more_sessions():
    assert "no_baseline" in _ids(_analysis(baseline=None, score=None))


def test_missing_data_asks_user_to_wear_the_ring():
    assert "no_sensor_data" in _ids(_analysis(data_quality="none", aggregates={}, metrics=[]))


def test_elevated_heart_rate_fires_pacing_advice():
    ids = _ids(_analysis(metrics=[{"key": "heartRate", "value": 172, "baseline": 150,
                                   "delta": 22, "direction": "worse"}]))
    assert "hr_elevated" in ids


def test_lower_heart_rate_same_duration_is_praised():
    ids = _ids(_analysis(metrics=[{"key": "heartRate", "value": 140, "baseline": 150,
                                  "delta": -10, "direction": "better"}]))
    assert "hr_efficient" in ids


def test_short_session_suggests_building_duration():
    assert "duration_short" in _ids(_analysis(duration_seconds=600))


def test_low_spo2_is_flagged():
    ids = _ids(_analysis(aggregates={"spo2": {"mean": 95, "min": 88, "max": 99, "n": 50}}))
    assert "spo2_low" in ids


def test_rules_are_deterministic():
    a = _analysis()
    assert [i.id for i in evaluate(a)] == [i.id for i in evaluate(a)]
```

- [ ] **Step 2: Run them and watch them fail**

Run: `pytest tests/test_insight_rules.py -v` → FAIL, module not found.

- [ ] **Step 3: Implement the rules**

`app/analytics/insight_rules.py`:
```python
"""Which observations fire is a deterministic decision; only the wording is the LLM's.

Mirrors the alert rule in CLAUDE.md: decisions are testable rules, phrasing is generative.
Thresholds here are v1 and intended to be tuned with domain input.
"""
from dataclasses import dataclass

HR_ELEVATED_DELTA = 15.0      # bpm above baseline at comparable effort
HR_EFFICIENT_DELTA = -5.0     # bpm below baseline
SHORT_SESSION_RATIO = 0.7     # of baseline duration
SPO2_WATCH_MIN = 92.0


@dataclass(frozen=True)
class Insight:
    id: str
    section: str   # what_went_well | watch_outs | improve
    fact: str      # a plain statement of the finding; the LLM rephrases it


def _metric(analysis, key):
    return next((m for m in analysis.get("metrics", []) if m["key"] == key), None)


def evaluate(analysis):
    out: list[Insight] = []

    if analysis.get("data_quality") == "none":
        out.append(Insight("no_sensor_data", "improve",
            "No sensor data was captured for this session; wearing the ring throughout "
            "would allow a full analysis next time."))

    if analysis.get("baseline") is None:
        out.append(Insight("no_baseline", "improve",
            "There is not yet enough history for this activity type to compare against; "
            "a few more sessions will establish a personal baseline."))

    hr = _metric(analysis, "heartRate")
    if hr and hr.get("delta") is not None:
        if hr["delta"] >= HR_ELEVATED_DELTA:
            out.append(Insight("hr_elevated", "watch_outs",
                f"Average heart rate was {hr['delta']:.0f} bpm above the personal baseline, "
                "which can indicate harder effort, heat, or incomplete recovery."))
        elif hr["delta"] <= HR_EFFICIENT_DELTA:
            out.append(Insight("hr_efficient", "what_went_well",
                f"Average heart rate was {abs(hr['delta']):.0f} bpm below the personal "
                "baseline, which suggests improving efficiency."))

    baseline = analysis.get("baseline") or {}
    base_duration = baseline.get("duration_seconds")
    duration = analysis.get("duration_seconds") or 0
    if base_duration and duration < base_duration * SHORT_SESSION_RATIO:
        out.append(Insight("duration_short", "improve",
            "This session was notably shorter than usual for this activity."))

    spo2 = (analysis.get("aggregates") or {}).get("spo2")
    if spo2 and spo2.get("min") is not None and spo2["min"] < SPO2_WATCH_MIN:
        out.append(Insight("spo2_low", "watch_outs",
            f"Blood oxygen dipped to {spo2['min']:.0f}% during this session."))

    return out
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `pytest tests/test_insight_rules.py -v` → all PASS

- [ ] **Step 5: Commit**

```bash
git add app/analytics/insight_rules.py tests/test_insight_rules.py
git commit -m "feat: deterministic insight rules for activity advice"
```

---

### Task 6: Activity reads on ContextLoader, with the absence envelope

Every read the activity agent makes goes through here. The envelope distinguishing
`empty` from `unconfigured` is the single most important correctness detail in this task
(spec §17.2.1).

**Note on the test fake:** `tests/fakes.py::FakeQuery` implements `select/eq/neq/in_/gte/
lte/not_.is_/order/range/insert/upsert/delete` — there is **no `.limit()`**. Use
`.order(col, desc=True).range(0, limit - 1)`, matching the existing loader.

**Files:**
- Modify: `app/common/context_loader.py`
- Test: `tests/test_activity_context_loader.py`

**Interfaces:**
- Produces, all on `ContextLoader`:
  - `LOG_KINDS: frozenset[str]` (module level)
  - `activity_session(user_id, session_id) -> dict | None`
  - `past_activity_sessions(user_id, activity_type, limit, window_days) -> dict`
  - `past_activity_reports(user_id, limit) -> dict`
  - `user_profile(user_id) -> dict`
  - `safety_facts(user_id) -> dict`
  - `logs(user_id, kind, days, limit) -> dict`
  - `measurements(user_id, measurement_type, days, limit) -> dict`
  - `daily_snapshots(user_id, days) -> dict`
  - `documents(user_id, kind, limit) -> dict`
- Envelope shape: `{"status": "ok"|"empty"|"unconfigured"|"error", "items": [...]}`
  plus `"reason"` when not ok/empty.

- [ ] **Step 1: Write the failing tests, Review Focus 2 first**

```python
import pytest
from app.common.context_loader import ContextLoader, LOG_KINDS
from tests.fakes import FakeSupabase

USER, OTHER = "user-1", "user-2"


def test_unconfigured_is_not_the_same_as_empty():
    """Review Focus 2: 'we could not look' must never read as 'you have none'."""
    loader = ContextLoader(FakeSupabase({"meals": []}))
    empty = loader.logs(USER, "meals", days=30, limit=10)
    assert empty["status"] == "empty" and empty["items"] == []

    # no storage backend is wired, so documents cannot be looked up at all
    unconfigured = loader.documents(USER, kind="lab_report", limit=5)
    assert unconfigured["status"] == "unconfigured"
    assert "reason" in unconfigured
    assert unconfigured["status"] != "empty"


def test_logs_reject_a_kind_outside_the_allowlist():
    loader = ContextLoader(FakeSupabase({}))
    with pytest.raises(ValueError):
        loader.logs(USER, "predictions", days=30, limit=10)
    assert "medications" not in LOG_KINDS      # safety facts are never model-reachable
    assert "lab_results" in LOG_KINDS


def test_activity_session_is_scoped_to_the_user():
    db = FakeSupabase({"activity_sessions": [
        {"id": "s1", "user_id": USER, "activity_type": "running", "duration_seconds": 1800},
    ]})
    loader = ContextLoader(db)
    assert loader.activity_session(USER, "s1")["id"] == "s1"
    assert loader.activity_session(OTHER, "s1") is None   # another user's row is invisible


def test_past_sessions_exclude_the_current_one_and_filter_by_type():
    db = FakeSupabase({"activity_sessions": [
        {"id": "s1", "user_id": USER, "activity_type": "running",
         "started_at": "2026-09-20T10:00:00+00:00", "duration_seconds": 1800, "summary": {}},
        {"id": "s2", "user_id": USER, "activity_type": "yoga",
         "started_at": "2026-09-21T10:00:00+00:00", "duration_seconds": 1800, "summary": {}},
        {"id": "s3", "user_id": OTHER, "activity_type": "running",
         "started_at": "2026-09-22T10:00:00+00:00", "duration_seconds": 1800, "summary": {}},
    ]})
    out = ContextLoader(db).past_activity_sessions(USER, "running", limit=10, window_days=90)
    assert [r["id"] for r in out["items"]] == ["s1"]
    assert out["status"] == "ok"


def test_past_sessions_never_return_raw_samples():
    db = FakeSupabase({"activity_sessions": [
        {"id": "s1", "user_id": USER, "activity_type": "running",
         "started_at": "2026-09-20T10:00:00+00:00", "duration_seconds": 1800,
         "summary": {"heartRate": 150}, "samples": [{"heartRate": 1}] * 500},
    ]})
    out = ContextLoader(db).past_activity_sessions(USER, "running", limit=10, window_days=90)
    assert "samples" not in out["items"][0]


def test_safety_facts_are_returned_for_the_user_only():
    db = FakeSupabase({"medications": [
        {"id": "m1", "user_id": USER, "title": "Metformin",
         "recorded_at": "2026-09-01T00:00:00+00:00", "notes": "", "fields": {}},
        {"id": "m2", "user_id": OTHER, "title": "Warfarin",
         "recorded_at": "2026-09-01T00:00:00+00:00", "notes": "", "fields": {}},
    ]})
    out = ContextLoader(db).safety_facts(USER)
    assert [i["title"] for i in out["items"]] == ["Metformin"]


def test_user_profile_returns_empty_envelope_when_absent():
    out = ContextLoader(FakeSupabase({"user_preferences": []})).user_profile(USER)
    assert out["status"] == "empty"
```

- [ ] **Step 2: Run them and watch them fail**

Run: `pytest tests/test_activity_context_loader.py -v`
Expected: FAIL — `ImportError: cannot import name 'LOG_KINDS'`

- [ ] **Step 3: Extend the loader**

Add to `app/common/context_loader.py` (keep existing methods untouched):
```python
from datetime import datetime, timedelta, timezone

# Model-reachable log kinds. `medications` is deliberately absent: safety facts are
# fetched deterministically and always included, never via a skippable tool.
LOG_KINDS = frozenset({
    "lab_results", "therapy_sessions", "genetic_records", "environment_logs",
    "meals", "workouts", "hydration_logs", "plans", "progress_checkins",
    "consultations", "timeline_events",
})

SESSION_FIELDS = "id,activity_type,started_at,ended_at,duration_seconds,summary"


def _ok(items):
    return {"status": "ok" if items else "empty", "items": items}


def _unconfigured(reason):
    return {"status": "unconfigured", "items": [], "reason": reason}


def _since(days):
    return (datetime.now(timezone.utc) - timedelta(days=days)).isoformat()
```
Then the methods on `ContextLoader`:
```python
    def activity_session(self, user_id: str, session_id: str) -> dict | None:
        rows = (self._db.table("activity_sessions").select("*")
                .eq("user_id", user_id).eq("id", session_id).execute().data)
        return rows[0] if rows else None

    def past_activity_sessions(self, user_id, activity_type, limit=5, window_days=90) -> dict:
        query = (self._db.table("activity_sessions").select(SESSION_FIELDS)
                 .eq("user_id", user_id).gte("started_at", _since(window_days)))
        if activity_type:
            query = query.eq("activity_type", activity_type)
        rows = query.order("started_at", desc=True).range(0, max(0, limit - 1)).execute().data
        return _ok(rows)

    def past_activity_reports(self, user_id, limit=3) -> dict:
        rows = (self._db.table("predictions").select("summary,analysis,created_at")
                .eq("user_id", user_id).eq("kind", "activity_summary")
                .order("created_at", desc=True).range(0, max(0, limit - 1)).execute().data)
        return _ok(rows)

    def user_profile(self, user_id: str) -> dict:
        rows = (self._db.table("user_preferences").select("profile")
                .eq("user_id", user_id).execute().data)
        return _ok(rows)

    def safety_facts(self, user_id: str) -> dict:
        """Medications, always fetched — never exposed as a model-callable tool."""
        rows = (self._db.table("medications").select("title,notes,fields,recorded_at")
                .eq("user_id", user_id).order("recorded_at", desc=True)
                .range(0, 49).execute().data)
        return _ok(rows)

    def logs(self, user_id: str, kind: str, days: int = 30, limit: int = 20) -> dict:
        if kind not in LOG_KINDS:
            raise ValueError(f"kind not allowed: {kind}")
        rows = (self._db.table(kind).select("title,notes,fields,recorded_at")
                .eq("user_id", user_id).gte("recorded_at", _since(days))
                .order("recorded_at", desc=True).range(0, max(0, limit - 1)).execute().data)
        return _ok(rows)

    def measurements(self, user_id, measurement_type, days=30, limit=100) -> dict:
        rows = (self._db.table("health_measurements")
                .select("measurement_type,value,unit,recorded_at,quality")
                .eq("user_id", user_id).eq("measurement_type", measurement_type)
                .gte("recorded_at", _since(days))
                .order("recorded_at", desc=True).range(0, max(0, limit - 1)).execute().data)
        return _ok(rows)

    def daily_snapshots(self, user_id: str, days: int = 7) -> dict:
        rows = (self._db.table("wearable_daily_reports").select("report_date,snapshot")
                .eq("user_id", user_id).order("report_date", desc=True)
                .range(0, max(0, days - 1)).execute().data)
        return _ok(rows)

    def documents(self, user_id: str, kind: str | None = None, limit: int = 5) -> dict:
        """No object-storage backend is wired yet (design §17.2), so this reports
        `unconfigured` — which must never be narrated as the user having no documents."""
        return _unconfigured("no document storage backend is configured")
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `pytest tests/test_activity_context_loader.py -v` → all PASS

- [ ] **Step 5: Run the whole suite — the loader is shared**

Run: `pytest -q` → all PASS

- [ ] **Step 6: Commit**

```bash
git add app/common/context_loader.py tests/test_activity_context_loader.py
git commit -m "feat: activity reads on ContextLoader with explicit absence envelope"
```

---

### Task 7: Tools bound to ToolRuntime

Identity must be unreachable from the model, and every numeric argument clamped.

**Files:**
- Create: `app/activity_agent/__init__.py`, `app/activity_agent/state.py`,
  `app/activity_agent/tools.py`
- Test: `tests/test_activity_tools.py`

**Interfaces:**
- Produces:
  - `state.ActivityContext` — frozen dataclass: `user_id: str`, `session_id: str`,
    `display_name: str | None`
  - `state.ActivityState(AgentState)` — adds `session: dict`, `analysis: dict`,
    `insights: list[dict]`, `data_gaps: list[dict]`, `report: dict`,
    `summary: str`, `guardrail_flags: list[str]`
  - `tools.build_tools(loader) -> list[BaseTool]`
  - `tools.MAX_DAYS = 365`, `tools.MAX_LIMIT = 50`, `tools.clamp(value, low, high) -> int`

- [ ] **Step 1: Write the failing tests**

```python
from app.activity_agent.tools import build_tools, clamp, MAX_DAYS, MAX_LIMIT
from app.common.context_loader import ContextLoader
from tests.fakes import FakeSupabase


def _tools():
    return {t.name: t for t in build_tools(ContextLoader(FakeSupabase({})))}


def test_no_tool_exposes_an_identity_argument():
    """The central isolation guarantee, enforced structurally rather than by convention."""
    for name, tool in _tools().items():
        props = set(tool.args_schema.model_json_schema().get("properties", {}))
        assert not {"user_id", "userId", "uid", "id"} & props, f"{name} leaks identity"
        assert "runtime" not in props, f"{name} exposes runtime to the model"


def test_the_expected_seven_tools_are_present():
    assert set(_tools()) == {
        "get_past_sessions", "get_logs", "get_measurements", "get_daily_snapshot",
        "get_documents", "get_past_reports", "compare_window",
    }


def test_arguments_are_clamped():
    assert clamp(10**9, 1, MAX_DAYS) == MAX_DAYS
    assert clamp(-5, 1, MAX_LIMIT) == 1
    assert clamp(10, 1, MAX_LIMIT) == 10


def test_every_tool_has_a_docstring_description():
    for name, tool in _tools().items():
        assert tool.description, f"{name} has no description for the model to read"
```

- [ ] **Step 2: Run them and watch them fail**

Run: `pytest tests/test_activity_tools.py -v` → FAIL, module not found.

- [ ] **Step 3: Write the state module**

`app/activity_agent/state.py`:
```python
from dataclasses import dataclass

from langchain.agents.middleware import AgentState


@dataclass(frozen=True)
class ActivityContext:
    """Per-job runtime context. `user_id` is set once at entry and never mutated."""
    user_id: str
    session_id: str
    display_name: str | None = None


class ActivityState(AgentState):
    session: dict
    analysis: dict
    insights: list[dict]
    data_gaps: list[dict]
    report: dict
    summary: str
    guardrail_flags: list[str]
```

- [ ] **Step 4: Write the tools module**

`app/activity_agent/tools.py`:
```python
"""Tools for the activity agent.

Two invariants, both load-bearing:
  * no tool takes an identity argument — `user_id` comes from `ToolRuntime.context`
  * every model-supplied number is clamped before it reaches a query
"""
from langchain.tools import ToolRuntime, tool

from app.activity_agent.state import ActivityContext
from app.analytics.activity_analysis import analyze_activity

MAX_DAYS = 365
MAX_LIMIT = 50


def clamp(value, low: int, high: int) -> int:
    try:
        value = int(value)
    except (TypeError, ValueError):
        return low
    return max(low, min(high, value))


def build_tools(loader):
    @tool
    def get_past_sessions(activity_type: str | None = None, limit: int = 5,
                          window_days: int = 90,
                          runtime: ToolRuntime[ActivityContext] = None) -> dict:
        """Aggregated past activity sessions for the current user.

        Pass activity_type=None to span all activity types. Never returns raw samples.
        """
        return loader.past_activity_sessions(
            runtime.context.user_id, activity_type,
            limit=clamp(limit, 1, MAX_LIMIT), window_days=clamp(window_days, 1, MAX_DAYS))

    @tool
    def get_logs(kind: str, days: int = 30, limit: int = 20,
                 runtime: ToolRuntime[ActivityContext] = None) -> dict:
        """Entries the user logged, by kind.

        kind is one of: lab_results, therapy_sessions, genetic_records, environment_logs,
        meals, workouts, hydration_logs, plans, progress_checkins, consultations,
        timeline_events. Use this to explain a session from what happened around it.
        """
        try:
            return loader.logs(runtime.context.user_id, kind,
                               days=clamp(days, 1, MAX_DAYS),
                               limit=clamp(limit, 1, MAX_LIMIT))
        except ValueError as exc:
            return {"status": "error", "items": [], "reason": str(exc)}

    @tool
    def get_measurements(measurement_type: str, days: int = 30, limit: int = 100,
                         runtime: ToolRuntime[ActivityContext] = None) -> dict:
        """Typed body or vital measurements, e.g. weight, restingHeartRate, sleepDuration."""
        return loader.measurements(runtime.context.user_id, measurement_type,
                                   days=clamp(days, 1, MAX_DAYS),
                                   limit=clamp(limit, 1, MAX_LIMIT))

    @tool
    def get_daily_snapshot(days: int = 7,
                           runtime: ToolRuntime[ActivityContext] = None) -> dict:
        """Daily ring summaries (sleep, readiness) around the session."""
        return loader.daily_snapshots(runtime.context.user_id, days=clamp(days, 1, 31))

    @tool
    def get_documents(kind: str | None = None, limit: int = 5,
                      runtime: ToolRuntime[ActivityContext] = None) -> dict:
        """Uploaded documents such as lab reports.

        A status of 'unconfigured' means document storage is not set up — it does NOT
        mean the user has no documents. Never tell the user they have none in that case.
        """
        return loader.documents(runtime.context.user_id, kind,
                                limit=clamp(limit, 1, MAX_LIMIT))

    @tool
    def get_past_reports(limit: int = 3,
                         runtime: ToolRuntime[ActivityContext] = None) -> dict:
        """Previous activity reports, for continuity with advice already given."""
        return loader.past_activity_reports(runtime.context.user_id,
                                           limit=clamp(limit, 1, 10))

    @tool
    def compare_window(window_days: int = 30,
                       runtime: ToolRuntime[ActivityContext] = None) -> dict:
        """Recompute this session's comparison against a different history window.

        Deterministic: all arithmetic happens in Python. Use this instead of calculating
        differences yourself.
        """
        ctx = runtime.context
        session = loader.activity_session(ctx.user_id, ctx.session_id)
        if session is None:
            return {"status": "error", "items": [], "reason": "session not found"}
        past = loader.past_activity_sessions(
            ctx.user_id, session.get("activity_type"), limit=MAX_LIMIT,
            window_days=clamp(window_days, 1, MAX_DAYS))["items"]
        return {"status": "ok", "items": [analyze_activity(session, past)]}

    return [get_past_sessions, get_logs, get_measurements, get_daily_snapshot,
            get_documents, get_past_reports, compare_window]
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `pytest tests/test_activity_tools.py -v` → all PASS

If `test_no_tool_exposes_an_identity_argument` fails because `runtime` appears in the
schema, the annotation is wrong — `ToolRuntime` must be the parameter's type annotation
so LangChain excludes it from the model-visible schema. Fix the annotation, never the test.

- [ ] **Step 6: Commit**

```bash
git add app/activity_agent tests/test_activity_tools.py
git commit -m "feat: activity agent tools with runtime-bound identity and clamped args"
```

---

### Task 8: Deterministic nodes and the dynamic prompt

Everything before narration. Owns Review Focus 4: the webhook payload is not trusted.

**Files:**
- Create: `app/activity_agent/nodes.py`, `app/activity_agent/prompts.py`
- Test: `tests/test_activity_nodes.py`

**Interfaces:**
- Produces:
  - `nodes.entry(state, runtime) -> dict`
  - `nodes.make_load_session(loader) -> callable`
  - `nodes.make_load_context(loader) -> callable`
  - `nodes.analyze_node(state) -> dict`
  - `nodes.insights_node(state) -> dict`
  - `nodes.route_after_load(state) -> str` returning `"continue"` or `"stop"`
  - `nodes.ALLOWED_ACTIVITY_TYPES: frozenset[str]`
  - `prompts.build_system_prompt(state, context) -> str`

- [ ] **Step 1: Write the failing tests**

```python
from types import SimpleNamespace

from app.activity_agent.nodes import (
    ALLOWED_ACTIVITY_TYPES, make_load_session, make_load_context,
    analyze_node, insights_node, route_after_load,
)
from app.activity_agent.prompts import build_system_prompt
from app.activity_agent.state import ActivityContext
from app.common.context_loader import ContextLoader
from tests.fakes import FakeSupabase

USER, OTHER = "user-1", "user-2"
SESSION = {"id": "s1", "user_id": USER, "activity_type": "running",
           "started_at": "2026-09-29T06:00:00+00:00", "duration_seconds": 1800,
           "summary": {"heartRate": 142}, "samples": [{"heartRate": 142}] * 60}


def _runtime(user_id=USER, session_id="s1"):
    return SimpleNamespace(context=ActivityContext(user_id=user_id, session_id=session_id))


def test_row_is_reread_and_a_user_mismatch_yields_nothing():
    """Review Focus 4: never trust the payload's user_id."""
    loader = ContextLoader(FakeSupabase({"activity_sessions": [SESSION]}))
    load = make_load_session(loader)

    assert load({}, _runtime())["session"]["id"] == "s1"
    # a payload claiming another user must not reach this row
    assert load({}, _runtime(user_id=OTHER))["session"] == {}
    assert route_after_load({"session": {}}) == "stop"


def test_samples_come_from_the_row_not_the_payload():
    loader = ContextLoader(FakeSupabase({"activity_sessions": [SESSION]}))
    out = make_load_session(loader)({"session": {"samples": [{"heartRate": 999}] * 3}}, _runtime())
    assert len(out["session"]["samples"]) == 60          # authoritative row won
    assert out["session"]["samples"][0]["heartRate"] == 142


def test_accidental_tap_is_stopped():
    short = dict(SESSION, id="s2", duration_seconds=5)
    loader = ContextLoader(FakeSupabase({"activity_sessions": [short]}))
    out = make_load_session(loader)({}, _runtime(session_id="s2"))
    assert route_after_load(out) == "stop"


def test_unknown_activity_type_is_stopped():
    weird = dict(SESSION, id="s3", activity_type="teleporting")
    loader = ContextLoader(FakeSupabase({"activity_sessions": [weird]}))
    out = make_load_session(loader)({}, _runtime(session_id="s3"))
    assert route_after_load(out) == "stop"
    assert "running" in ALLOWED_ACTIVITY_TYPES and "yoga" in ALLOWED_ACTIVITY_TYPES


def test_load_context_records_data_gaps_distinguishing_empty_from_unconfigured():
    loader = ContextLoader(FakeSupabase({"activity_sessions": [SESSION], "meals": []}))
    out = make_load_context(loader)({"session": SESSION}, _runtime())
    gaps = {g["source"]: g["status"] for g in out["data_gaps"]}
    assert gaps["documents"] == "unconfigured"
    assert gaps.get("past_sessions") == "empty"
    assert "unconfigured" in gaps.values() and out["data_gaps"]


def test_analyze_then_insights_populate_state():
    past = [{"duration_seconds": 1800, "summary": {"heartRate": 150}}] * 3
    analyzed = analyze_node({"session": SESSION, "past_sessions": past})
    assert analyzed["analysis"]["score"] is not None
    out = insights_node(analyzed)
    assert isinstance(out["insights"], list)
    assert all({"id", "section", "fact"} <= set(i) for i in out["insights"])


def test_prompt_personalises_and_never_contains_raw_samples():
    state = {"session": SESSION, "analysis": {"metrics": [], "data_quality": "full",
             "duration_seconds": 1800, "score": None, "baseline": None},
             "insights": [], "data_gaps": []}
    prompt = build_system_prompt(state, ActivityContext(USER, "s1", display_name="Asha"))
    assert "Asha" in prompt
    assert "samples" not in prompt.lower()
    assert "recordedAt" not in prompt
```

- [ ] **Step 2: Run them and watch them fail**

Run: `pytest tests/test_activity_nodes.py -v` → FAIL, module not found.

- [ ] **Step 3: Write the nodes**

`app/activity_agent/nodes.py`:
```python
"""Deterministic nodes. No model is called anywhere in this module."""
from app.analytics.activity_analysis import analyze_activity, is_plausible_session
from app.analytics.insight_rules import evaluate
from app.common.logging_config import get_logger, log_context

logger = get_logger(__name__)

ALLOWED_ACTIVITY_TYPES = frozenset({
    "running", "walking", "cycling", "swimming", "strength", "yoga", "other",
})


def make_load_session(loader):
    def load_session(state, runtime) -> dict:
        ctx = runtime.context
        # Authoritative re-read: the webhook payload is untrusted, and `samples` can be
        # megabytes. Scoping by user_id means a mismatched payload finds nothing.
        session = loader.activity_session(ctx.user_id, ctx.session_id)
        if session is None:
            logger.warning("session not found or not this user's "
                           f"{log_context(user_id=ctx.user_id, session_id=ctx.session_id)}")
            return {"session": {}}
        return {"session": session}
    return load_session


def route_after_load(state) -> str:
    session = state.get("session") or {}
    if not session:
        return "stop"
    if session.get("activity_type") not in ALLOWED_ACTIVITY_TYPES:
        logger.warning(f"unknown activity_type={session.get('activity_type')}, stopping")
        return "stop"
    if not is_plausible_session(session):
        logger.info(f"implausible duration={session.get('duration_seconds')}, stopping")
        return "stop"
    return "continue"


def make_load_context(loader):
    def load_context(state, runtime) -> dict:
        ctx = runtime.context
        session = state["session"]
        past = loader.past_activity_sessions(ctx.user_id, session.get("activity_type"))
        profile = loader.user_profile(ctx.user_id)
        safety = loader.safety_facts(ctx.user_id)
        reports = loader.past_activity_reports(ctx.user_id, limit=1)
        documents = loader.documents(ctx.user_id)

        gaps = []
        for source, result in (("past_sessions", past), ("profile", profile),
                               ("safety_facts", safety), ("past_reports", reports),
                               ("documents", documents)):
            if result["status"] != "ok":
                gap = {"source": source, "status": result["status"]}
                if "reason" in result:
                    gap["reason"] = result["reason"]
                gaps.append(gap)

        return {
            "past_sessions": past["items"],
            "profile": (profile["items"][0].get("profile") if profile["items"] else {}) or {},
            "safety_facts": safety["items"],
            "previous_report": reports["items"][0] if reports["items"] else None,
            "data_gaps": gaps,
        }
    return load_context


def analyze_node(state) -> dict:
    return {"analysis": analyze_activity(state["session"], state.get("past_sessions") or [])}


def insights_node(state) -> dict:
    found = evaluate(state["analysis"])
    return {"insights": [{"id": i.id, "section": i.section, "fact": i.fact} for i in found]}
```

- [ ] **Step 4: Write the prompt builder**

`app/activity_agent/prompts.py`:
```python
"""Dynamic system prompt.

Ordering matters for prompt caching: stable instructions first, per-session facts last,
so the cacheable prefix is as long as possible (design §15.4).
"""
import json

ROLE = """You are a health and fitness analyst writing a short report about one finished \
activity session.

Rules you must follow:
- Every number you state must come from the COMPUTED FACTS below. Never calculate, \
estimate, or infer a figure yourself; if you need a different comparison, call the \
compare_window tool.
- Base all advice on the DETERMINED FINDINGS below. Do not invent training or health \
advice beyond them.
- You are not a clinician. Never diagnose, never discuss medication or dosage, never \
prescribe treatment.
- A data source marked "unconfigured" means we could not look it up. It does NOT mean \
the user has none of that data, and you must not say they do.
- If data quality is "none", do not make confident physiological claims at all.
- Write in second person, plainly, no emoji, no headings inside section bodies.

Produce a headline plus these sections, in this order: what_happened, what_changed, \
what_went_well, watch_outs, improve. Two or three sentences each."""


def build_system_prompt(state, context) -> str:
    analysis = state.get("analysis") or {}
    name = getattr(context, "display_name", None)
    greeting = f"The user's name is {name}." if name else "The user's name is unknown."

    facts = {
        "activity_type": (state.get("session") or {}).get("activity_type"),
        "duration_seconds": analysis.get("duration_seconds"),
        "data_quality": analysis.get("data_quality"),
        "score": analysis.get("score"),
        "baseline": analysis.get("baseline"),
        "metrics": analysis.get("metrics"),
        "history_used": analysis.get("history_used"),
    }
    previous = state.get("previous_report") or {}
    return "\n\n".join([
        ROLE,
        greeting,
        f"COMPUTED FACTS (the only numbers you may use):\n{json.dumps(facts, default=str)}",
        f"DETERMINED FINDINGS (the only advice you may give):\n"
        f"{json.dumps(state.get('insights') or [], default=str)}",
        f"UNAVAILABLE SOURCES:\n{json.dumps(state.get('data_gaps') or [], default=str)}",
        f"PREVIOUS REPORT HEADLINE: {previous.get('summary') or 'none'}",
    ])
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `pytest tests/test_activity_nodes.py -v` → all PASS

- [ ] **Step 6: Commit**

```bash
git add app/activity_agent/nodes.py app/activity_agent/prompts.py tests/test_activity_nodes.py
git commit -m "feat: deterministic activity nodes with untrusted-payload re-read"
```

---

### Task 9: Report assembly, numeric verification, and the graph

Owns Review Focus 5: a number the model invented must not pass silently.

**Key design point:** the model returns **prose only** — a headline and section bodies.
Every number in the envelope is written by us from the deterministic analysis. The model
is never asked to echo a metric, which removes the main opportunity for drift.

**Files:**
- Create: `app/activity_agent/report.py`, `app/activity_agent/persist.py`,
  `app/activity_agent/agent.py`
- Test: `tests/test_activity_report.py`, `tests/test_activity_graph.py`

**Interfaces:**
- Produces:
  - `report.Narrative` (pydantic): `headline: str`, `sections: list[NarrativeSection]`
  - `report.NarrativeSection`: `id: str`, `title: str`, `body: str`
  - `report.build_report(analysis, insights, narrative, data_gaps) -> dict`
  - `report.verify_numbers(report_dict, analysis) -> tuple[dict, list[str]]`
  - `report.fallback_narrative(analysis, insights) -> Narrative`
  - `persist.save_activity_report(supabase, user_id, session_id, report, flags) -> None`
  - `agent.build_activity_agent(loader, supabase, settings, checkpointer) -> CompiledGraph`

- [ ] **Step 1: Write the failing report tests**

```python
from app.activity_agent.report import (
    Narrative, NarrativeSection, build_report, verify_numbers, fallback_narrative,
)

ANALYSIS = {
    "activity_type": "running", "duration_seconds": 1800, "data_quality": "full",
    "score": {"value": 72, "scale": 100, "label": "solid", "basis": "vs your last 5 sessions",
              "score_version": 1},
    "baseline": {"heartRate": 150, "duration_seconds": 1800, "sessions_compared": 5},
    "metrics": [{"key": "heartRate", "value": 142, "min": 120, "max": 170, "samples": 60,
                 "baseline": 150, "delta": -8, "direction": "better"}],
    "history_used": {"sessions_compared": 5},
}


def _narrative(body):
    ids = ["what_happened", "what_changed", "what_went_well", "watch_outs", "improve"]
    return Narrative(headline="A steady run.",
                     sections=[NarrativeSection(id=i, title=i, body=body) for i in ids])


def test_report_envelope_is_assembled_from_deterministic_values():
    out = build_report(ANALYSIS, [], _narrative("Nothing notable."), [])
    assert out["schema_version"] == 1
    assert out["score"]["value"] == 72          # ours, not the model's
    assert out["metrics"][0]["delta"] == -8
    assert [s["id"] for s in out["sections"]] == [
        "what_happened", "what_changed", "what_went_well", "watch_outs", "improve"]
    assert out["data_gaps"] == []


def test_numbers_present_in_the_metrics_are_accepted():
    out = build_report(ANALYSIS, [], _narrative("Your average was 142 bpm, 8 below 150."), [])
    _, flags = verify_numbers(out, ANALYSIS)
    assert flags == []


def test_an_invented_number_is_flagged():
    """Review Focus 5."""
    out = build_report(ANALYSIS, [], _narrative("You burned 918 calories."), [])
    _, flags = verify_numbers(out, ANALYSIS)
    assert "unverified_number" in flags


def test_quality_none_blocks_confident_numeric_claims():
    analysis = dict(ANALYSIS, data_quality="none", metrics=[], score=None, baseline=None)
    out = build_report(analysis, [], _narrative("Your heart rate averaged 142 bpm."), [])
    checked, flags = verify_numbers(out, analysis)
    assert "quality_gate" in flags
    assert "142" not in checked["sections"][0]["body"]


def test_fallback_narrative_needs_no_model():
    nar = fallback_narrative(ANALYSIS, [{"id": "x", "section": "improve", "fact": "Do more."}])
    assert nar.headline
    assert len(nar.sections) == 5
```

- [ ] **Step 2: Run them and watch them fail**

Run: `pytest tests/test_activity_report.py -v` → FAIL, module not found.

- [ ] **Step 3: Implement report assembly and verification**

`app/activity_agent/report.py`:
```python
"""The report envelope. The model supplies prose; every number here is ours."""
import re

from pydantic import BaseModel, Field

SCHEMA_VERSION = 1
SECTION_IDS = ("what_happened", "what_changed", "what_went_well", "watch_outs", "improve")
SECTION_TITLES = {
    "what_happened": "What happened", "what_changed": "What changed",
    "what_went_well": "What went well", "watch_outs": "Worth watching",
    "improve": "What to try next time",
}
_NUMBER = re.compile(r"\d+(?:\.\d+)?")
SMALL_NUMBER_LIMIT = 10          # ordinals and counts like "3 sessions" are unremarkable


class NarrativeSection(BaseModel):
    id: str = Field(description="One of: " + ", ".join(SECTION_IDS))
    title: str
    body: str


class Narrative(BaseModel):
    """Prose only — the model never returns metrics, scores, or data quality."""
    headline: str = Field(description="One sentence for a list view.")
    sections: list[NarrativeSection]


def build_report(analysis, insights, narrative, data_gaps) -> dict:
    by_id = {s.id: s for s in narrative.sections}
    sections = []
    for sid in SECTION_IDS:
        section = by_id.get(sid)
        sections.append({
            "id": sid,
            "title": SECTION_TITLES[sid],
            "body": (section.body if section else "").strip(),
        })
    return {
        "schema_version": SCHEMA_VERSION,
        "score_version": (analysis.get("score") or {}).get("score_version", 1),
        "event_type": analysis.get("activity_type"),
        "score": analysis.get("score"),
        "headline": narrative.headline.strip(),
        "sections": sections,
        "metrics": analysis.get("metrics") or [],
        "data_quality": analysis.get("data_quality", "none"),
        "history_used": analysis.get("history_used") or {},
        "data_gaps": data_gaps or [],
        "insights": insights or [],
    }


def _allowed_numbers(analysis) -> set[str]:
    allowed = set()

    def add(value):
        if isinstance(value, (int, float)) and not isinstance(value, bool):
            allowed.add(f"{round(abs(value)):d}")
            allowed.add(f"{abs(value):.1f}".rstrip("0").rstrip("."))

    for metric in analysis.get("metrics") or []:
        for key in ("value", "min", "max", "baseline", "delta", "samples"):
            add(metric.get(key))
    for key, value in (analysis.get("baseline") or {}).items():
        add(value)
    add((analysis.get("score") or {}).get("value"))
    add(analysis.get("duration_seconds"))
    seconds = analysis.get("duration_seconds") or 0
    add(seconds // 60)                      # minutes are a fair restatement of duration
    add((analysis.get("history_used") or {}).get("sessions_compared"))
    return allowed


def verify_numbers(report_dict, analysis) -> tuple[dict, list[str]]:
    """Cheap deterministic fidelity check: prose figures must trace to computed values."""
    flags: list[str] = []
    allowed = _allowed_numbers(analysis)
    texts = [report_dict["headline"]] + [s["body"] for s in report_dict["sections"]]
    found = {n for text in texts for n in _NUMBER.findall(text)}
    unverified = {
        n for n in found
        if n not in allowed and not (float(n).is_integer() and float(n) <= SMALL_NUMBER_LIMIT)
    }

    if analysis.get("data_quality") == "none" and found:
        for section in report_dict["sections"]:
            section["body"] = _NUMBER.sub("—", section["body"])
        report_dict["headline"] = _NUMBER.sub("—", report_dict["headline"])
        flags.append("quality_gate")
    elif unverified:
        flags.append("unverified_number")

    return report_dict, flags


def fallback_narrative(analysis, insights) -> Narrative:
    """Used when no model is available or a budget cap was hit — deterministic prose."""
    minutes = round((analysis.get("duration_seconds") or 0) / 60)
    activity = analysis.get("activity_type") or "activity"
    metric_bits = ", ".join(
        f"{m['key']} averaged {m['value']}" for m in (analysis.get("metrics") or [])[:3]
    ) or "no sensor metrics were captured"
    by_section = {sid: [] for sid in SECTION_IDS}
    for insight in insights or []:
        by_section.setdefault(insight["section"], []).append(insight["fact"])

    bodies = {
        "what_happened": f"You recorded a {minutes}-minute {activity} session.",
        "what_changed": metric_bits.capitalize() + ".",
        "what_went_well": " ".join(by_section["what_went_well"]) or "Session recorded.",
        "watch_outs": " ".join(by_section["watch_outs"]) or "Nothing flagged.",
        "improve": " ".join(by_section["improve"])
                   or "Keep logging sessions to build a clearer picture.",
    }
    return Narrative(
        headline=f"{minutes}-minute {activity} session recorded.",
        sections=[NarrativeSection(id=s, title=SECTION_TITLES[s], body=bodies[s])
                  for s in SECTION_IDS],
    )
```

- [ ] **Step 4: Run report tests to verify they pass**

Run: `pytest tests/test_activity_report.py -v` → all PASS

- [ ] **Step 5: Write the persist helper**

`app/activity_agent/persist.py`:
```python
from app.common.logging_config import get_logger, log_context

logger = get_logger(__name__)


def save_activity_report(supabase, user_id, session_id, report, flags) -> None:
    """One upsert at the end. `event_id` holds the triggering row's id (design §D3)."""
    supabase.table("predictions").upsert(
        {
            "user_id": user_id,
            "event_id": session_id,
            "kind": "activity_summary",
            "summary": report["headline"],
            "analysis": report,
            "data_quality": report.get("data_quality", "none"),
            "guardrail_flags": flags,
        },
        on_conflict="event_id,kind",
    ).execute()
    logger.info("activity report saved "
                f"{log_context(user_id=user_id, session_id=session_id)}")
```

- [ ] **Step 6: Write the failing graph tests**

```python
from types import SimpleNamespace

from app.activity_agent.agent import build_activity_agent
from app.common.context_loader import ContextLoader
from tests.fakes import FakeSupabase

USER = "user-1"
SESSION = {"id": "s1", "user_id": USER, "activity_type": "running",
           "started_at": "2026-09-29T06:00:00+00:00", "duration_seconds": 1800,
           "summary": {"heartRate": 142}, "samples": [{"heartRate": 142}] * 60}
PAST = [{"id": f"p{i}", "user_id": USER, "activity_type": "running",
         "started_at": "2026-09-2%dT06:00:00+00:00" % i, "duration_seconds": 1800,
         "summary": {"heartRate": 150}} for i in range(1, 4)]
SETTINGS = SimpleNamespace(openai_api_key=None, llm_model="x", max_llm_calls=2,
                           max_tool_calls=8, wall_clock_seconds=60)


def _invoke(db, session_id="s1", user_id=USER):
    agent = build_activity_agent(ContextLoader(db), db, SETTINGS, checkpointer=None)
    return agent.invoke(
        {"messages": []},
        context={"user_id": user_id, "session_id": session_id},
        config={"configurable": {"thread_id": session_id}},
    )


def test_report_is_written_without_an_llm_using_the_fallback():
    db = FakeSupabase({"activity_sessions": [SESSION] + PAST, "predictions": []})
    _invoke(db)
    rows = db.tables["predictions"]
    assert len(rows) == 1
    assert rows[0]["kind"] == "activity_summary"
    assert rows[0]["analysis"]["score"]["value"] > 0
    assert len(rows[0]["analysis"]["sections"]) == 5


def test_another_users_session_writes_nothing():
    db = FakeSupabase({"activity_sessions": [SESSION], "predictions": []})
    _invoke(db, user_id="user-2")
    assert db.tables["predictions"] == []


def test_accidental_tap_writes_nothing():
    db = FakeSupabase({"activity_sessions": [dict(SESSION, duration_seconds=4)],
                       "predictions": []})
    _invoke(db)
    assert db.tables["predictions"] == []


def test_repeat_delivery_does_not_duplicate():
    db = FakeSupabase({"activity_sessions": [SESSION] + PAST, "predictions": []})
    _invoke(db)
    _invoke(db)
    assert len(db.tables["predictions"]) == 1
```

- [ ] **Step 7: Run them and watch them fail**

Run: `pytest tests/test_activity_graph.py -v` → FAIL, module not found.

- [ ] **Step 8: Assemble the graph**

`app/activity_agent/agent.py`:
```python
"""Graph assembly.

Deterministic StateGraph with exactly one model-calling node. The narration step is a
prebuilt `create_agent`, so tools, budgets, retries and structured output are all
framework-provided (design §15.2).
"""
from langchain.agents import create_agent
from langchain.agents.middleware import (
    ModelCallLimitMiddleware, ModelRetryMiddleware, ToolCallLimitMiddleware,
    dynamic_prompt,
)
from langgraph.graph import END, START, StateGraph

from app.activity_agent import nodes
from app.activity_agent.persist import save_activity_report
from app.activity_agent.prompts import build_system_prompt
from app.activity_agent.report import (
    Narrative, build_report, fallback_narrative, verify_numbers,
)
from app.activity_agent.state import ActivityContext, ActivityState
from app.activity_agent.tools import build_tools
from app.agent.guardrails import apply_guardrails
from app.common.logging_config import get_logger

logger = get_logger(__name__)


def _build_narrator(loader, settings):
    """None when no API key is configured — the graph then uses deterministic prose."""
    if not settings.openai_api_key:
        return None
    from langchain_openai import ChatOpenAI

    @dynamic_prompt
    def prompt(request):
        return build_system_prompt(request.state, request.runtime.context)

    return create_agent(
        model=ChatOpenAI(model=settings.llm_model, api_key=settings.openai_api_key,
                         temperature=0, timeout=settings.wall_clock_seconds),
        tools=build_tools(loader),
        middleware=[
            prompt,
            ModelCallLimitMiddleware(run_limit=settings.max_llm_calls, exit_behavior="end"),
            ToolCallLimitMiddleware(run_limit=settings.max_tool_calls, exit_behavior="end"),
            ModelRetryMiddleware(max_retries=1, on_failure="continue"),
        ],
        response_format=Narrative,
        state_schema=ActivityState,
        context_schema=ActivityContext,
    )


def build_activity_agent(loader, supabase, settings, checkpointer=None):
    narrator = _build_narrator(loader, settings)

    def narrate(state, runtime) -> dict:
        analysis, insights = state["analysis"], state.get("insights") or []
        narrative = None
        if narrator is not None:
            try:
                result = narrator.invoke(
                    {"messages": [{"role": "user",
                                   "content": "Write the report for this session."}]},
                    context=runtime.context,
                )
                narrative = result.get("structured_response")
            except Exception:
                logger.exception("narration failed, falling back to deterministic prose")
        if narrative is None:
            narrative = fallback_narrative(analysis, insights)
        return {"report": build_report(analysis, insights, narrative,
                                       state.get("data_gaps") or [])}

    def verify(state) -> dict:
        report, flags = verify_numbers(state["report"], state["analysis"])
        return {"report": report, "guardrail_flags": flags}

    def guardrails(state) -> dict:
        report = state["report"]
        flags = list(state.get("guardrail_flags") or [])
        # the existing deterministic medical-safety rules, reused unchanged
        analysis_for_rules = {"metrics": {
            m["key"]: {"during_mean": m["value"]} for m in report.get("metrics", [])
        }}
        for section in report["sections"]:
            text, section_flags = apply_guardrails(section["body"], analysis_for_rules)
            section["body"] = text
            flags.extend(f for f in section_flags if f not in flags)
        return {"report": report, "guardrail_flags": flags}

    def persist(state, runtime) -> dict:
        save_activity_report(supabase, runtime.context.user_id, runtime.context.session_id,
                             state["report"], state.get("guardrail_flags") or [])
        return {}

    graph = StateGraph(ActivityState, context_schema=ActivityContext)
    graph.add_node("load_session", nodes.make_load_session(loader))
    graph.add_node("load_context", nodes.make_load_context(loader))
    graph.add_node("analyze", nodes.analyze_node)
    graph.add_node("insights", nodes.insights_node)
    graph.add_node("narrate", narrate)
    graph.add_node("verify", verify)
    graph.add_node("guardrails", guardrails)
    graph.add_node("persist", persist)

    graph.add_edge(START, "load_session")
    graph.add_conditional_edges("load_session", nodes.route_after_load,
                                {"continue": "load_context", "stop": END})
    graph.add_edge("load_context", "analyze")
    graph.add_edge("analyze", "insights")
    graph.add_edge("insights", "narrate")
    graph.add_edge("narrate", "verify")
    graph.add_edge("verify", "guardrails")
    graph.add_edge("guardrails", "persist")
    graph.add_edge("persist", END)
    return graph.compile(checkpointer=checkpointer)
```

- [ ] **Step 9: Run the graph tests to verify they pass**

Run: `pytest tests/test_activity_graph.py -v` → all PASS

- [ ] **Step 10: Run the whole suite**

Run: `pytest -q` → all PASS

- [ ] **Step 11: Commit**

```bash
git add app/activity_agent tests/test_activity_report.py tests/test_activity_graph.py
git commit -m "feat: activity report assembly, numeric verification, and graph"
```

---

### Task 10: Gateway webhook for activity sessions

**Files:**
- Create: `app/gateway/activity_webhooks.py`
- Modify: `app/gateway/schemas.py`, `app/gateway/queue_provider.py`, `app/gateway/main.py`
- Test: `tests/test_activity_webhooks.py`

**Interfaces:**
- Produces:
  - `schemas.ActivitySessionRecord` (pydantic): `id: str`, `user_id: str`,
    `activity_type: str`
  - `schemas.ActivityWebhookPayload`: `type`, `table`, `record: ActivitySessionRecord`
  - `queue_provider.get_activity_queue() -> JobQueue`
  - `activity_webhooks.router` with `POST /webhooks/activity-sessions`

- [ ] **Step 1: Write the failing tests**

```python
from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.gateway.activity_webhooks import router
from app.gateway.queue_provider import get_activity_queue

SECRET = "test-secret"
BODY = {"type": "INSERT", "table": "activity_sessions",
        "record": {"id": "s1", "user_id": "u1", "activity_type": "running",
                   "samples": [{"heartRate": 1}] * 500}}


class SpyQueue:
    def __init__(self):
        self.jobs = []

    def enqueue(self, job):
        self.jobs.append(job)


def _client(monkeypatch):
    monkeypatch.setenv("SUPABASE_URL", "https://x.supabase.co")
    monkeypatch.setenv("SUPABASE_SERVICE_KEY", "k")
    monkeypatch.setenv("WEBHOOK_SECRET", SECRET)
    app = FastAPI()
    app.include_router(router)
    queue = SpyQueue()
    app.dependency_overrides[get_activity_queue] = lambda: queue
    return TestClient(app), queue


def test_missing_secret_is_rejected_and_nothing_is_enqueued(monkeypatch):
    client, queue = _client(monkeypatch)
    assert client.post("/webhooks/activity-sessions", json=BODY).status_code == 401
    assert queue.jobs == []


def test_wrong_secret_is_rejected(monkeypatch):
    client, queue = _client(monkeypatch)
    response = client.post("/webhooks/activity-sessions", json=BODY,
                           headers={"x-webhook-secret": "nope"})
    assert response.status_code == 401
    assert queue.jobs == []


def test_valid_request_enqueues_ids_only_and_returns_202(monkeypatch):
    client, queue = _client(monkeypatch)
    response = client.post("/webhooks/activity-sessions", json=BODY,
                           headers={"x-webhook-secret": SECRET})
    assert response.status_code == 202
    assert queue.jobs == [{"session_id": "s1", "user_id": "u1",
                           "activity_type": "running"}]
    # the multi-megabyte samples array must never ride on the queue
    assert "samples" not in queue.jobs[0]
```

- [ ] **Step 2: Run them and watch them fail**

Run: `pytest tests/test_activity_webhooks.py -v` → FAIL, module not found.

- [ ] **Step 3: Add the schema**

Append to `app/gateway/schemas.py`:
```python
class ActivitySessionRecord(BaseModel):
    """Only the identifiers are read. `samples` may be megabytes and is deliberately
    not modelled — the worker re-reads the authoritative row instead (design §18.2)."""
    id: str
    user_id: str
    activity_type: str


class ActivityWebhookPayload(BaseModel):
    type: Literal["INSERT", "UPDATE", "DELETE"]
    table: str
    record: ActivitySessionRecord
```

- [ ] **Step 4: Add the queue provider**

Append to `app/gateway/queue_provider.py`:
```python
@lru_cache
def get_activity_queue() -> JobQueue:
    settings = get_settings()
    redis_client = redis.Redis.from_url(settings.redis_url)
    return JobQueue(redis_client, settings.activity_queue_name)
```

- [ ] **Step 5: Add the endpoint**

`app/gateway/activity_webhooks.py`:
```python
from fastapi import APIRouter, Depends, Header, HTTPException

from app.common.config import get_settings
from app.common.logging_config import get_logger, log_context
from app.common.queue import JobQueue
from app.gateway.queue_provider import get_activity_queue
from app.gateway.schemas import ActivityWebhookPayload
from app.gateway.security import verify_webhook_signature

router = APIRouter()
logger = get_logger(__name__)


@router.post("/webhooks/activity-sessions", status_code=202)
def handle_activity_webhook(
    payload: ActivityWebhookPayload,
    x_webhook_secret: str | None = Header(default=None),
    queue: JobQueue = Depends(get_activity_queue),
):
    settings = get_settings()
    # The secret is checked before any field of the payload is used.
    if not verify_webhook_signature(x_webhook_secret, settings.webhook_secret):
        logger.warning("rejected activity webhook: bad or missing secret")
        raise HTTPException(status_code=401, detail="invalid webhook secret")

    record = payload.record
    queue.enqueue({"session_id": record.id, "user_id": record.user_id,
                   "activity_type": record.activity_type})
    logger.info("activity session enqueued "
                f"{log_context(user_id=record.user_id, session_id=record.id)}")
    return {"queued": True}
```

- [ ] **Step 6: Mount the router**

In `app/gateway/main.py`, alongside the existing router include:
```python
from app.gateway import activity_webhooks
app.include_router(activity_webhooks.router)
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `pytest tests/test_activity_webhooks.py -v` → all PASS

- [ ] **Step 8: Commit**

```bash
git add app/gateway tests/test_activity_webhooks.py
git commit -m "feat: activity session webhook on its own queue lane"
```

---

### Task 11: The activity worker and its container

**Files:**
- Create: `app/activity_worker/__init__.py`, `app/activity_worker/handlers.py`,
  `app/activity_worker/main.py`, `docker/Dockerfile.activity-worker`
- Modify: `docker-compose.yml`
- Test: `tests/test_activity_worker.py`

**Interfaces:**
- Produces:
  - `handlers.process_activity_job(job: dict, agent, wall_clock_seconds: int) -> None`
  - `main.process_one(queue, agent, timeout, wall_clock_seconds) -> bool`
  - `main.run() -> None`

- [ ] **Step 1: Write the failing tests**

```python
from app.activity_worker.handlers import process_activity_job
from app.activity_worker.main import process_one


class SpyAgent:
    def __init__(self, boom=False):
        self.calls, self.boom = [], boom

    def invoke(self, payload, **kwargs):
        self.calls.append((payload, kwargs))
        if self.boom:
            raise RuntimeError("model exploded")
        return {}


class OneJobQueue:
    def __init__(self, job):
        self.job = job

    def dequeue(self, timeout=5):
        job, self.job = self.job, None
        return job


def test_job_becomes_context_and_thread_id():
    agent = SpyAgent()
    process_activity_job({"user_id": "u1", "session_id": "s1"}, agent, 60)
    _, kwargs = agent.calls[0]
    assert kwargs["context"] == {"user_id": "u1", "session_id": "s1"}
    assert kwargs["config"]["configurable"]["thread_id"] == "s1"


def test_a_failing_agent_does_not_kill_the_worker():
    process_activity_job({"user_id": "u1", "session_id": "s1"}, SpyAgent(boom=True), 60)
    # no exception escapes — the worker must stay alive for the next job


def test_a_malformed_job_is_skipped():
    agent = SpyAgent()
    process_activity_job({"user_id": "u1"}, agent, 60)     # no session_id
    assert agent.calls == []


def test_process_one_reports_whether_it_did_work():
    agent = SpyAgent()
    queue = OneJobQueue({"user_id": "u1", "session_id": "s1"})
    assert process_one(queue, agent, timeout=0, wall_clock_seconds=60) is True
    assert process_one(queue, agent, timeout=0, wall_clock_seconds=60) is False
```

- [ ] **Step 2: Run them and watch them fail**

Run: `pytest tests/test_activity_worker.py -v` → FAIL, module not found.

- [ ] **Step 3: Write the handler**

`app/activity_worker/handlers.py`:
```python
from app.common.logging_config import get_logger, log_context

logger = get_logger(__name__)


def process_activity_job(job: dict, agent, wall_clock_seconds: int) -> None:
    user_id, session_id = job.get("user_id"), job.get("session_id")
    if not user_id or not session_id:
        logger.warning(f"malformed activity job, skipping: {job}")
        return
    context = log_context(user_id=user_id, session_id=session_id)
    try:
        agent.invoke(
            {"messages": []},
            context={"user_id": user_id, "session_id": session_id},
            config={"configurable": {"thread_id": session_id},
                    "recursion_limit": 25},
        )
        logger.info(f"activity job processed {context}")
    except Exception:
        # A single bad session must never take the worker down.
        logger.exception(f"activity job failed {context}")
```

- [ ] **Step 4: Write the worker entrypoint**

`app/activity_worker/main.py`:
```python
import redis

from app.activity_agent.agent import build_activity_agent
from app.activity_worker.handlers import process_activity_job
from app.common.checkpointer import build_checkpointer
from app.common.config import get_settings
from app.common.context_loader import ContextLoader
from app.common.logging_config import configure_logging, get_logger
from app.common.queue import JobQueue
from app.common.supabase_client import get_supabase_client

logger = get_logger(__name__)


def process_one(queue, agent, timeout: int = 5, wall_clock_seconds: int = 60) -> bool:
    try:
        job = queue.dequeue(timeout=timeout)
    except Exception:
        logger.exception("dequeue failed, will retry next tick")
        return False
    if job is None:
        return False
    process_activity_job(job, agent, wall_clock_seconds)
    return True


def run() -> None:
    configure_logging()
    settings = get_settings()
    # socket_timeout must exceed BRPOP's blocking timeout, as in the events worker.
    redis_client = redis.Redis.from_url(settings.redis_url, socket_timeout=30)
    queue = JobQueue(redis_client, settings.activity_queue_name)
    supabase = get_supabase_client()
    agent = build_activity_agent(
        ContextLoader(supabase), supabase, settings, build_checkpointer(settings),
    )
    logger.info("activity worker started "
                f"llm={'on' if settings.openai_api_key else 'off (deterministic prose)'} "
                f"model={settings.llm_model} lane={settings.activity_queue_name}")
    while True:
        process_one(queue, agent, wall_clock_seconds=settings.wall_clock_seconds)


if __name__ == "__main__":
    run()
```

- [ ] **Step 5: Write the Dockerfile**

`docker/Dockerfile.activity-worker` (mirrors `Dockerfile.worker`):
```dockerfile
FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app ./app
CMD ["python", "-m", "app.activity_worker.main"]
```

- [ ] **Step 6: Add the compose service**

Append to `docker-compose.yml`:
```yaml
  activity-worker:
    build:
      context: .
      dockerfile: docker/Dockerfile.activity-worker
    env_file: .env
    depends_on:
      redis:
        condition: service_healthy
    restart: unless-stopped
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `pytest tests/test_activity_worker.py -v` → all PASS

- [ ] **Step 8: Run the whole suite**

Run: `pytest -q` → all PASS

- [ ] **Step 9: Commit**

```bash
git add app/activity_worker docker/Dockerfile.activity-worker docker-compose.yml \
  tests/test_activity_worker.py
git commit -m "feat: deployable activity worker with checkpointed thread per session"
```

---

### Task 12: Live end-to-end verification and the demo

Everything until now was tested against fakes. This task proves it against the real
Supabase project and the real model, and leaves something demoable.

**Known constraint, state it plainly:** Supabase's cloud DB webhook cannot reach
`localhost`. So locally we drive the gateway exactly as Supabase would (same endpoint,
same header, same body), which proves gateway → queue → worker → report. The *true*
app-to-report path additionally needs a publicly reachable gateway — a tunnel or a
deploy — which is Step 7.

**A second gap worth naming:** the mobile app does not subscribe to `predictions` today
(verified — it only touches `activity_sessions` and `wellness_documents`). So the report
will not appear in the app until the frontend adds that subscription. For the demo we use
the existing HTML harness, which already subscribes to `predictions` via Realtime.

**Files:**
- Modify: `test_ui/index.html`
- Create: `scripts/seed_demo_sessions.py`

- [ ] **Step 1: Bring the stack up**

```bash
docker compose up -d --build
docker compose ps           # redis, gateway, worker, activity-worker all up
docker compose logs activity-worker --tail 20
```
Expected in the log: `activity worker started llm=on model=<your model> lane=activity:realtime`.
If it says `llm=off`, `OPENAI_API_KEY` is not reaching the container — check `.env`.

- [ ] **Step 2: Seed history so a score can exist**

A score needs at least 3 plausible past sessions of the same type (`MIN_BASELINE_SESSIONS`).

`scripts/seed_demo_sessions.py`:
```python
"""Seed past running sessions for a demo user so the baseline and score exist."""
import os
import sys
import uuid
from datetime import datetime, timedelta, timezone

from supabase import create_client

USER_ID = sys.argv[1]
client = create_client(os.environ["SUPABASE_URL"], os.environ["SUPABASE_SERVICE_KEY"])

now = datetime.now(timezone.utc)
for days_ago, avg_hr in ((10, 152), (7, 150), (4, 151), (2, 149)):
    started = now - timedelta(days=days_ago)
    client.table("activity_sessions").insert({
        "id": str(uuid.uuid4()),
        "user_id": USER_ID,
        "activity_type": "running",
        "started_at": started.isoformat(),
        "ended_at": (started + timedelta(minutes=30)).isoformat(),
        "duration_seconds": 1800,
        "summary": {"heartRate": avg_hr, "spo2": 97, "hrv": 42},
        "samples": [{"heartRate": avg_hr} for _ in range(30)],
    }).execute()
print(f"seeded 4 past running sessions for {USER_ID}")
```

Run it with a real auth user's id (the `user_id` must exist in `auth.users`, since
`activity_sessions.user_id` references it):
```bash
set -a && source .env && set +a
python scripts/seed_demo_sessions.py <REAL-AUTH-USER-UUID>
```

- [ ] **Step 3: Insert the session to be analysed, then drive the webhook**

```bash
set -a && source .env && set +a
SESSION_ID=$(python - <<'PY'
import os, uuid
from datetime import datetime, timedelta, timezone
from supabase import create_client
sid = str(uuid.uuid4()); user = os.environ["DEMO_USER_ID"]
started = datetime.now(timezone.utc) - timedelta(minutes=32)
create_client(os.environ["SUPABASE_URL"], os.environ["SUPABASE_SERVICE_KEY"]) \
  .table("activity_sessions").insert({
    "id": sid, "user_id": user, "activity_type": "running",
    "started_at": started.isoformat(),
    "ended_at": (started + timedelta(minutes=30)).isoformat(),
    "duration_seconds": 1800,
    "summary": {"heartRate": 142, "spo2": 97, "hrv": 48},
    "samples": [{"heartRate": 138 + (i % 9), "spo2": 97} for i in range(1800)],
  }).execute()
print(sid)
PY
)
echo "session: $SESSION_ID"

curl -i -X POST http://localhost:8090/webhooks/activity-sessions \
  -H "content-type: application/json" \
  -H "x-webhook-secret: $WEBHOOK_SECRET" \
  -d "{\"type\":\"INSERT\",\"table\":\"activity_sessions\",\"record\":{\"id\":\"$SESSION_ID\",\"user_id\":\"$DEMO_USER_ID\",\"activity_type\":\"running\"}}"
```
Expected: `HTTP/1.1 202 Accepted` immediately (the gateway never blocks on analysis).

- [ ] **Step 4: Confirm the report was written, and inspect its quality**

```bash
docker compose logs activity-worker --tail 30     # expect "activity report saved"
set -a && source .env && set +a
python - <<'PY'
import os, json
from supabase import create_client
rows = (create_client(os.environ["SUPABASE_URL"], os.environ["SUPABASE_SERVICE_KEY"])
        .table("predictions").select("*").eq("kind", "activity_summary")
        .order("created_at", desc=True).limit(1).execute().data)
r = rows[0]["analysis"]
print("headline :", r["headline"])
print("score    :", r["score"])
print("quality  :", r["data_quality"], "| flags:", rows[0]["guardrail_flags"])
print("gaps     :", r["data_gaps"])
for s in r["sections"]:
    print(f"\n## {s['title']}\n{s['body']}")
PY
```

Check by eye, and treat each of these as a defect to fix, not a quirk to accept:
- `score.value` is present and plausible; `basis` names the number of sessions compared
- every figure in the prose appears in `metrics` — `guardrail_flags` should not contain
  `unverified_number`
- no diagnosis or medication language anywhere
- `data_gaps` lists `documents` as `unconfigured`, and the prose does **not** claim the
  user has no documents
- all five sections are present and non-empty

- [ ] **Step 5: Verify the failure paths against the live system**

```bash
# a) duplicate delivery must not duplicate the row
curl -s -o /dev/null -X POST http://localhost:8090/webhooks/activity-sessions \
  -H "content-type: application/json" -H "x-webhook-secret: $WEBHOOK_SECRET" \
  -d "{\"type\":\"INSERT\",\"table\":\"activity_sessions\",\"record\":{\"id\":\"$SESSION_ID\",\"user_id\":\"$DEMO_USER_ID\",\"activity_type\":\"running\"}}"

# b) a payload naming a different user must write nothing
curl -s -o /dev/null -X POST http://localhost:8090/webhooks/activity-sessions \
  -H "content-type: application/json" -H "x-webhook-secret: $WEBHOOK_SECRET" \
  -d "{\"type\":\"INSERT\",\"table\":\"activity_sessions\",\"record\":{\"id\":\"$SESSION_ID\",\"user_id\":\"00000000-0000-0000-0000-000000000009\",\"activity_type\":\"running\"}}"

# c) a bad secret must be rejected
curl -s -o /dev/null -w "%{http_code}\n" -X POST http://localhost:8090/webhooks/activity-sessions \
  -H "content-type: application/json" -H "x-webhook-secret: wrong" \
  -d "{\"type\":\"INSERT\",\"table\":\"activity_sessions\",\"record\":{\"id\":\"$SESSION_ID\",\"user_id\":\"$DEMO_USER_ID\",\"activity_type\":\"running\"}}"
```
Expected: (a) still exactly one `activity_summary` row for that session; (b) no new row
and a "session not found or not this user's" warning in the log; (c) prints `401`.

Count the rows to confirm (a) and (b):
```bash
python - <<'PY'
import os
from supabase import create_client
n = (create_client(os.environ["SUPABASE_URL"], os.environ["SUPABASE_SERVICE_KEY"])
     .table("predictions").select("id", count="exact")
     .eq("event_id", os.environ["SESSION_ID"]).execute())
print("rows for this session:", n.count)   # must be 1
PY
```

- [ ] **Step 6: Extend the HTML harness to demo the report**

In `test_ui/index.html`, add an activity control beside the existing event buttons. The
page already subscribes to `predictions` INSERT for the user, so the report arrives by
Realtime with no polling — which is the point worth showing a stakeholder.

```html
<hr />
<h2>Activity session</h2>
<select id="activity_type">
  <option value="running">running</option>
  <option value="cycling">cycling</option>
  <option value="yoga">yoga</option>
</select>
<button id="finish_activity" disabled>Finish 30-min session</button>
<div id="report" style="max-width:48em;font-family:system-ui"></div>
```
```javascript
document.getElementById("finish_activity").onclick = async () => {
  const id = crypto.randomUUID();
  const ended = new Date();
  const started = new Date(ended.getTime() - 30 * 60 * 1000);
  const { error } = await supabase.from("activity_sessions").insert({
    id, user_id: userId,
    activity_type: document.getElementById("activity_type").value,
    started_at: started.toISOString(), ended_at: ended.toISOString(),
    duration_seconds: 1800,
    summary: { heartRate: 142, spo2: 97, hrv: 48 },
    samples: Array.from({ length: 600 }, (_, i) => ({ heartRate: 138 + (i % 9) })),
  });
  log(error ? "insert failed: " + error.message
            : "session saved, waiting for the report to arrive…");
};

// render an activity_summary the moment Realtime delivers it
function renderReport(row) {
  if (row.kind !== "activity_summary") return;
  const r = row.analysis;
  document.getElementById("report").innerHTML =
    `<h3>${r.headline}</h3>` +
    (r.score ? `<p><b>Score ${r.score.value}/${r.score.scale}</b> — ${r.score.label}
       <i>(${r.score.basis})</i></p>` : "") +
    r.sections.map(s => `<h4>${s.title}</h4><p>${s.body}</p>`).join("") +
    `<p><small>data quality: ${r.data_quality}</small></p>`;
}
```
Wire `renderReport(payload.new)` into the existing `predictions` subscription callback.

- [ ] **Step 7: Configure the real Supabase DB webhook**

Needed for the genuine app-to-report path. Requires a publicly reachable gateway — use a
tunnel for a demo (`cloudflared tunnel --url http://localhost:8090`) or a deployed URL.

In the Supabase dashboard: **Database → Webhooks → Create**
- Table `activity_sessions`, event **INSERT**
- Type HTTP Request, method POST
- URL `<public-gateway-url>/webhooks/activity-sessions`
- HTTP header `x-webhook-secret: <WEBHOOK_SECRET from .env>`

Then, from the harness (or the Flutter app), finish a session and confirm a report
arrives with no manual curl.

- [ ] **Step 8: Demo dry run**

Walk it once, end to end, as a stakeholder would see it: open the harness, connect,
finish a session, watch the report appear by itself. Confirm it takes well under the 60s
cap, and note the elapsed time. Fix anything that reads badly in the prose before
showing it to anyone.

- [ ] **Step 9: Commit**

```bash
git add test_ui/index.html scripts/seed_demo_sessions.py
git commit -m "feat: demo harness renders activity reports and seed script for baselines"
```

---

## Self-Review

**Spec coverage.** Every section maps to a task: §5 identity → Tasks 7, 8; §7 graph →
Tasks 8, 9; §8 report contract → Task 9; §9 memory/threads → Tasks 2, 11; §10 guardrails →
Tasks 8, 9; §11 budgets and idempotency → Tasks 9, 11, 12; §15 framework use → Tasks 1, 9;
§17 tools → Tasks 6, 7; §18 edge cases → Tasks 4, 6, 7, 8, 9, 12; §19 layout → all.

**Deliberately not implemented, with reasons:**
- **RLS-enforced reads (spec §12.1)** — Phase 2. Phase 1 keeps service-role, per D10.
- **Deleting `app/agent/llm.py` and renaming to `event_agent/`** — Task 3 explains why:
  the legacy event agent depends on both, and migrating it is not this feature.
- **Per-user throttling for bulk sync (spec §18.2)** — not built. With one demo user it
  cannot trigger; it needs designing against real sync behaviour. **Carry into Phase 2.**
- **`langgraph.json`** — optional developer tooling (spec §15.5), no functional role.

**Type consistency.** `ActivityContext(user_id, session_id, display_name)` is constructed
in Task 7 and consumed identically in Tasks 8, 9, 11. `build_report` /`verify_numbers` /
`fallback_narrative` signatures match their call sites in `agent.py`. Loader methods
return the `{"status", "items"}` envelope everywhere except `activity_session`, which
returns `dict | None` — asserted in Task 6's tests and relied on in Task 8's.

**Review Focus coverage.** All five have tests in their owning tasks: ragged samples and
the forgot-to-stop outlier in Task 4; `unconfigured` vs `empty` in Task 6 (and again in
Task 8's `data_gaps` test); payload user mismatch in Tasks 8 and 12; invented numbers in
Task 9 and checked live in Task 12.

**One risk to watch during execution.** `display_name` must be populated from
`user_preferences.profile` in the worker before the prompt can personalise; Task 8's
prompt test passes it directly. If it arrives empty at runtime the prompt says "name is
unknown" — correct but impersonal. Confirm during Task 12 Step 4 and, if empty, read it
in `load_context` and thread it into the context object.
