# Mid-Event Check-Ins Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** While an event is open, re-check the user's readings on a timer and send one proactive alert per reason when a deterministic rule fires.

**Architecture:** A Redis sorted set holds "check this event again at T". The existing worker promotes due jobs into the normal queue each tick, so the agent is re-entered with `status="in_progress"`. The agent reuses `analyze_event` with `end = now`, asks a pure rule function whether to speak, and only then calls the LLM. `kind="check_in:<reason>"` on the existing `unique (event_id, kind)` constraint provides dedupe.

**Tech Stack:** Python 3.11 · LangGraph · Redis (sorted set) · Supabase Postgres · pytest · fakeredis

**Spec:** `docs/superpowers/specs/2026-10-04-mid-event-check-ins-design.md`

## Global Constraints

- **P2 — compute deterministically; let the LLM narrate.** The decision to alert is arithmetic; the LLM only words it. No LLM call before a rule has fired.
- **NFR-4.3** — alert *decisions* are rule-based and unit-tested; the LLM controls wording only.
- **NFR-5.2/5.3** — no LLM inference in a check that fires nothing. Deterministic computation preferred wherever a correct answer exists.
- **Tools/loaders must never accept `user_id` as a parameter from the model**; it comes from state. All reads go through `ContextLoader`.
- **Thresholds live in `app/common/thresholds.py`** with a validated range; a bad env value falls back loudly. Never a local copy of a shared threshold.
- **Every new timestamp parse goes through `parse_ts`** — mixing naive and aware datetimes raises `TypeError` at runtime.
- **Timer defaults:** interval 600 s, max 28800 s. **Rule defaults:** min elapsed 900 s, HR delta 12.0 bpm, HR z 2.0, HRV drop 25.0 %. Rule parameters live in `Thresholds`; timer parameters live in `Settings`.
- Tests run with `pytest` from `healthagent/`. Follow the existing test style: real `Settings` via `tests.fakes.make_settings`, `FakeSupabase`, `fakeredis`, no mocks of our own code.

## Review Focus

1. **Event ends between scheduling and promotion** — a promoted `in_progress` job whose event is now `ended` must produce nothing, not an alert about a finished event. *(Task 6)*
2. **No baseline yet (new user)** — `baseline_mean`/`z_during` are `None`; the rule must stay silent rather than compare against nothing. *(Task 3)*
3. **Same reason twice** — a reason already delivered for this event must not fire again, and must not cost an LLM call. *(Task 3, Task 6)*
4. **Naive timestamps** — a `started_at` without an offset must not raise `TypeError` against an aware `now`. *(Task 2)*
5. **User forgot to tap stop** — the timer chain must terminate at `check_in_max_seconds` instead of rescheduling forever. *(Task 8)*
6. **Another user's event id** — a promoted job naming someone else's event must write nothing. *(Task 6)*

---

### Task 1: Check-in thresholds and timer settings

**Files:**
- Modify: `app/common/thresholds.py:17-35`
- Modify: `app/common/config.py:9-30`, `app/common/config.py:47-65`
- Test: `tests/test_thresholds.py`, `tests/test_config.py`

**Interfaces:**
- Consumes: nothing.
- Produces: `Thresholds.check_in_hr_delta: float`, `Thresholds.check_in_hr_z: float`, `Thresholds.check_in_hrv_drop_pct: float`, `Thresholds.check_in_min_elapsed_seconds: float`; `Settings.check_in_interval_seconds: int`, `Settings.check_in_max_seconds: int`, `Settings.delayed_queue_name: str`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_thresholds.py`:

```python
def test_check_in_defaults_are_strict():
    thresholds = get_thresholds()

    assert thresholds.check_in_hr_delta == 12.0
    assert thresholds.check_in_hr_z == 2.0
    assert thresholds.check_in_hrv_drop_pct == 25.0
    assert thresholds.check_in_min_elapsed_seconds == 900.0


def test_check_in_threshold_outside_its_range_falls_back_to_the_default(monkeypatch):
    monkeypatch.setenv("CHECK_IN_HR_Z", "0.1")

    assert get_thresholds().check_in_hr_z == 2.0


def test_check_in_threshold_is_overridable_within_range(monkeypatch):
    monkeypatch.setenv("CHECK_IN_HR_DELTA", "20")

    assert get_thresholds().check_in_hr_delta == 20.0
```

Append to `tests/test_config.py`:

```python
def test_check_in_timer_defaults():
    settings = get_settings()

    assert settings.check_in_interval_seconds == 600
    assert settings.check_in_max_seconds == 28800
    assert settings.delayed_queue_name == "events:delayed"


def test_check_in_interval_is_overridable(monkeypatch):
    monkeypatch.setenv("CHECK_IN_INTERVAL_SECONDS", "300")

    assert get_settings().check_in_interval_seconds == 300
```

If `tests/test_config.py` does not already import `get_settings`, add
`from app.common.config import get_settings` at the top.

- [ ] **Step 2: Run tests to verify they fail**

Run: `pytest tests/test_thresholds.py tests/test_config.py -v`
Expected: FAIL with `AttributeError: 'Thresholds' object has no attribute 'check_in_hr_delta'` and the equivalent for `Settings`.

- [ ] **Step 3: Write minimal implementation**

In `app/common/thresholds.py`, add three fields to the `Thresholds` dataclass:

```python
@dataclass(frozen=True)
class Thresholds:
    spo2_danger_min: float = 90.0
    spo2_attention_max: float = 95.0
    heart_rate_danger_max: float = 200.0
    hr_attention_delta: float = 15.0
    stress_attention_delta: float = 15.0
    hrv_attention_delta: float = 15.0
    # Mid-event check-ins are deliberately stricter than the retrospective
    # attention thresholds above: a false alarm delivered mid-event costs more
    # trust than a missed one, because the user is being interrupted.
    check_in_hr_delta: float = 12.0
    check_in_hr_z: float = 2.0
    check_in_hrv_drop_pct: float = 25.0
    # A rule parameter, not a timer one: it decides whether a window mean is old
    # enough to mean anything, so it belongs with the other validated rule
    # inputs rather than in service config.
    check_in_min_elapsed_seconds: float = 900.0
```

and four entries to `RANGES`:

```python
    "check_in_hr_delta": (5.0, 50.0),
    "check_in_hr_z": (1.0, 6.0),
    "check_in_hrv_drop_pct": (10.0, 60.0),
    # 0 is allowed so a demo or a test can disable the wait deliberately.
    "check_in_min_elapsed_seconds": (0.0, 7200.0),
```

In `app/common/config.py`, add four fields to `Settings` after
`wall_clock_seconds`:

```python
    check_in_interval_seconds: int = 600
    check_in_max_seconds: int = 28800
    delayed_queue_name: str = "events:delayed"
```

and read them in `get_settings()`:

```python
        check_in_interval_seconds=int(os.environ.get("CHECK_IN_INTERVAL_SECONDS", "600")),
        check_in_max_seconds=int(os.environ.get("CHECK_IN_MAX_SECONDS", "28800")),
        delayed_queue_name=os.environ.get("DELAYED_QUEUE_NAME", "events:delayed"),
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `pytest tests/test_thresholds.py tests/test_config.py -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add app/common/thresholds.py app/common/config.py tests/test_thresholds.py tests/test_config.py
git commit -m "feat: check-in thresholds and timer settings"
```

---

### Task 2: `parse_ts` — one timestamp parser

**Files:**
- Create: `app/common/timeparse.py`
- Test: `tests/test_timeparse.py`

**Interfaces:**
- Consumes: nothing.
- Produces: `parse_ts(value: str | datetime | None) -> datetime | None` — always timezone-aware UTC; `None` for `None` or an unparseable string.

- [ ] **Step 1: Write the failing test**

