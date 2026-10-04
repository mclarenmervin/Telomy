# Mid-Event Check-Ins — Design

**Date:** 2026-10-04
**Status:** Draft for implementation
**Implements:** [PRD](../../specs/2026-09-12-prd.md) FR-3.2, FR-3.3, G3; NFR-1.2, NFR-4.1–4.3, NFR-5.2–5.3

---

## 1. Why

Today the event agent wakes up exactly twice: on `started` it writes a canned
acknowledgement without looking at any reading, and on `ended` it produces the
real analysis. Everything the user hears is therefore retrospective.

Every competing platform is retrospective too, by construction: none of them
knows an event is happening, so the safest thing they can do is average the
night and score it in the morning. The event tap is what buys us permission to
speak *during* the event. This design adds the third wake-up: while an event is
open, re-evaluate on a timer and speak only when a deterministic rule says
there is something worth saying.

## 2. Scope

**In:** a repeating timer per open event; a deterministic check-in rule over the
existing event analysis; one alert per reason per event; narration of a fired
rule; stop conditions.

**Out:** detection (Phase 3), push-notification delivery (the mobile app already
reads `predictions` over Realtime), new sensor math, per-user threshold
learning, voice.

## 3. Mechanism

```
tap start ──▶ events(status=started) ──▶ webhook ──▶ queue ──▶ worker
                                                                 │
                                           ack prediction ◀──────┤
                                                                 │
                                        schedule check in T+10m ─┘
                                                 │
                        ┌────────────────────────┴──────────────────┐
                        ▼                                           │
            delayed set (Redis zset, score = due time)              │
                        │ worker promotes due jobs each tick        │
                        ▼                                           │
        agent runs with status=in_progress                          │
                        │                                           │
        analyze_event(start … now) → evaluate_check_in()            │
                        │                                           │
         ┌──────────────┴───────────────┐                           │
         ▼                              ▼                           │
   nothing fired                   reason fired                     │
   (silent, no LLM)         narrate → guardrails → persist          │
         │                     kind="check_in:<reason>"             │
         └──────────────┬───────────────┘                           │
                        └──── schedule next check ──────────────────┘
                             (unless a stop condition holds)

tap stop ──▶ events(status=ended) ──▶ full analysis, no reschedule
```

### 3.1 The timer

A Redis sorted set (`events:delayed`) keyed by due timestamp. The worker, each
tick, promotes every job whose score is in the past into the normal job queue,
then does its usual blocking read. No new process, no in-memory timers, so P3
(stateless workers) and P4 (ingest never coupled to compute) hold unchanged.

A job is promoted by whichever worker wins `ZREM`; the loser skips it. That is
the whole concurrency story.

### 3.2 The decision

`evaluate_check_in` is a pure function over the analysis dict that
`analyze_event` already produces (called with `end = now`, so the "during"
window is start→now and the "after" window is empty). It returns at most one
reason, or `None`.

Priority order, first match wins:

| Reason | Fires when |
|---|---|
| `spo2_low` | `spo2.during_mean < spo2_danger_min` (90%) |
| `hr_elevated` | `heartRate.delta_during ≥ check_in_hr_delta` (12 bpm) **and** `z_during ≥ check_in_hr_z` (2.0) |
| `hrv_suppressed` | HRV down `≥ check_in_hrv_drop_pct` (25%) from `baseline_mean` |

One reason per check keeps the notification focused and makes the dedupe key
obvious. The `z` requirement on heart rate is what makes the rule *personal*: a
12 bpm rise only fires if it is also two standard deviations outside this
person's own spread, so a naturally variable person is not nagged.

**Silence guards** — any of these returns `None` before any rule is considered:

- `data_quality == "none"` — no readings near the window, nothing to say.
- `elapsed < check_in_min_elapsed_seconds` (15 min) — too early to mean anything.
- No baseline for the metric (`baseline_mean`/`z_during` is `None`) — a new user
  must never be alerted against a baseline that does not exist. This guard is
  **per rule, not global**: `hr_elevated` and `hrv_suppressed` both require a
  baseline, while `spo2_low` deliberately does not. Below 90% is dangerous at
  any personal baseline, so suppressing it until a baseline exists would be the
  worse failure. The cost is that a single noisy SpO2 sample can interrupt a
  brand-new user.
