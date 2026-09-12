# Detector — Low-Level Design

**Date:** 2026-09-12
**Status:** Draft for review
**Scope:** Continuous feature computation and automatic event detection from
wearable telemetry.

---

## 1. Purpose and Boundaries

The detector answers exactly one question: **"did something happen?"**

It does not interpret, explain, or advise. Its sole output is a row in the
`events` table — the identical row shape a button press produces. It has no
knowledge of the agent, no connection to it, and no shared code with it. Delete
the detector entirely and the manual flow keeps working.

### 1.1 Two Decisions That Define This Component

**The detector runs on the backend, not the phone.**

On-device detection is tempting — the phone already has the sensor stream over
BLE. It breaks down in practice: continuous inference drains battery; detection
logic can only be updated by shipping an app release through store review; it
stops the moment the app is backgrounded or the phone sleeps; and quality varies
across iOS/Android and device generations. Detection logic must be tunable on a
Tuesday afternoon and live for everyone by Tuesday evening.

The phone's job stays narrow: pull data over BLE, upload in batches.

**The detector is not an agent and never calls an LLM.**

An LLM detector would run inference over a continuous numeric stream, 24/7, for
every user simultaneously — catastrophically expensive, slow, and the wrong tool
entirely. *"Did heart rate deviate from this person's baseline by more than two
standard deviations while the motion signature matched pattern X?"* is
arithmetic, not reasoning.

> **The split:** the detector answers *"did something happen?"* with math.
> The agent answers *"what does it mean for this person?"* with reasoning.
> Cheap and always-on vs. expensive and event-triggered.

## 2. Problem Framing

This is **multivariate time-series classification** — the Human Activity
Recognition (HAR) problem domain. It is explicitly *not* an NLP problem; there
is no language anywhere in the sensor path. (Voice event logging *is* NLP, but
that is a separate component writing to the same table — see Platform HLD §3.)

Naming it correctly matters: it points at the right techniques, the right
evaluation methodology, and the right known failure modes.

## 3. Pipeline

```
Ring/band ──BLE──▶ Phone ──batched upload──▶ Supabase: telemetry_raw
                                                       │
                                             (new rows accumulate)
                                                       ▼
                                        ┌────────────────────────────┐
                                        │     DETECTOR WORKER        │
                                        │   60-second tick loop      │
                                        │   sharded by user_id       │
                                        └────────────────────────────┘
                                                       │
                              per-user rolling window + baselines in Redis
                                                       │
                                          confidence > threshold?
                                                       ▼
                                    INSERT events (status='candidate')
                                                       │
                                  ── existing webhook → queue → agent ──
```

## 4. The Detection Loop

A **sharded watermark poll** — simple, restart-safe, horizontally scalable.

```python
# every 60 seconds, for each user in this replica's shard:

watermark = read(detector_state.last_processed_ts, user_id)

rows = fetch(telemetry_raw,
             where=(user_id == uid) & (ts > watermark))

if not rows:
    continue

features = compute_features(rows)            # shared module — see §8
write(telemetry_features, features)

window = redis.push_and_trim(f"win:{uid}", features, keep="60min")
baselines = redis.get_or_load(f"base:{uid}") # refreshed daily

if not baseline_ready(uid):
    advance_watermark(uid, rows.max_ts)
    continue                                  # warm-up period

result = evaluate(window, baselines)          # rules or model — see §6

if result.confidence > threshold(result.event_type):
    insert_candidate_event(uid, result)

advance_watermark(uid, rows.max_ts)
```

### 4.1 Why Each Piece Exists

**Watermark.** A crashed or redeployed worker resumes exactly where it stopped —
no gaps, no reprocessing. Stored in Postgres (`detector_state`), not Redis, so
it survives cache loss.

**Sharding by `hash(user_id) % replica_count`.** Each user is owned by exactly
one replica at a time. Without this, two workers see the same telemetry and emit
duplicate candidate events. This is the reason the detector can scale
horizontally at all.

**Redis rolling window.** Keeps the loop cheap: evaluation runs against in-memory
state, so Postgres traffic is one bounded read and one write per user per tick
rather than repeated history scans.

**Baselines cached in Redis, refreshed daily.** They change on the scale of
weeks; re-reading them every tick is pure waste.

**Warm-up gate.** A new user has no baseline, and deviation-based detection is
meaningless without one. Detection stays off until `baseline_ready`.

### 4.2 Tick Interval

The 60-second tick sets the detection latency floor: worst case, an event is
noticed about a minute after its signal appears. For eating, drinking, sauna, or
exercise this is entirely acceptable. If a specific event type later needs
faster detection, shorten the tick **for that shard** — no redesign required.

## 5. Personal Baselines

**Absolute thresholds do not work for health data.** A resting heart rate of 85
is alarming for an endurance athlete and unremarkable for someone else. Every
signal is therefore measured as *deviation from that individual's own
established baseline*.

