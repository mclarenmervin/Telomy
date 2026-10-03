# Personalized activity report — design

Status: approved in conversation 2026-10-02, pending written review
Supersedes parts of: [2026-09-29 activity analysis agent design](2026-09-29-activity-analysis-agent-design.md)

## 1. Goal

Make the end-of-session report read as though the user's own doctor were talking to
them — warm, personal, honest — while staying strictly inside what a non-clinician
product may say. Show every signal the ring recorded, not a subset. Mark anything
concerning clearly, and give one route to act on it: booking a consultation.

The report today is accurate and safe but impersonal. "Asha's swimming session was
steady and controlled" is a description of a session, not of a person. It also shows
two metrics when the ring reports five, and it has no way to say "this one matters".

## 2. Scope

In scope: the report contract, severity computation, guardrails, the agent's prompt
and persona, and the Flutter report card.

Out of scope, deliberately:

- **Conversational chat about a report.** Agreed as phase 2. It inverts the auth model:
  the phone would call the agent directly, so the gateway must verify a Supabase JWT and
  derive `user_id` from the verified token rather than from a trusted queue job. That is
  a different threat model and deserves its own spec. It also benefits from going second,
  since it will reuse the severity rules and medication guardrail defined here.
- Live/in-session reporting. Still end-of-session only.
- Any change to how sessions are written or triggered.

## 3. Decisions

| # | Decision | Rationale |
|---|---|---|
| D1 | Persona is **doctor-like in manner, not in authority** | Resolves "feel like my own doctor" against "never diagnose". It observes and escalates; it does not name or treat conditions. |
| D2 | Severity is computed **in Python**, never by the model | Same reason the score is. Model-decided severity is non-reproducible and untestable; a bad generation becomes a missed warning. |
| D3 | Context is **tool-driven except where correctness depends on it** | See §4. Keeps the agent personal without making deterministic output depend on model discretion. |
| D4 | Escalation is **always present, in two tiers** | A quiet link on normal days; a highlighted card when a rule fires. One always-on banner becomes wallpaper; a conditional-only one strands users who want a doctor on an ordinary day. |
| D5 | **No phone number** in agent output | Cannot be changed without a redeploy, cannot vary by region, and would be wrong for most users. Deep-link to the existing `/consultations` flow instead. |
| D6 | Supplements are covered by the **medication guardrail** | They are the obvious workaround to a medication-only rule, and are less regulated. |
| D7 | Severity is conveyed by **colour, icon and word** | Colour alone fails for colour-blind users, and this is the signal where being missed matters most. |
| D8 | `schema_version` → 2, all new fields optional | An older app build ignores them; a newer build survives reports written before the change. |

## 4. Which context is loaded, and how

The rule: **anything a deterministic calculation or a safety rule depends on is
pre-loaded; everything that only colours the narrative is fetched by tool.**

Pre-loaded every run (unchanged from today):

| source | why it cannot be a tool |
|---|---|
| current session | the subject of the report |
| past sessions (90d window) | baseline, deltas and score are computed from them in Python |
| user profile | the name, needed by every personalized sentence; one cheap query |
| medications / safety facts | CLAUDE.md: safety-critical facts are fetched deterministically. On a skippable tool, a report will eventually comment on exertion while ignoring a beta-blocker. |

Tool-driven, at the model's discretion, with the prompt describing what exists and when
to reach for it:

- lab documents and reports
- body measurements (weight, resting heart rate, sleep duration)
- daily ring summaries (sleep, readiness)
- logged journal entries
- `compare_window` for a different history window

Budget: `max_llm_calls` rises from 2 to 3; `max_tool_calls` stays at 8. Expect 12–20s
per report, against 6–10s today. Acceptable because the agent runs in the background and
nobody is waiting on it.

## 5. Severity rules

Three levels, computed per metric and then rolled up to the report as the maximum.
Thresholds reuse constants already tuned during the 2026-09-29 safety review.

```
SPO2_DANGER_MIN      = 90.0   # existing, agent.py
SPO2_ATTENTION_MAX   = 95.0   # new: below this but at or above danger
HEART_RATE_DANGER_MAX = 200.0 # existing, agent.py
HR_ELEVATED_DELTA    = 15.0   # existing, insight_rules.py
```