- The reason is already in `already_sent` for this event.

Silence is the expected outcome of most checks and is not a failure.

### 3.3 Dedupe

The prediction is written with `kind = "check_in:<reason>"`, so the existing
`unique (event_id, kind)` constraint makes a duplicate structurally impossible,
and `already_sent` (read from `predictions` for that event) means we never even
pay for an LLM call for a reason we have already delivered. A *different* reason
may still fire later in the same event.

### 3.4 Stop conditions

`next_check_in_due` returns `None` — ending the chain — when:

- the event row is gone or belongs to someone else (the loader is user-scoped),
- `event.status` is not open (`started`, `confirmed`); `ended`, `expired` and
  `rejected` all stop the timer,
- elapsed ≥ `check_in_max_seconds` (8 h), which bounds a user who forgot to tap
  stop,
- the job's own status is not one that continues the chain.

### 3.5 Cost

A check that fires nothing costs **no LLM inference at all**, per NFR-5.2/5.3;
the LLM is called only after the rule has already decided to speak. A 3-hour
event at a 10-minute interval is 18 checks and, at most, 3 LLM calls (one per
distinct reason).

The database cost is not negligible, and an earlier draft of this document
understated it. Each check calls `load_readings`, which widens the window to
the full 14-day baseline span for all four tracked metrics, so the baseline is
rebuilt from raw rows on every tick. Two mitigations: the node reads
`sent_check_in_reasons` **first** and returns before any analytics once every
reason has been delivered; and the whole chain stops at the duration cap.
Caching the per-event baseline between ticks — the baseline window is identical
across a chain, only the `during` slice moves — is the obvious next
optimisation and is deliberately not in this phase.

## 4. Safety

- The decision to alert is a unit-tested rule; the LLM only words it (NFR-4.3).
- `apply_guardrails` runs after narration exactly as it does for the `ended`
  path, including the mandatory escalation line on dangerous values (NFR-4.2).
- The check-in prompt adds no new capability: same "no diagnosis, no
  medication" system constraints, present tense.
- Every check-in has a deterministic fallback sentence, so an LLM outage
  degrades to a plainer alert rather than silence.

## 5. Thresholds

v1 values, deliberately strict — a demo-visible false alarm costs more than a
missed one. All are env-overridable and range-validated in
`app/common/thresholds.py`, so a typo falls back loudly instead of silently
disabling an alert.

| Setting | Default | Range |
|---|---|---|
| `CHECK_IN_HR_DELTA` | 12.0 bpm | 5–50 |
| `CHECK_IN_HR_Z` | 2.0 σ | 1–6 |
| `CHECK_IN_HRV_DROP_PCT` | 25.0 % | 10–60 |
| `CHECK_IN_MIN_ELAPSED_SECONDS` | 900 s | 0–7200 |
| `CHECK_IN_INTERVAL_SECONDS` | 600 s | `Settings` |
| `CHECK_IN_MAX_SECONDS` | 28800 s | `Settings` |

The three rule parameters and the min-elapsed guard are validated `Thresholds`;
the two timer parameters are plain `Settings`, because a bad interval delays a
check-in while a bad rule parameter silently disables an alert.

## 6. Known limitations

- **Thresholds are guesses.** They are tuned against synthetic data only. Real
  tuning needs the labelled events Phase 1 is meant to produce.
- **Interval is fixed**, not adaptive to event type. A sauna session and a
  five-hour dinner get the same cadence.
- **No delivery confirmation.** We write the prediction; whether the phone
  surfaced it is the app's business.
- **Sync latency is invisible to us.** If the ring batches every 15 minutes, a
  10-minute check may see nothing new. The silence guards make that harmless,
  but it caps how "live" the feature can feel on a given device.