```sql
user_baselines
  user_id, metric, mean, std, computed_at, sample_days
```

| Property | Decision |
|---|---|
| Computation | Nightly batch job (scheduler, `batch` lane) |
| Window | Trailing 14–30 days |
| Exclusions | Periods inside known events — baselines must reflect *normal*, not *event* physiology |
| Minimum data | ~7 days before `baseline_ready = true` |
| Storage | Postgres source of truth; Redis cache refreshed daily |

The exclusion rule is easy to overlook and matters: if a user's drinking sessions
are folded into their baseline, the baseline drifts toward the thing being
detected, and detection degrades over time.

## 6. Detection Logic — Three Phases

The logic matures in stages, and **Phase 1 is mandatory** because on day one
there is zero training data.

### Phase 1 — Rules over derived features

Hand-written thresholds on baseline-relative features:

```
alcohol_candidate IF
    hr_delta_baseline      > +15%
AND sustained_duration     > 10 min
AND motion_variance        < low_threshold
AND temp_delta_baseline    > +0.3°C
AND time_of_day            IN evening_window
→ confidence 0.6
```

Crude, but it ships, it is fully explainable when wrong, and — critically —
**every candidate it raises gets confirmed or rejected by a real user.** That is
how the training set is manufactured.

### Phase 2 — Gradient-boosted classifier

Once labels accumulate (100–200 seeded test events plus real users' confirm/reject
taps), train **XGBoost or LightGBM on windowed features**.

For this data regime this is not a compromise — it is the correct choice:
excellent on tabular time-series features with modest data, trains in seconds,
infers in single-digit milliseconds, needs no GPU, and exposes feature
importances so a misfire can be explained.

### Phase 3 — Sequence models

Only if Phase 2 plateaus **and** substantially more data exists. Do not plan for
this; earn your way to it.

### 6.1 Feature Set

Per rolling window, per sensor channel:

| Group | Features |
|---|---|
| Distribution | mean, std, min, max, median |
| Trend | slope, delta vs. window start |
| **Baseline-relative** | `(value − baseline.mean) / baseline.std` — **the most important group** |
| Motion | energy, variance, dominant frequency, coarse motion class |
| Temporal | time of day, day of week, time since last event |
| Contextual | delta vs. preceding 30 minutes |

## 7. Evaluation Methodology

Two traps here produce *fake* accuracy that looks fine until production.

### 7.1 Split by user, never by window

If windows from the same person appear in both training and test sets, the model
memorises that individual's physiology and reports ~95% accuracy, then collapses
on a real new user.

> **Hold out entire people.** The test set must contain only users the model has
> never seen. This is the most common mistake in this field and it feels fine
> right up until production.

### 7.2 Accuracy is a meaningless metric here

Across a full day, "nothing notable is happening" is well over 95% of windows. A
model that always predicts "nothing" scores brilliantly and is useless.

| Do track | Do not track |
|---|---|
| Precision per event class | Overall accuracy |
| Recall per event class | |
| False-positive rate per user per day | |
| Time-to-detection after true onset | |

**Hard negatives must be mined explicitly.** Climbing stairs should be a labelled
negative for "smoking", or it becomes a permanent false positive.

### 7.3 Precision over recall, early on

If the app asks *"are you smoking?"* while the user is climbing stairs, trust
evaporates immediately and the feature gets disabled.

Confidence thresholds start **deliberately high** and are lowered only as the
detector proves itself. Better to miss events in month one than to be annoying.

## 8. Training Data Extraction

The training set is a **join between `events` and `telemetry_features`**:

```
for each labelled event:
    window_rows = telemetry_features
                  WHERE user_id = event.user_id
                    AND minute_ts BETWEEN event.started_at AND event.ended_at

    trim first 1–2 min and last 1–2 min     # boundary buffer — see §8.1
    emit windows tagged event_type

negatives:
    feature rows falling inside no event at all
    + explicitly mined hard negatives
```

### 8.1 Label Noise at Boundaries

Testers do not press "start" at the exact moment an activity begins — they start
eating and remember the button four minutes later. "Stop" is worse.

Two mitigations:

1. **Retroactive start** in the app ("I started about 5 minutes ago") — FR-1.4.
2. **Boundary buffer:** drop the first and last 1–2 minutes of every labelled
   window and train on the confident middle.

### 8.2 Training/Serving Skew — the silent killer

If features are computed even slightly differently at training time versus
detection time, model performance degrades silently and the cause takes weeks to
find.

> **Mandatory:** one shared `features/` module, imported by both the detector
> worker and the training extraction job. Feature definitions are versioned; a
> model records the feature-version it was trained against and refuses to load
> against a mismatched version.

Extraction is a **versioned, reproducible job** — not a notebook — because it
runs on every retrain.