| metric | `urgent` | `attention` |
|---|---|---|
| `spo2` | `min < 90` | `min < 95` |
| `heartRate` | `max > 200` | `delta >= +15` |
| `stress` | — | `delta >= +15` |
| `hrv` | — | `delta <= -15` |
| `steps` | — | — |

Note a correction to what was described in conversation: attention for SpO2 is
`< 95`, not `92–94`. The narrower band left 90–91 in neither bucket — below the
attention range but above the danger threshold — which would have silently dropped the
most concerning non-emergency readings.

`steps` never carries severity; it is a volume count, not a physiological signal.

The exercise-aware logic in `_exercise_danger` stays: elevated heart rate during
exercise is expected, which is why the danger threshold is 200 and not the event
agent's 150.

## 5.1 Where thresholds live

Thresholds are configurable at three tiers, chosen per threshold rather than uniformly.

**App level (environment), for all of them.** A single `app/common/thresholds.py` reads
each value from the environment with the default above, so they can be tuned without a
code deploy:

```
SPO2_DANGER_MIN, SPO2_ATTENTION_MAX, HEART_RATE_DANGER_MAX,
HR_ATTENTION_DELTA, STRESS_ATTENTION_DELTA, HRV_ATTENTION_DELTA
```

**Per user, only where physiology genuinely varies and we already hold the data.** The
one clear case is maximum heart rate: 195 bpm is unremarkable at 20 and alarming at 70, so
a flat 200 is crude. Where the profile has a date of birth, the danger threshold becomes
`220 - age`; where it does not, it falls back to `HEART_RATE_DANGER_MAX`.

**Never settable by the user.** A user who raises their own SpO2 danger threshold disables
the warning for exactly the person who needs it. These are physiological facts, not
preferences.

Note that the `attention` rules are *already* per-user: `delta >= +15` is measured against
that person's own baseline, computed from their own history. What the environment tunes is
sensitivity, not the reference point.

### Validation is mandatory

Each value is range-checked at startup. A typo such as `SPO2_DANGER_MIN=0` would otherwise
switch off the urgent warning silently, with nothing in any log to show it. Out-of-range
values fall back to the default and log at error level, and the effective thresholds are
logged once at worker start so a running deployment can be audited.

Accepted ranges: SpO2 thresholds 85-99, heart-rate danger 150-230, delta thresholds 5-50.

## 6. Report contract (schema v2)

```jsonc
{
  "schema_version": 2,
  "severity": "normal|attention|urgent",     // = max over metrics
  "metrics": [
    {
      "key": "spo2", "value": 93, "baseline": 97, "delta": -4,
      "direction": "worse",
      "severity": "attention",               // NEW — drives the row's colour
      "note": "Dipped below your usual range during this session."  // NEW
    }
  ],
  "escalation": {                            // NEW — always present
    "level": "routine|recommended|urgent",
    "title": "Book a consultation",
    "body": "…",
    "action": "book_consultation"
  },
  // unchanged: score, headline, sections, data_quality, history_used,
  //            data_gaps, insights, event_type, score_version
}
```

All five ring signals appear when present: `heartRate`, `hrv`, `spo2`, `stress`,
`steps`. A signal the ring did not report is omitted, never rendered as zero.

`escalation.level` maps from report severity: `normal` → `routine`,
`attention` → `recommended`, `urgent` → `urgent`. `title` and `body` are written
deterministically, not by the model, so the call to action cannot be softened by a
generation.

## 7. Guardrails

Existing, unchanged: diagnosis patterns, the data-not-instructions treatment of
user-supplied text, and `SAFE_FALLBACK` replacement on a trip.

Changed or added:

1. **Medication patterns extended to supplements** — vitamins, minerals, herbal
   remedies. Same action: replace the section, flag the report.
2. **Honesty rule** in the prompt: do not reassure where the data does not support it.
   Without it, a warm persona softens `attention` findings into nothing, which is the
   opposite of the intent.