Create `tests/test_timeparse.py`:

```python
from datetime import datetime, timezone

from app.common.timeparse import parse_ts

UTC = timezone.utc


def test_offset_timestamp_is_parsed_as_aware():
    assert parse_ts("2026-10-04T12:00:00+00:00") == datetime(2026, 10, 4, 12, tzinfo=UTC)


def test_zulu_suffix_is_parsed():
    assert parse_ts("2026-10-04T12:00:00Z") == datetime(2026, 10, 4, 12, tzinfo=UTC)


def test_naive_timestamp_is_assumed_utc_and_stays_comparable():
    """Regression: a naive value compared against an aware now() raises TypeError."""
    parsed = parse_ts("2026-10-04T12:00:00")

    assert parsed == datetime(2026, 10, 4, 12, tzinfo=UTC)
    assert parsed < datetime.now(UTC)


def test_datetime_passes_through_as_aware():
    assert parse_ts(datetime(2026, 10, 4, 12)) == datetime(2026, 10, 4, 12, tzinfo=UTC)


def test_none_and_garbage_return_none():
    assert parse_ts(None) is None
    assert parse_ts("") is None
    assert parse_ts("not a timestamp") is None
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest tests/test_timeparse.py -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'app.common.timeparse'`

- [ ] **Step 3: Write minimal implementation**

Create `app/common/timeparse.py`:

```python
"""One timestamp parser, because mixing naive and aware datetimes raises at runtime.

Postgres hands back offsets, hand-written fixtures and older rows sometimes do
not, and `naive < aware` is a TypeError rather than a wrong answer — so it
surfaces as a crashed worker, not a bad number. Everything here comes out
aware and in UTC.
"""

from datetime import datetime, timezone


def parse_ts(value: str | datetime | None) -> datetime | None:
    if value is None:
        return None
    if isinstance(value, datetime):
        parsed = value
    else:
        text = str(value).strip()
        if not text:
            return None
        try:
            parsed = datetime.fromisoformat(text.replace("Z", "+00:00"))
        except ValueError:
            return None
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest tests/test_timeparse.py -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add app/common/timeparse.py tests/test_timeparse.py
git commit -m "feat: parse_ts helper for aware UTC timestamps"
```

---

### Task 3: The check-in rule

**Files:**
- Create: `app/analytics/check_in.py`
- Test: `tests/test_check_in_rule.py`

**Interfaces:**
- Consumes: `Thresholds` (Task 1); the analysis dict shape from `analyze_event` — `{"data_quality": str, "metrics": {metric: {"baseline_mean", "during_mean", "delta_during", "z_during", ...}}}`.
- Produces:
  - `CheckIn` frozen dataclass with `reason: str` and `fact: str`
  - `evaluate_check_in(analysis: dict, elapsed_seconds: float, already_sent=(), thresholds: Thresholds | None = None) -> CheckIn | None`
  - `REASON_SPO2 = "spo2_low"`, `REASON_HR = "hr_elevated"`, `REASON_HRV = "hrv_suppressed"`, `PRIORITY` tuple in that order.
  - `CHECK_IN_PREFIX = "check_in:"` — the one definition; Task 4 and Task 6 both import it from here.

- [ ] **Step 1: Write the failing test**

Create `tests/test_check_in_rule.py`:

```python
from app.analytics.check_in import (
    PRIORITY,
    REASON_HR,
    REASON_HRV,
    REASON_SPO2,
    evaluate_check_in,
)
from app.common.thresholds import Thresholds, get_thresholds

ELAPSED = 1800.0  # 30 minutes in — past the min-elapsed guard


def analysis(quality="full", **metrics):
    base = {
        "heartRate": {"baseline_mean": 60.0, "during_mean": 62.0,
                      "delta_during": 2.0, "z_during": 0.5},
        "hrv": {"baseline_mean": 55.0, "during_mean": 54.0,
                "delta_during": -1.0, "z_during": -0.2},
        "temperature": {"baseline_mean": 36.5, "during_mean": 36.5,
                        "delta_during": 0.0, "z_during": 0.0},
        "spo2": {"baseline_mean": 97.0, "during_mean": 97.0,
                 "delta_during": 0.0, "z_during": 0.0},
    }
    base.update(metrics)
    return {"data_quality": quality, "metrics": base}


def test_a_quiet_event_says_nothing():
    assert evaluate_check_in(analysis(), ELAPSED) is None


def test_elevated_heart_rate_fires_with_the_delta_in_the_fact():
    result = evaluate_check_in(
        analysis(heartRate={"baseline_mean": 60.0, "during_mean": 76.0,
                            "delta_during": 16.0, "z_during": 3.1}),
        ELAPSED,
    )

    assert result is not None
    assert result.reason == REASON_HR
    assert "16" in result.fact


def test_heart_rate_above_the_delta_but_within_normal_spread_stays_silent():
    """A naturally variable person must not be nagged by a raw delta alone."""
    result = evaluate_check_in(
        analysis(heartRate={"baseline_mean": 60.0, "during_mean": 76.0,
                            "delta_during": 16.0, "z_during": 0.8}),
        ELAPSED,
    )

    assert result is None


def test_suppressed_hrv_fires_on_percentage_drop():
    result = evaluate_check_in(
        analysis(hrv={"baseline_mean": 55.0, "during_mean": 38.0,
                      "delta_during": -17.0, "z_during": -2.4}),
        ELAPSED,
    )

    assert result is not None
    assert result.reason == REASON_HRV


def test_low_spo2_outranks_everything_else():
    result = evaluate_check_in(
        analysis(
            spo2={"baseline_mean": 97.0, "during_mean": 88.0,
                  "delta_during": -9.0, "z_during": -4.0},
            heartRate={"baseline_mean": 60.0, "during_mean": 90.0,
                       "delta_during": 30.0, "z_during": 5.0},
        ),
        ELAPSED,
    )

    assert result is not None
    assert result.reason == REASON_SPO2
    assert PRIORITY.index(REASON_SPO2) == 0


def test_only_one_reason_is_returned_per_check():
    result = evaluate_check_in(
        analysis(
            heartRate={"baseline_mean": 60.0, "during_mean": 90.0,
                       "delta_during": 30.0, "z_during": 5.0},
            hrv={"baseline_mean": 55.0, "during_mean": 30.0,
                 "delta_during": -25.0, "z_during": -4.0},
        ),
        ELAPSED,
    )

    assert result is not None
    assert result.reason == REASON_HR


def test_a_reason_already_sent_is_skipped_and_the_next_one_can_fire():
    loud = analysis(
        heartRate={"baseline_mean": 60.0, "during_mean": 90.0,
                   "delta_during": 30.0, "z_during": 5.0},
        hrv={"baseline_mean": 55.0, "during_mean": 30.0,
             "delta_during": -25.0, "z_during": -4.0},
    )

    result = evaluate_check_in(loud, ELAPSED, already_sent={REASON_HR})

    assert result is not None
    assert result.reason == REASON_HRV


def test_every_reason_already_sent_means_silence():
    loud = analysis(
        heartRate={"baseline_mean": 60.0, "during_mean": 90.0,
                   "delta_during": 30.0, "z_during": 5.0},
    )

    assert evaluate_check_in(loud, ELAPSED, already_sent={REASON_HR}) is None


def test_no_baseline_yet_stays_silent():
    """Regression: a new user has no baseline; alerting against None is nonsense."""
    result = evaluate_check_in(
        analysis(heartRate={"baseline_mean": None, "during_mean": 95.0,
                            "delta_during": None, "z_during": None}),
        ELAPSED,
    )

    assert result is None


def test_missing_sensor_data_stays_silent():
    assert evaluate_check_in(analysis(quality="none"), ELAPSED) is None


def test_too_early_in_the_event_stays_silent():
    loud = analysis(
        heartRate={"baseline_mean": 60.0, "during_mean": 90.0,
                   "delta_during": 30.0, "z_during": 5.0},
    )

    assert evaluate_check_in(loud, elapsed_seconds=60.0) is None


def test_min_elapsed_boundary_fires_exactly_at_the_threshold():
    loud = analysis(
        heartRate={"baseline_mean": 60.0, "during_mean": 90.0,
                   "delta_during": 30.0, "z_during": 5.0},
    )
    minimum = get_thresholds().check_in_min_elapsed_seconds

    assert evaluate_check_in(loud, elapsed_seconds=minimum) is not None


def test_thresholds_can_be_tuned_without_touching_the_rule():
    strict = Thresholds(check_in_hr_delta=40.0)
    loud = analysis(
        heartRate={"baseline_mean": 60.0, "during_mean": 90.0,
                   "delta_during": 30.0, "z_during": 5.0},
    )

    assert evaluate_check_in(loud, ELAPSED, thresholds=strict) is None
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest tests/test_check_in_rule.py -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'app.analytics.check_in'`