## 9. Data Requirements — Honest Assessment

**The unit of training data is the window, not the event.** A 40-minute session
sampled at 1 Hz with 60-second windows sliding every 10 seconds yields ~240
labelled windows. Two hundred events becomes tens of thousands of windows. On
raw volume, this is fine.

**What actually governs generalisation is examples per class, across diverse
people.** Two hundred events spread over 15 event types is ~13 per type — and if
they come from four testers, the model learns *those four people*, not the
phenomenon.

| Metric | Requirement |
|---|---|
| Instances per event type | **30–50+** |
| Distinct people per event type | As many as possible — this dominates |
| Initial target event count | **4–6 types**, not 15 |

> **Recommendation:** concentrate all labelling effort on 4–6 Tier A events.
> Ship a detector that nails sleep, exercise, alcohol, and sauna rather than one
> that is mediocre at fifteen things. Tier C events (smoking, red light therapy,
> specific foods) remain fully supported as manual/voice input and remain
> valuable agent context — they are simply not detector targets.

See PRD §8 for the full Tier A/B/C triage.

## 10. Candidate Events and the Confirmation Loop

Auto-detected events are written with `status='candidate'`, not `'started'`:

```json
{
  "user_id": "a3d1e8c0-...",
  "event_type": "alcohol",
  "status": "candidate",
  "source": "auto",
  "confidence": 0.78,
  "detected_at": "2026-09-12T21:14:00Z"
}
```

`candidate` status does real work:

```
candidate → agent runs in REDUCED-COST mode
          → app asks: "Are you drinking? Your HR and temp are changing."
          │
          ├── user confirms → status='confirmed' → full agent run
          └── user rejects  → status='rejected'  → labelled negative
```

Three benefits at once: no tokens burned on false positives; the user retains a
sense of control rather than being surveilled; and **every tap is a labelled
training sample.**

### 10.1 Event Termination Without a Stop Button

Nothing tells an auto-detected event that it ended. Two mechanisms:

1. **Cessation detection** — signals returning to baseline.
2. **Hard timeout** — `expected_max_duration` per event type as a backstop. An
   "eating" event still open after three hours is a bug, not a long lunch.

## 11. Continuous Improvement

```
user confirms/rejects candidate
          ↓
   labelled example written
          ↓
   scheduled retrain (weekly/monthly, batch lane)
          ↓
   evaluate against FROZEN held-out user set
          ↓
   promote only if metrics improve → version + deploy
          ↓
   (rollback available — models are versioned)
```

### 11.1 The Feedback Loop Is Self-Biased

Users are only ever asked about windows the *current* model already flagged — so
the system never learns about events it silently misses. Left alone, the model
calcifies around its own blind spots.

**Correction:** periodically sample a small number of random *unflagged* windows
and ask users "did anything happen around here?" Cheap, and it is the only thing
that surfaces false negatives.

## 12. Shadow Mode

Before any candidate event reaches a user, run the detector in **shadow mode**:
it evaluates and logs what it *would* have raised, writing to a separate
`detector_shadow` table instead of `events`.

This allows measurement of real-world precision and false-positive-per-user-per-day
rates against live data, with zero user-visible risk, and it is the gate for
turning detection on per event type.

## 13. Failure Modes and Mitigations

| Failure | Consequence | Mitigation |
|---|---|---|
| Replica restart mid-tick | Gap in processing | Watermark in Postgres; resume exactly |
| Two replicas on one user | Duplicate candidates | Consistent hash sharding; one owner per user |
| Redis flush | Rolling windows lost | Rebuild from `telemetry_features`; watermark unaffected |
| Device offline / gap in data | Stale window, spurious detection | Gap detection — suppress evaluation across discontinuities |
| Baseline polluted by event periods | Detection degrades over time | Exclude known event windows from baseline computation |
| New user, no baseline | Meaningless deviations | `baseline_ready` gate; ~7-day warm-up |
| Feature definition change | Training/serving skew | Shared module + feature versioning; model refuses mismatched version |
| Threshold too low | Annoying false positives, feature disabled | Shadow mode first; start high, lower slowly |

## 14. Open Questions

1. **Actual device capability** — exact channels, sampling rate, and API access.
   This determines which Tier A events are genuinely detectable and drives
   storage sizing. *Blocking for implementation.*
2. Which 4–6 event types are the initial detector targets?
3. Acceptable false-positive budget per user per day (proposed: **< 1**).
4. Retraining cadence — weekly or monthly.
5. Should the warm-up period use population-average baselines as a stopgap, or
   stay fully disabled until personal baselines exist?

## 15. Related Documents

- [PRD](./2026-09-12-prd.md) — §8 event taxonomy, §10 risks
- [Platform High-Level Design](./2026-09-12-platform-hld.md) — §4 data model
- [Agent Low-Level Design](./2026-09-12-agent-lld.md)