3. **Severity consistency check**: if Python computed `attention` or `urgent`, the
   narrative must acknowledge it. A purely congratulatory report against a raised flag
   is rejected and replaced with deterministic prose.
4. The existing `ESCALATION_LINE` is now carried by the `escalation` block rather than
   appended to `watch_outs`, so it appears exactly once and in a place the UI can style.

### 7.1 Number verification must account for tool-sourced values

`verify_numbers` admits only figures traceable to the computed `analysis`. Once the
agent fetches labs or measurements via tools, it will legitimately cite numbers absent
from `analysis`, and every such report would raise `unverified_number`.

Fix: collect numeric values returned by tool calls during the run and add them to the
allowed set.

This is not cosmetic. Left unfixed, the flag fires on almost every richer report, stops
carrying information, and creates pressure to disable it — which is precisely how a
fabricated health number reaches a user.

## 8. Persona and prompt

Allowed:

> "Asha, your heart rate settled faster after this swim than it has in weeks — that is a
> real sign your fitness is moving. One thing I want to flag: your blood oxygen dipped
> lower than I would like to see. That is worth having someone look at properly."

Not allowed: naming a condition ("this suggests sleep apnoea"), recommending any
substance ("try magnesium"), or any comment on medication or dose.

Prompt changes:

- Voice: warm, second person, uses the name naturally rather than in every sentence.
- Connect this session to the person's wider context where it is known, and say when
  context was fetched and showed nothing relevant.
- State the honesty rule (§7, item 2) explicitly.
- Describe the available tools and when reaching for them is worthwhile, since context
  is now tool-driven (§4).
- The model is told the computed severity and must write consistently with it; it
  cannot raise or lower it.

Prompt-cache ordering is preserved: stable instructions first, per-session facts last.

## 9. App UI

Metrics become a vertical list, one row per reported signal. Chips cannot carry a
sentence, and every metric now has a note.

```
Heart rate        129 bpm  ↘ 7            normal
  Lower than your recent average — your pacing held steady.

Blood oxygen       93 %    ↘ 4         ⚠  attention
  Dipped below your usual range during this session.
```

Severity rendering: amber tint plus warning icon plus the word for `attention`; the
error colour, same treatment, for `urgent`. This needs one new theme token — the scheme
has `primary` and `error` but no warning colour — defined for light and dark mode.

Escalation:

- `routine` — a quiet text button beneath the footnote.
- `recommended` / `urgent` — a bordered card above the sections in the severity colour,
  carrying the backend's `title` and `body`, with a filled button.

Both deep-link to the existing `/consultations` route
(`mobile/lib/features/consultations/`), which already books through the marketplace and
stores a journal entry of kind `consultation`.

`ActivityReport` gains `severity`, per-metric `severity` and `note`, and `escalation`,
all optional, following the tolerant-parsing pattern already in that model.

## 10. Testing

Backend:

- severity rules at each threshold boundary, including the 90–94 SpO2 band
- `steps` never carries severity
- supplement guardrail trips and replaces
- severity consistency check rejects a congratulatory narrative against a raised flag
- tool-sourced numbers pass `verify_numbers`
- escalation level maps correctly from each severity

Flutter — currently there are no widget tests for the report card; these are the first:

- the three escalation states render
- a flagged metric row shows colour, icon and word
- a report missing the v2 fields still renders

## 11. Migration

No database migration. `predictions.analysis` is `jsonb`; new keys need no schema change,
and `kind` is unchanged.

A deployed older app build receiving a v2 report ignores the new fields and renders as it
does today. A new build receiving a v1 report shows no severity and a `routine`
escalation. Neither crashes.

## 12. Open items

- The `attention` thresholds are product judgement, not clinical guidance, and inherit
  the caveat already recorded in §20.2 of the 2026-09-29 spec: they want review by a
  clinician before this is used by real users.
- The heart-rate `attention` rule is a plain `delta >= +15` against the same-activity
  baseline. An earlier draft qualified this with "and no matching effort increase", which
  was dropped: it had no agreed definition, and because the baseline is already restricted
  to the same activity type, effort is largely controlled for already. If this proves
  noisy in practice, the qualifier is the first thing to reintroduce — with a definition.