- [ ] **Step 3: Write minimal implementation**

Create `app/analytics/check_in.py`:

```python
"""Whether to interrupt the user mid-event is a deterministic decision.

The LLM is never asked *whether* to speak, only how to word a reason that has
already fired — so a bad generation cannot invent an alert, and a quiet event
costs no inference at all (NFR-4.3, NFR-5.2).

Returns at most one reason per check: the notification stays focused, and the
reason doubles as the dedupe key (`kind="check_in:<reason>"`).
"""

from dataclasses import dataclass

from app.common.thresholds import Thresholds, get_thresholds

REASON_SPO2 = "spo2_low"
REASON_HR = "hr_elevated"
REASON_HRV = "hrv_suppressed"

# The reason is part of the prediction's `kind`, which is what makes the existing
# unique (event_id, kind) constraint the dedupe mechanism. Defined here, imported
# by the loader and the graph — two copies of this string would silently split
# "already sent" from "what we write".
CHECK_IN_PREFIX = "check_in:"

# Most urgent first. Blood oxygen outranks the others because it is the only one
# of the three that can warrant leaving the event entirely.
PRIORITY = (REASON_SPO2, REASON_HR, REASON_HRV)


@dataclass(frozen=True)
class CheckIn:
    reason: str
    fact: str  # a plain statement of what fired; the LLM rephrases it


def _spo2(metric: dict, thresholds: Thresholds) -> CheckIn | None:
    during = metric.get("during_mean")
    if during is None or during >= thresholds.spo2_danger_min:
        return None
    return CheckIn(
        REASON_SPO2,
        f"Blood oxygen is averaging {during:.0f}% during this event, below "
        f"{thresholds.spo2_danger_min:.0f}%.",
    )


def _heart_rate(metric: dict, thresholds: Thresholds) -> CheckIn | None:
    delta, z = metric.get("delta_during"), metric.get("z_during")
    # Both are required: a raw delta alone would nag a naturally variable person,
    # and a z-score alone would fire on a tiny absolute change.
    if delta is None or z is None:
        return None
    if delta < thresholds.check_in_hr_delta or z < thresholds.check_in_hr_z:
        return None
    return CheckIn(
        REASON_HR,
        f"Heart rate is running {delta:.0f} bpm above the personal baseline so "
        f"far in this event ({z:.1f} standard deviations outside the usual spread).",
    )


def _hrv(metric: dict, thresholds: Thresholds) -> CheckIn | None:
    baseline, delta = metric.get("baseline_mean"), metric.get("delta_during")
    if not baseline or baseline <= 0 or delta is None or delta >= 0:
        return None
    drop_pct = (-delta / baseline) * 100
    if drop_pct < thresholds.check_in_hrv_drop_pct:
        return None
    return CheckIn(
        REASON_HRV,
        f"HRV is down {drop_pct:.0f}% against the personal baseline so far in "
        "this event.",
    )


_RULES = {
    REASON_SPO2: ("spo2", _spo2),
    REASON_HR: ("heartRate", _heart_rate),
    REASON_HRV: ("hrv", _hrv),
}


def evaluate_check_in(
    analysis: dict,
    elapsed_seconds: float,
    already_sent=(),
    thresholds: Thresholds | None = None,
) -> CheckIn | None:
    """One reason to speak, or None. Silence is the expected outcome."""
    thresholds = thresholds or get_thresholds()

    # No readings near the window: there is nothing to have an opinion about.
    if analysis.get("data_quality") == "none":
        return None
    # Too early for a window mean to say anything about the event.
    if elapsed_seconds < thresholds.check_in_min_elapsed_seconds:
        return None

    metrics = analysis.get("metrics") or {}
    already_sent = set(already_sent)
    for reason in PRIORITY:
        if reason in already_sent:
            continue
        metric_key, rule = _RULES[reason]
        fired = rule(metrics.get(metric_key) or {}, thresholds)
        if fired is not None:
            return fired
    return None
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest tests/test_check_in_rule.py -v`
Expected: PASS (13 tests)

- [ ] **Step 5: Commit**

```bash
git add app/analytics/check_in.py tests/test_check_in_rule.py
git commit -m "feat: deterministic mid-event check-in rule"
```

---

### Task 4: Reading back which reasons were already sent

**Files:**
- Modify: `app/common/context_loader.py` (add a method after `load_other_events`, around line 86)
- Test: `tests/test_context_loader.py`

**Interfaces:**
- Consumes: `CHECK_IN_PREFIX` from `app.analytics.check_in` (Task 3); the `predictions` table (`user_id`, `event_id`, `kind`).
- Produces: `ContextLoader.sent_check_in_reasons(user_id: str, event_id: str) -> set[str]` — the bare reasons (`"hr_elevated"`), not the `check_in:` prefixed kinds.

- [ ] **Step 1: Write the failing test**

Append to `tests/test_context_loader.py` (reuse that file's existing fixtures
for `ContextLoader` and `FakeSupabase`; if it has no module-level user
constants, define `ALICE`/`BOB`/`EVENT_ID` string uuids at the top of the new
tests as the other test modules do):

```python
def test_sent_check_in_reasons_returns_bare_reasons():
    db = FakeSupabase({"predictions": [
        {"user_id": ALICE, "event_id": EVENT_ID, "kind": "ack"},
        {"user_id": ALICE, "event_id": EVENT_ID, "kind": "check_in:hr_elevated"},
        {"user_id": ALICE, "event_id": EVENT_ID, "kind": "check_in:spo2_low"},
    ]})

    reasons = ContextLoader(db).sent_check_in_reasons(ALICE, EVENT_ID)

    assert reasons == {"hr_elevated", "spo2_low"}


def test_sent_check_in_reasons_is_empty_when_nothing_was_sent():
    db = FakeSupabase({"predictions": [
        {"user_id": ALICE, "event_id": EVENT_ID, "kind": "ack"},
    ]})

    assert ContextLoader(db).sent_check_in_reasons(ALICE, EVENT_ID) == set()


def test_sent_check_in_reasons_ignores_another_users_rows():
    db = FakeSupabase({"predictions": [
        {"user_id": BOB, "event_id": EVENT_ID, "kind": "check_in:hr_elevated"},
    ]})

    assert ContextLoader(db).sent_check_in_reasons(ALICE, EVENT_ID) == set()


def test_sent_check_in_reasons_ignores_other_events():
    db = FakeSupabase({"predictions": [
        {"user_id": ALICE, "event_id": "other", "kind": "check_in:hr_elevated"},
    ]})

    assert ContextLoader(db).sent_check_in_reasons(ALICE, EVENT_ID) == set()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest tests/test_context_loader.py -v`
Expected: FAIL with `AttributeError: 'ContextLoader' object has no attribute 'sent_check_in_reasons'`

- [ ] **Step 3: Write minimal implementation**

Add the import to `app/common/context_loader.py`, beside the existing
`app.analytics.event_analysis` import:

```python
from app.analytics.check_in import CHECK_IN_PREFIX
```

and this method to `ContextLoader`, after `load_other_events`:

```python
    def sent_check_in_reasons(self, user_id: str, event_id: str) -> set[str]:
        """Which mid-event reasons this event has already been alerted about.

        Filtered in Python rather than with a `like`: the set per event is tiny,
        and one fewer PostgREST operator is one fewer thing to get wrong.
        """
        rows = (
            self._db.table("predictions")
            .select("kind")
            .eq("user_id", user_id)
            .eq("event_id", event_id)
            .execute()
            .data
        )
        return {
            row["kind"][len(CHECK_IN_PREFIX):]
            for row in rows
            if str(row.get("kind", "")).startswith(CHECK_IN_PREFIX)
        }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest tests/test_context_loader.py -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add app/common/context_loader.py tests/test_context_loader.py
git commit -m "feat: read already-sent check-in reasons per event"
```

---

### Task 5: Narrating a check-in

**Files:**
- Modify: `app/agent/narration.py` (add after `narrate`, line 74)
- Test: `tests/test_narration.py`

**Interfaces:**
- Consumes: `CheckIn` (Task 3).
- Produces:
  - `CHECK_IN_SYSTEM_PROMPT: str`
  - `check_in_fallback(event_type: str, check_in) -> str`
  - `build_check_in_prompt(event_type: str, check_in, analysis: dict) -> tuple[str, str]`
  - `narrate_check_in(llm, event_type: str, check_in, analysis: dict) -> str`

- [ ] **Step 1: Write the failing test**

Append to `tests/test_narration.py` (that file already defines a fake LLM; if
its fake is named differently, use the existing one rather than adding another):

```python
from app.analytics.check_in import CheckIn
from app.agent.narration import (
    build_check_in_prompt,
    check_in_fallback,
    narrate_check_in,
)

CHECK_IN = CheckIn("hr_elevated", "Heart rate is running 16 bpm above the baseline.")


def test_check_in_fallback_states_the_fact_and_names_the_event():
    text = check_in_fallback("alcohol", CHECK_IN)

    assert "16 bpm" in text
    assert "alcohol" in text


def test_check_in_prompt_carries_the_fact_and_forbids_diagnosis():
    system, user = build_check_in_prompt("alcohol", CHECK_IN, {"data_quality": "full"})

    assert "diagnos" in system.lower()
    assert "right now" in system.lower() or "happening" in system.lower()
    assert "16 bpm" in user
    assert "alcohol" in user


def test_narrate_check_in_uses_the_llm_reply():
    llm = FakeLLM("Your heart rate is climbing — worth easing off.")

    text = narrate_check_in(llm, "alcohol", CHECK_IN, {"data_quality": "full"})

    assert text == "Your heart rate is climbing — worth easing off."


def test_narrate_check_in_falls_back_without_an_llm_and_never_goes_silent():
    text = narrate_check_in(None, "alcohol", CHECK_IN, {"data_quality": "full"})

    assert "16 bpm" in text


def test_narrate_check_in_falls_back_when_the_llm_raises():
    class Boom:
        def invoke(self, messages):
            raise RuntimeError("provider down")

    text = narrate_check_in(Boom(), "alcohol", CHECK_IN, {"data_quality": "full"})

    assert "16 bpm" in text


def test_narrate_check_in_falls_back_on_an_empty_reply():
    text = narrate_check_in(FakeLLM("   "), "alcohol", CHECK_IN, {"data_quality": "full"})

    assert "16 bpm" in text
```

If `tests/test_narration.py` has no `FakeLLM`, add this above the new tests:

```python
from types import SimpleNamespace


class FakeLLM:
    def __init__(self, reply="ok"):
        self.reply, self.calls = reply, 0

    def invoke(self, messages):
        self.calls += 1
        return SimpleNamespace(content=self.reply)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest tests/test_narration.py -v`
Expected: FAIL with `ImportError: cannot import name 'narrate_check_in'`

- [ ] **Step 3: Write minimal implementation**

Append to `app/agent/narration.py`:

```python
CHECK_IN_SYSTEM_PROMPT = (
    "You are a wellness assistant speaking to the user DURING an event that is "
    "still happening right now. In one or two short sentences, say what you are "
    "seeing and offer one gentle, optional thing they could do. Use ONLY the "
    "numbers provided. These are correlations, not causes. Never diagnose, and "
    "never give medication, supplement, or dosage advice."
)


def check_in_fallback(event_type: str, check_in) -> str:
    """Used whenever the LLM is absent, failing, or empty — a fired rule must
    never reach the user as silence."""
    return f"While your {event_type} event is in progress: {check_in.fact}"


def build_check_in_prompt(event_type: str, check_in, analysis: dict) -> tuple[str, str]:
    user = (
        f"Event in progress: {event_type}\n"
        f"Data quality: {analysis.get('data_quality')}\n"
        f"What fired: {check_in.fact}\n"
        "Other computed readings so far:\n"
        + "\n".join(f"- {line}" for line in _metric_lines(analysis))
    )
    return CHECK_IN_SYSTEM_PROMPT, user


def narrate_check_in(llm, event_type: str, check_in, analysis: dict) -> str:
    if llm is None:
        return check_in_fallback(event_type, check_in)
    system, user = build_check_in_prompt(event_type, check_in, analysis)
    try:
        text = str(llm.invoke([("system", system), ("human", user)]).content).strip()
    except Exception:
        logger.exception("llm call failed, using fallback check-in")
        return check_in_fallback(event_type, check_in)
    return text or check_in_fallback(event_type, check_in)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest tests/test_narration.py -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add app/agent/narration.py tests/test_narration.py
git commit -m "feat: narrate a fired check-in with a deterministic fallback"
```

---

### Task 6: The `in_progress` route in the agent graph

**Files:**
- Modify: `app/agent/graph.py:15-108`
- Create: `db/004_check_ins.sql`
- Test: `tests/test_agent_graph.py`

**Interfaces:**
- Consumes: `evaluate_check_in`, `CheckIn` (Task 3); `sent_check_in_reasons` (Task 4); `narrate_check_in` (Task 5); `parse_ts` (Task 2).
- Produces: the agent accepts `status="in_progress"` and an optional `now` (ISO string) in its input state; writes `predictions.kind = "check_in:<reason>"`. `OPEN_STATUSES = frozenset({"started", "confirmed"})` exported from `app/agent/graph.py`.

- [ ] **Step 1: Write the failing test**

Append to `tests/test_agent_graph.py`:

```python
from app.analytics.check_in import REASON_HR

IN_PROGRESS_NOW = START + timedelta(minutes=45)


def make_open_db(owner=ALICE, status="started", event_type="alcohol", with_readings=True):
    """An event that is still open, with readings up to IN_PROGRESS_NOW."""
    event = {
        "id": EVENT_ID, "user_id": owner, "event_type": event_type, "status": status,
        "started_at": START.isoformat(), "ended_at": None,
    }
    readings = []
    if with_readings:
        readings = generate_readings(
            ALICE, IN_PROGRESS_NOW, days=14, seed=3,
            events=[(event_type, START, IN_PROGRESS_NOW)],
        )
    return FakeSupabase({"events": [event], "health_measurements": readings})


def run_in_progress(db, llm, user=ALICE, now=IN_PROGRESS_NOW):
    agent = build_agent(ContextLoader(db), llm, db)
    return agent.invoke({
        "user_id": user, "event_id": EVENT_ID,
        "status": "in_progress", "now": now.isoformat(),
    })


def test_in_progress_check_writes_a_check_in_when_a_rule_fires():
    db, llm = make_open_db(event_type="sauna"), FakeLLM("Your heart rate is climbing.")

    run_in_progress(db, llm)

    rows = db.tables["predictions"]
    assert len(rows) == 1
    assert rows[0]["kind"] == f"check_in:{REASON_HR}"
    assert rows[0]["user_id"] == ALICE
    assert rows[0]["summary"] == "Your heart rate is climbing."


def test_a_quiet_in_progress_check_writes_nothing_and_skips_the_llm():
    db, llm = make_open_db(event_type="eating"), FakeLLM()

    run_in_progress(db, llm)

    assert db.tables.get("predictions", []) == []
    assert llm.calls == 0


def test_an_in_progress_check_with_no_readings_stays_silent():
    db, llm = make_open_db(with_readings=False), FakeLLM()

    run_in_progress(db, llm)

    assert db.tables.get("predictions", []) == []
    assert llm.calls == 0


def test_a_reason_already_delivered_does_not_fire_again_or_call_the_llm():
    """Regression: the same reason buzzing every ten minutes is how users
    switch notifications off."""
    db, llm = make_open_db(event_type="sauna"), FakeLLM()
    db.tables["predictions"] = [
        {"user_id": ALICE, "event_id": EVENT_ID, "kind": f"check_in:{REASON_HR}",
         "summary": "already said"},
    ]

    run_in_progress(db, llm)

    assert len(db.tables["predictions"]) == 1
    assert llm.calls == 0


def test_an_event_that_ended_before_the_check_ran_produces_nothing():
    """Regression: the timer fires after the user tapped stop."""
    db, llm = make_open_db(event_type="sauna", status="ended"), FakeLLM()

    run_in_progress(db, llm)

    assert db.tables.get("predictions", []) == []
    assert llm.calls == 0


def test_an_in_progress_check_on_another_users_event_produces_nothing():
    db, llm = make_open_db(owner=BOB, event_type="sauna"), FakeLLM()

    run_in_progress(db, llm, user=ALICE)

    assert db.tables.get("predictions", []) == []
    assert llm.calls == 0


def test_an_unsafe_check_in_is_replaced_and_flagged():
    db = make_open_db(event_type="sauna")
    llm = FakeLLM("This is a diagnosis of atrial fibrillation.")

    run_in_progress(db, llm)

    row = db.tables["predictions"][0]
    assert row["summary"] == SAFE_FALLBACK
    assert "diagnosis" in row["guardrail_flags"]


def test_a_check_in_without_an_llm_still_reaches_the_user():
    db = make_open_db(event_type="sauna")

    run_in_progress(db, None)

    row = db.tables["predictions"][0]
    assert "in progress" in row["summary"].lower()


def test_a_check_before_the_min_elapsed_guard_stays_silent():
    db, llm = make_open_db(event_type="sauna"), FakeLLM()

    run_in_progress(db, llm, now=START + timedelta(minutes=5))

    assert db.tables.get("predictions", []) == []
    assert llm.calls == 0


def test_in_progress_does_not_mutate_the_user_id():
    db = make_open_db(event_type="sauna")

    result = run_in_progress(db, FakeLLM())

    assert result["user_id"] == ALICE
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest tests/test_agent_graph.py -v`
Expected: FAIL — the `in_progress` status is unhandled, so `predictions` stays
empty and `test_in_progress_check_writes_a_check_in_when_a_rule_fires` fails on
`len(rows) == 1`.

- [ ] **Step 3: Write minimal implementation**

Rewrite `app/agent/graph.py` as follows (new and changed parts only — keep
`acknowledge`, `analyze`, `guardrails` and `persist` bodies as they are):

```python
from datetime import datetime, timedelta, timezone
from typing import TypedDict

from langgraph.graph import END, START, StateGraph

from app.agent.guardrails import apply_guardrails
from app.agent.narration import narrate, narrate_check_in
from app.agent.persist import save_prediction
from app.analytics.check_in import CHECK_IN_PREFIX, CheckIn, evaluate_check_in
from app.analytics.event_analysis import BASELINE_DAYS, analyze_event
from app.common.logging_config import get_logger, log_context
from app.common.timeparse import parse_ts

logger = get_logger(__name__)

# An event the user (or the detector) has not closed yet. `ended`, `expired` and
# `rejected` all stop the check-in timer.
OPEN_STATUSES = frozenset({"started", "confirmed"})


class AgentState(TypedDict, total=False):
    user_id: str
    event_id: str
    status: str
    now: str | None
    event: dict | None
    kind: str
    analysis: dict
    summary: str
    check_in: CheckIn | None
    guardrail_flags: list[str]
```

In `build_agent`, change `route` and add the two new nodes:

```python
    def route(state: AgentState) -> str:
        context = log_context(user_id=state["user_id"], event_id=state["event_id"])
        event = state.get("event")
        if event is None:
            logger.warning(f"event not found for user, skipping {context}")
            return "end"
        status = state["status"]
        if status == "in_progress":
            # The timer fires on a schedule, so the event may have been closed
            # between scheduling and promotion. Checking the row, not the job,
            # is what makes that race harmless.
            if event.get("status") not in OPEN_STATUSES:
                logger.info(
                    f"event no longer open, dropping check-in {context} "
                    f"event_status={event.get('status')}"
                )
                return "end"
            return "check_in"
        route_for = {"started": "acknowledge", "ended": "analyze"}.get(status)
        if route_for is None:
            logger.info(f"status not handled yet, skipping {context} status={status}")
            return "end"
        return route_for

    def _now(state: AgentState) -> datetime:
        return parse_ts(state.get("now")) or datetime.now(timezone.utc)

    def check_in(state: AgentState) -> dict:
        event = state["event"]
        start = parse_ts(event["started_at"])
        now = _now(state)
        readings = loader.load_readings(state["user_id"], start, now)
        others = loader.load_other_events(
            state["user_id"], state["event_id"], start - timedelta(days=BASELINE_DAYS)
        )
        analysis = analyze_event(readings, start, now, others)
        fired = evaluate_check_in(
            analysis,
            elapsed_seconds=(now - start).total_seconds(),
            already_sent=loader.sent_check_in_reasons(state["user_id"], state["event_id"]),
        )
        if fired is None:
            return {"analysis": analysis, "check_in": None}
        return {
            "kind": f"{CHECK_IN_PREFIX}{fired.reason}",
            "analysis": analysis,
            "check_in": fired,
        }

    def route_check_in(state: AgentState) -> str:
        if state.get("check_in") is None:
            logger.info(
                "nothing to say mid-event "
                f"{log_context(user_id=state['user_id'], event_id=state['event_id'])}"
            )
            return "end"
        return "narrate_check_in"

    def narrate_check_in_node(state: AgentState) -> dict:
        return {
            "summary": narrate_check_in(
                llm, state["event"]["event_type"], state["check_in"], state["analysis"]
            )
        }
```

Wire them into the graph, replacing the existing node/edge block:

```python
    graph = StateGraph(AgentState)
    graph.add_node("load_event", load_event)
    graph.add_node("acknowledge", acknowledge)
    graph.add_node("analyze", analyze)
    graph.add_node("check_in", check_in)
    graph.add_node("narrate", narrate_node)
    graph.add_node("narrate_check_in", narrate_check_in_node)
    graph.add_node("guardrails", guardrails)
    graph.add_node("persist", persist)

    graph.add_edge(START, "load_event")
    graph.add_conditional_edges(
        "load_event",
        route,
        {
            "acknowledge": "acknowledge",
            "analyze": "analyze",
            "check_in": "check_in",
            "end": END,
        },
    )
    graph.add_edge("acknowledge", "persist")
    graph.add_edge("analyze", "narrate")
    graph.add_conditional_edges(
        "check_in",
        route_check_in,
        {"narrate_check_in": "narrate_check_in", "end": END},
    )
    graph.add_edge("narrate", "guardrails")
    graph.add_edge("narrate_check_in", "guardrails")
    graph.add_edge("guardrails", "persist")
    graph.add_edge("persist", END)
    return graph.compile()
```

Also replace the two `datetime.fromisoformat(...)` calls inside `analyze` with
`parse_ts(...)`, so every timestamp in this module is aware:

```python
    def analyze(state: AgentState) -> dict:
        event = state["event"]
        start = parse_ts(event["started_at"])
        end = parse_ts(event.get("ended_at")) or start
```

Create `db/004_check_ins.sql`:

```sql
-- Mid-event check-ins are predictions with kind 'check_in:<reason>'. The reason
-- is part of the kind so the existing unique (event_id, kind) constraint makes a
-- duplicate alert for the same reason structurally impossible, while a different
-- reason can still fire later in the same event.
alter table predictions drop constraint if exists predictions_kind_check;

alter table predictions add constraint predictions_kind_check check (
  kind in ('ack', 'analysis', 'activity_summary')
  or kind ~ '^check_in:[a-z0-9_]+$'
);
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `pytest tests/test_agent_graph.py -v`
Expected: PASS (the pre-existing tests plus 10 new ones)

Then run the whole suite, since `graph.py` and `narration.py` are shared:
Run: `pytest -q`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add app/agent/graph.py db/004_check_ins.sql tests/test_agent_graph.py
git commit -m "feat: in_progress route emits mid-event check-ins"
```

---

### Task 7: `DelayedQueue` — the timer

**Files:**
- Modify: `app/common/queue.py`
- Test: `tests/test_delayed_queue.py`

**Interfaces:**
- Consumes: `JobQueue` (existing).
- Produces:
  - `DelayedQueue(redis_client, key)` with `schedule(job: dict, due_at: datetime) -> None`
  - `promote_due(target: JobQueue, now: datetime, limit: int = 100) -> int`
  - `pending(self) -> int`

- [ ] **Step 1: Write the failing test**

Create `tests/test_delayed_queue.py`:

```python
from datetime import datetime, timedelta, timezone

import fakeredis

from app.common.queue import DelayedQueue, JobQueue

UTC = timezone.utc
NOW = datetime(2026, 10, 4, 20, 0, tzinfo=UTC)
JOB = {"event_id": "e1", "user_id": "u1", "status": "in_progress"}


def make_pair():
    redis_client = fakeredis.FakeStrictRedis()
    return (
        DelayedQueue(redis_client, "events:delayed"),
        JobQueue(redis_client, "events:realtime"),
    )


def test_a_job_scheduled_for_later_is_not_promoted_yet():
    delayed, queue = make_pair()
    delayed.schedule(JOB, NOW + timedelta(minutes=10))

    moved = delayed.promote_due(queue, NOW)

    assert moved == 0
    assert queue.dequeue(timeout=1) is None
    assert delayed.pending() == 1


def test_a_due_job_is_promoted_onto_the_work_queue_intact():
    delayed, queue = make_pair()
    delayed.schedule(JOB, NOW - timedelta(seconds=1))

    moved = delayed.promote_due(queue, NOW)

    assert moved == 1
    assert queue.dequeue(timeout=1) == JOB
    assert delayed.pending() == 0


def test_a_job_due_exactly_now_is_promoted():
    delayed, queue = make_pair()
    delayed.schedule(JOB, NOW)

    assert delayed.promote_due(queue, NOW) == 1


def test_promoting_twice_does_not_duplicate_the_job():
    """Two workers sweeping at once must not both enqueue the same check."""
    delayed, queue = make_pair()
    delayed.schedule(JOB, NOW - timedelta(seconds=1))

    first = delayed.promote_due(queue, NOW)
    second = delayed.promote_due(queue, NOW)

    assert (first, second) == (1, 0)
    assert queue.dequeue(timeout=1) == JOB
    assert queue.dequeue(timeout=1) is None


def test_only_due_jobs_are_promoted_when_several_are_waiting():
    delayed, queue = make_pair()
    delayed.schedule({"event_id": "due"}, NOW - timedelta(minutes=1))
    delayed.schedule({"event_id": "later"}, NOW + timedelta(minutes=30))

    moved = delayed.promote_due(queue, NOW)

    assert moved == 1
    assert queue.dequeue(timeout=1) == {"event_id": "due"}
    assert delayed.pending() == 1


def test_promotion_is_capped_by_the_limit():
    delayed, queue = make_pair()
    for index in range(5):
        delayed.schedule({"event_id": f"e{index}"}, NOW - timedelta(minutes=1))

    assert delayed.promote_due(queue, NOW, limit=2) == 2
    assert delayed.pending() == 3


def test_rescheduling_the_same_job_moves_its_due_time_instead_of_duplicating():
    delayed, queue = make_pair()
    delayed.schedule(JOB, NOW + timedelta(minutes=10))
    delayed.schedule(JOB, NOW - timedelta(seconds=1))

    assert delayed.pending() == 1
    assert delayed.promote_due(queue, NOW) == 1
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest tests/test_delayed_queue.py -v`
Expected: FAIL with `ImportError: cannot import name 'DelayedQueue'`

- [ ] **Step 3: Write minimal implementation**

Append to `app/common/queue.py`:

```python
from datetime import datetime


class DelayedQueue:
    """A Redis sorted set used as a timer. Score is the due time, as a unix stamp.

    This is how an open event gets looked at again without any worker holding
    state or sleeping (P3): the due time lives in Redis, and whichever worker
    sweeps next promotes the job onto the normal work queue.
    """

    def __init__(self, redis_client: Any, key: str):
        self._redis = redis_client
        self._key = key

    def schedule(self, job: dict, due_at: datetime) -> None:
        # sort_keys makes the member deterministic, so rescheduling the same job
        # updates its due time rather than leaving a second copy behind.
        self._redis.zadd(self._key, {json.dumps(job, sort_keys=True): due_at.timestamp()})

    def promote_due(self, target: "JobQueue", now: datetime, limit: int = 100) -> int:
        due = self._redis.zrangebyscore(
            self._key, "-inf", now.timestamp(), start=0, num=limit
        )
        moved = 0
        for member in due:
            # Only the caller whose ZREM actually removed the member may enqueue
            # it; a concurrent sweeper gets 0 and skips. This is the whole
            # concurrency story for the timer.
            if self._redis.zrem(self._key, member):
                target.enqueue(json.loads(member))
                moved += 1
        return moved

    def pending(self) -> int:
        return int(self._redis.zcard(self._key))
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest tests/test_delayed_queue.py tests/test_queue.py -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add app/common/queue.py tests/test_delayed_queue.py
git commit -m "feat: DelayedQueue for scheduling the next check-in"
```

---

### Task 8: Deciding when the next check is due, and scheduling it

**Files:**
- Create: `app/worker/check_in_schedule.py`
- Modify: `app/worker/handlers.py`
- Test: `tests/test_check_in_schedule.py`, `tests/test_worker.py`

**Interfaces:**
- Consumes: `Settings` (Task 1), `parse_ts` (Task 2), `OPEN_STATUSES` (Task 6), `DelayedQueue` (Task 7).
- Produces:
  - `next_check_in_due(event: dict | None, job_status: str, now: datetime, settings) -> datetime | None`
  - `process_event_job(job: dict, agent, delayed=None, settings=None, now=None) -> None` — same behaviour as today when `delayed` is `None`.
  - `CONTINUING_STATUSES = frozenset({"started", "in_progress"})`

- [ ] **Step 1: Write the failing test**

Create `tests/test_check_in_schedule.py`:

```python
from datetime import datetime, timedelta, timezone

from app.worker.check_in_schedule import next_check_in_due
from tests.fakes import make_settings

UTC = timezone.utc
NOW = datetime(2026, 10, 4, 21, 0, tzinfo=UTC)
SETTINGS = make_settings()


def event(status="started", started_at=NOW - timedelta(minutes=20)):
    return {"status": status, "started_at": started_at.isoformat()}


def test_a_started_event_schedules_the_first_check_one_interval_out():
    due = next_check_in_due(event(), "started", NOW, SETTINGS)

    assert due == NOW + timedelta(seconds=SETTINGS.check_in_interval_seconds)


def test_an_in_progress_check_schedules_the_next_one():
    due = next_check_in_due(event(), "in_progress", NOW, SETTINGS)

    assert due == NOW + timedelta(seconds=SETTINGS.check_in_interval_seconds)


def test_an_ended_event_stops_the_chain():
    assert next_check_in_due(event(status="ended"), "in_progress", NOW, SETTINGS) is None


def test_an_expired_event_stops_the_chain():
    assert next_check_in_due(event(status="expired"), "in_progress", NOW, SETTINGS) is None


def test_a_confirmed_event_keeps_checking():
    """Auto-detected events the user confirmed are open too (Phase 3)."""
    assert next_check_in_due(event(status="confirmed"), "in_progress", NOW, SETTINGS) is not None


def test_an_ended_job_does_not_schedule_anything():
    assert next_check_in_due(event(), "ended", NOW, SETTINGS) is None


def test_a_missing_event_schedules_nothing():
    assert next_check_in_due(None, "in_progress", NOW, SETTINGS) is None


def test_an_event_past_the_maximum_duration_stops_the_chain():
    """Regression: a user who forgot to tap stop must not be checked forever."""
    forgotten = event(started_at=NOW - timedelta(seconds=SETTINGS.check_in_max_seconds + 1))

    assert next_check_in_due(forgotten, "in_progress", NOW, SETTINGS) is None


def test_an_event_just_inside_the_maximum_duration_still_schedules():
    nearly = event(started_at=NOW - timedelta(seconds=SETTINGS.check_in_max_seconds - 60))

    assert next_check_in_due(nearly, "in_progress", NOW, SETTINGS) is not None


def test_a_naive_started_at_does_not_raise():
    """Regression: naive vs aware comparison is a TypeError, not a wrong number."""
    naive = {"status": "started", "started_at": "2026-10-04T20:40:00"}

    assert next_check_in_due(naive, "in_progress", NOW, SETTINGS) is not None


def test_an_unparseable_started_at_stops_the_chain():
    assert next_check_in_due(
        {"status": "started", "started_at": "nonsense"}, "in_progress", NOW, SETTINGS
    ) is None
```

Append to `tests/test_worker.py`:

```python
from datetime import datetime, timedelta, timezone

from tests.fakes import make_settings

UTC = timezone.utc
SCHEDULE_NOW = datetime(2026, 10, 4, 21, 0, tzinfo=UTC)
OPEN_EVENT = {"status": "started", "started_at": (SCHEDULE_NOW - timedelta(minutes=5)).isoformat()}


class SpyDelayed:
    def __init__(self):
        self.scheduled = []

    def schedule(self, job, due_at):
        self.scheduled.append((job, due_at))


class EventAgent:
    """Returns the state a real graph run returns, including the loaded event."""

    def __init__(self, event):
        self._event = event
        self.calls = []

    def invoke(self, state):
        self.calls.append(state)
        return {**state, "event": self._event}


def test_a_started_job_schedules_the_first_check_in():
    delayed, agent = SpyDelayed(), EventAgent(OPEN_EVENT)
    settings = make_settings()

    process_event_job(
        {"event_id": "e1", "user_id": "u1", "status": "started"},
        agent, delayed=delayed, settings=settings, now=SCHEDULE_NOW,
    )

    assert len(delayed.scheduled) == 1
    job, due_at = delayed.scheduled[0]
    assert job == {"event_id": "e1", "user_id": "u1", "status": "in_progress"}
    assert due_at == SCHEDULE_NOW + timedelta(seconds=settings.check_in_interval_seconds)


def test_an_in_progress_job_reschedules_itself():
    delayed, agent = SpyDelayed(), EventAgent(OPEN_EVENT)

    process_event_job(
        {"event_id": "e1", "user_id": "u1", "status": "in_progress"},
        agent, delayed=delayed, settings=make_settings(), now=SCHEDULE_NOW,
    )

    assert [j["status"] for j, _ in delayed.scheduled] == ["in_progress"]


def test_an_ended_event_stops_rescheduling():
    delayed = SpyDelayed()
    agent = EventAgent({"status": "ended", "started_at": OPEN_EVENT["started_at"]})

    process_event_job(
        {"event_id": "e1", "user_id": "u1", "status": "in_progress"},
        agent, delayed=delayed, settings=make_settings(), now=SCHEDULE_NOW,
    )

    assert delayed.scheduled == []


def test_scheduling_is_skipped_entirely_when_no_delayed_queue_is_configured():
    agent = EventAgent(OPEN_EVENT)

    process_event_job({"event_id": "e1", "user_id": "u1", "status": "started"}, agent)

    assert len(agent.calls) == 1


def test_a_failing_agent_does_not_schedule_a_follow_up():
    delayed = SpyDelayed()

    process_event_job(
        {"event_id": "e1", "user_id": "u1", "status": "started"},
        FakeAgent(fail=True), delayed=delayed, settings=make_settings(), now=SCHEDULE_NOW,
    )

    assert delayed.scheduled == []


def test_a_failing_scheduler_does_not_break_the_job():
    class BoomDelayed:
        def schedule(self, job, due_at):
            raise ConnectionError("redis gone")

    process_event_job(  # must not raise
        {"event_id": "e1", "user_id": "u1", "status": "started"},
        EventAgent(OPEN_EVENT), delayed=BoomDelayed(),
        settings=make_settings(), now=SCHEDULE_NOW,
    )
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pytest tests/test_check_in_schedule.py tests/test_worker.py -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'app.worker.check_in_schedule'`

- [ ] **Step 3: Write minimal implementation**

Create `app/worker/check_in_schedule.py`:

```python
"""When — if ever — to look at an open event again.

A pure decision, separate from the queue and the agent, because "stop checking"
is the condition that keeps a forgotten event from being examined forever.
"""

from datetime import datetime, timedelta

from app.agent.graph import OPEN_STATUSES
from app.common.timeparse import parse_ts

# Job statuses that continue the timer chain. `ended` runs the full analysis and
# deliberately schedules nothing.
CONTINUING_STATUSES = frozenset({"started", "in_progress"})


def next_check_in_due(
    event: dict | None, job_status: str, now: datetime, settings
) -> datetime | None:
    if event is None or job_status not in CONTINUING_STATUSES:
        return None
    if event.get("status") not in OPEN_STATUSES:
        return None
    started_at = parse_ts(event.get("started_at"))
    if started_at is None:
        return None
    if (now - started_at).total_seconds() >= settings.check_in_max_seconds:
        return None
    return now + timedelta(seconds=settings.check_in_interval_seconds)
```

Rewrite `app/worker/handlers.py`:

```python
from datetime import datetime, timezone
from typing import Any

from app.common.logging_config import get_logger, log_context
from app.worker.check_in_schedule import next_check_in_due

logger = get_logger(__name__)


def process_event_job(
    job: dict,
    agent: Any,
    delayed: Any = None,
    settings: Any = None,
    now: datetime | None = None,
) -> None:
    user_id = job.get("user_id")
    event_id = job.get("event_id")
    context = log_context(user_id=user_id, event_id=event_id)
    try:
        result = agent.invoke(
            {"user_id": user_id, "event_id": event_id, "status": job.get("status")}
        )
        logger.info(f"job processed {context}")
    except Exception:
        # No follow-up is scheduled on failure: a webhook retry re-enters the
        # chain, and rescheduling off a failed run would compound the error.
        logger.exception(f"job failed {context}")
        return

    if delayed is None or settings is None:
        return
    try:
        now = now or datetime.now(timezone.utc)
        due_at = next_check_in_due(
            (result or {}).get("event"), job.get("status") or "", now, settings
        )
        if due_at is None:
            return
        delayed.schedule(
            {"event_id": event_id, "user_id": user_id, "status": "in_progress"}, due_at
        )
        logger.info(f"check-in scheduled {context} due_at={due_at.isoformat()}")
    except Exception:
        # A timer we failed to set is a missed check-in, not a failed job.
        logger.exception(f"scheduling the next check-in failed {context}")
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `pytest tests/test_check_in_schedule.py tests/test_worker.py -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add app/worker/check_in_schedule.py app/worker/handlers.py tests/test_check_in_schedule.py tests/test_worker.py
git commit -m "feat: schedule the next check-in and stop at the duration cap"
```

---

### Task 9: Wire the timer into the worker loop

**Files:**
- Modify: `app/worker/main.py:16-44`
- Test: `tests/test_worker.py`

**Interfaces:**
- Consumes: `DelayedQueue` (Task 7), `process_event_job` (Task 8).
- Produces: `process_one(queue, agent, timeout=5, delayed=None, settings=None) -> bool` — promotes due delayed jobs before reading the work queue.

- [ ] **Step 1: Write the failing test**

Append to `tests/test_worker.py`:

```python
class PromotingDelayed:
    def __init__(self, to_promote=0):
        self._to_promote = to_promote
        self.promotions = []
        self.scheduled = []

    def promote_due(self, target, now, limit=100):
        self.promotions.append(now)
        return self._to_promote

    def schedule(self, job, due_at):
        self.scheduled.append((job, due_at))


def test_process_one_sweeps_the_delayed_queue_before_reading_work():
    delayed, agent = PromotingDelayed(to_promote=1), FakeAgent()

    process_one(StubQueue([JOB]), agent, timeout=1, delayed=delayed,
                settings=make_settings())

    assert len(delayed.promotions) == 1
    assert len(agent.calls) == 1


def test_process_one_still_sweeps_when_there_is_no_work():
    delayed = PromotingDelayed()

    handled = process_one(StubQueue([]), FakeAgent(), timeout=1, delayed=delayed,
                          settings=make_settings())

    assert handled is False
    assert len(delayed.promotions) == 1


def test_a_failing_sweep_does_not_stop_the_worker_from_working():
    class BoomDelayed:
        def promote_due(self, target, now, limit=100):
            raise ConnectionError("redis gone")

        def schedule(self, job, due_at):
            pass

    agent = FakeAgent()

    handled = process_one(StubQueue([JOB]), agent, timeout=1, delayed=BoomDelayed(),
                          settings=make_settings())

    assert handled is True
    assert len(agent.calls) == 1


def test_run_builds_a_delayed_queue_from_the_configured_key():
    from app.worker import main as worker_main

    with patch.object(worker_main.redis.Redis, "from_url"), \
         patch.object(worker_main, "get_supabase_client"), \
         patch.object(worker_main, "get_narration_model", return_value=None), \
         patch.object(worker_main, "build_agent"), \
         patch.object(worker_main, "DelayedQueue") as mock_delayed, \
         patch.object(worker_main, "process_one", side_effect=KeyboardInterrupt):
        try:
            worker_main.run()
        except KeyboardInterrupt:
            pass

        args, _ = mock_delayed.call_args
        assert args[1] == "events:delayed"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pytest tests/test_worker.py -v`
Expected: FAIL with `TypeError: process_one() got an unexpected keyword argument 'delayed'`

- [ ] **Step 3: Write minimal implementation**

Rewrite `app/worker/main.py`:

```python
from datetime import datetime, timezone
from typing import Any

import redis

from app.agent.graph import build_agent
from app.common.config import get_settings
from app.common.context_loader import ContextLoader
from app.common.llm import get_narration_model
from app.common.logging_config import configure_logging, get_logger
from app.common.queue import DelayedQueue, JobQueue
from app.common.supabase_client import get_supabase_client
from app.worker.handlers import process_event_job

logger = get_logger(__name__)


def process_one(
    queue: Any, agent: Any, timeout: int = 5, delayed: Any = None, settings: Any = None
) -> bool:
    # Sweep first: a due check-in has to reach the work queue before we block on
    # reading it, or it waits a whole empty poll for no reason.
    if delayed is not None:
        try:
            promoted = delayed.promote_due(queue, datetime.now(timezone.utc))
            if promoted:
                logger.info(f"promoted {promoted} due check-in(s)")
        except Exception:
            # A missed sweep delays a check-in by one tick; it must never stop
            # the worker from doing ordinary work.
            logger.exception("promoting due check-ins failed, will retry next tick")
    try:
        job = queue.dequeue(timeout=timeout)
    except Exception:
        logger.exception("dequeue failed, will retry next tick")
        return False
    if job is None:
        return False
    process_event_job(job, agent, delayed=delayed, settings=settings)
    return True


def run() -> None:
    configure_logging()
    settings = get_settings()
    # socket_timeout must comfortably exceed BRPOP's blocking timeout (below),
    # or the client can give up waiting for Redis's reply right as it arrives.
    redis_client = redis.Redis.from_url(settings.redis_url, socket_timeout=30)
    queue = JobQueue(redis_client, settings.queue_name)
    delayed = DelayedQueue(redis_client, settings.delayed_queue_name)
    supabase = get_supabase_client()
    llm = get_narration_model(settings)
    agent = build_agent(ContextLoader(supabase), llm, supabase)
    logger.info(
        f"worker started llm={'on' if llm else 'off (fallback summaries)'} "
        f"check_in_interval={settings.check_in_interval_seconds}s"
    )
    while True:
        process_one(queue, agent, delayed=delayed, settings=settings)


if __name__ == "__main__":
    run()
```

- [ ] **Step 4: Run the whole suite**

Run: `pytest -q`
Expected: PASS — every test in the suite, including the pre-existing
`test_run_configures_socket_timeout_with_margin_over_dequeue_timeout`.

- [ ] **Step 5: Commit**

```bash
git add app/worker/main.py tests/test_worker.py
git commit -m "feat: worker promotes due check-ins each tick"
```

---

## Manual verification

After Task 9, prove the loop closes end to end against the dev harness:

```bash
# 1. Apply the migration
psql "$SUPABASE_DB_URL" -f db/004_check_ins.sql

# 2. Shorten the timer so a check happens in seconds, not minutes
export CHECK_IN_INTERVAL_SECONDS=60  # 60 is the clamped floor
export CHECK_IN_MIN_ELAPSED_SECONDS=0

# 3. Start redis, the gateway and the worker (docker-compose.yml)
docker compose up -d redis
python -m app.worker.main &

# 4. Insert an open sauna event for the dev user and seed readings
psql "$SUPABASE_DB_URL" -f db/dev_harness.sql
```

Expected in the worker log, in order: `job processed` for the `started` job,
`check-in scheduled … due_at=…`, then roughly 60 s later `promoted 1 due
check-in(s)` followed by either `prediction saved … kind=check_in:hr_elevated`
or `nothing to say mid-event`. Tapping stop must produce
`kind=analysis` and no further `check-in scheduled` line.
