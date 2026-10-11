# The prototype, inventoried

**What this is:** a reference appendix to
[the demo-parity programme](2026-10-11-demo-parity-programme.md). The prototype
lives in a separate repository (`github.com/anshumanastronaut/telomy`, read at
commit `acf01f0`) that nothing in this repo depends on, so this file records what
is in it — every screen, every backend module, the API surface and the design
tokens — at the level a phase prompt needs. It is a description, not a
specification: where this file and a phase prompt disagree, the prompt wins.

**Shape of it:** Expo SDK 57 / React Native 0.86 / expo-router over FastAPI and
SQLite. 73 screens, 16 shared components, 30 backend modules (9,854 lines), 154
REST routes, 46 tables, one profile (`pid = 1`), OTP accepting `000000`, and
120 days of seeded data with causal effects planted in it.

---

## 1. Member screens

The tab bar is six: Home, Vault, Therapy, Plan, Sinc, Profile.

| Screen | What it is |
|---|---|
| Home | greeting, longevity-age dial with "How this is calculated", domain cards, key biomarker, next action, Sinc's read today, disease-prediction card, activity card, quick actions (log event, log meal, talk to Sinc, breathe, twin), pinned metrics, last 7 days, **Vault Rewind** (the same home screen as of 1 week / 1 month / 3 months ago) |
| Vault | panels, markers, risk map, derived values, insights, timeline |
| Therapy | what's working for you · **no reliable signal yet** · upcoming at the centre · recent sessions |
| Plan (`sessions`) | action plan from your results, protocols, checklist |
| Sinc | chat, headed "I read your whole Vault before I answer" |
| Profile | plan, consents, family, emergency, devices, settings |
| `longevity` | the dial's detail: over time, what moves your number, other clocks in your Vault |
| `marker/[id]` | where you sit, Sinc's read, every result, what could change this, connected patterns |
| `signal/[id]` | a wearable metric: what moves it in your data, manual entry |
| `domain/[key]` | one pillar and its related patterns |
| `insight/[id]` | the insight, **receipts**, evidence, clinician sign-off |
| `report/[id]` · `review/[id]` | a lab report, and the member's own review of it |
| `upload` | add a report: pick → parse → **verify** → save to Vault |
| `imaging` | imaging records |
| `tests` | tests & scans catalogue, personalised, with prices |
| `completeness` | what is missing from the Vault and what it would unlock |
| `predict` · `risks` | validated risk equations, what-ifs, risk map |
| `twin` | the digital twin, its 10-year and 24-hour projections, "did the twin see it coming?", the mirror |
| `therapies` · `therapy/[id]` | catalogue; then what happens inside your body, your response measured, research behind it |
| `therapy-plan` | build a plan, checkpoints, **left out for safety** |
| `session/[id]` | what happened inside, quick check-in, the science |
| `rx` | your personal stack: supplements & Formulas, medicines to discuss, already taking, **blocked for your safety**, **not offered and why** |
| `meds` | medications and doses |
| `routine` | my routine, parsed from plain language |
| `activities` · `activity/[id]` | custom activity types; log a session, history |
| `activity` | activity & recovery: vitals vs baseline, exercise last 9 weeks |
| `log` | log an event or a meal |
| `voice` | talk to Sinc, voice stress, "always-on mode (how it will work)" |
| `nutrition` · `menu` · `goals` | meals and trends; menu with swaps; macro goals |
| `studies` | start an N-of-1 ABAB study; your studies |
| `environment` | what your city does to you; per +10 µg/m³ PM2.5 in your own data; same person, two cities |
| `brief` | the specialist pack: PDF and FHIR bundle |
| `monthly` | monthly report: this month vs last, predicted risk, priorities |
| `notes` | TL;DR and top 3 priorities |
| `queue` | what of mine is awaiting clinician review |
| `consult` · `care` · `plans` | book a consult, Telomy Care clinicians, subscription plans |
| `family` | invite someone, scoped shares, **access log** |
| `consent` | per-purpose consent with history |
| `emergency` | emergency card |
| `memory` | what Sinc remembers |
| `pins` | choose pinned metrics |
| `notifications` · `nudges` | tray; proactive nudges |
| `marketplace` · `browse` · `menu` | catalogue and navigation |
| `breathe` | a timed breathing session, always dark, large type |
| `onboarding` · `welcome` | connect a wearable → what may Telomy do → where should we start → "I'm Sinc" |
| `protocols` | activate a protocol |

## 2. Doctor screens

| Screen | What it is |
|---|---|
| `doctor/index` | Today: needs attention, next clinic consultations |
| `doctor/work` | the work queue in five segments — reports · drafts · consults · therapy plans · Rx & supplements. Every sign requires a note; Rx items can be dropped and doses edited before signing |
| `doctor/patients` | the panel, priority-ordered |
| `patient/[id]` | centre therapies & what's working, key values, clinician notes & top priorities, clinical notes, recent centre visits |
| `monthly?doctor=1` | the monthly report, to sign |
| `brief` | the same pre-clinic brief the member can generate |

## 3. Centre screens

| Screen | What it is |
|---|---|
| `centre/index` | revenue this month vs last, sessions, members, active in 30 days, no-shows, today's bookings, utilisation per service, **members at risk**, not seen in 30 days |
| `centre/floor` | the live therapy floor: who is in session, phase, HR/HRV/skin/SpO₂ with sparklines, elapsed progress, safety tier, staff-check alarms, up next, machines by room with status and next service — refreshes every 15 s |
| `centre/bookings` | bookings and status transitions, new booking |
| `centre/members` | members who share |
| `centre/services` | service catalogue and prices |
| `centre-research` | "what your machines do to people": therapy response phenotypes, every therapy every session, **model check against the literature** |

There is no admin role. That surface is designed in
[F9](F9-handoff-prompt.md), not ported.

## 4. Component vocabulary

Sixteen components build all 73 screens (`mobile/src/ui/`):

`T` (one scale: h1, h3, body, small, label, num) · `Screen` · `Card` (tone:
teal / copper) · `Row` · `Section` · `Chip` · `StatusChip` · **`Prov`**
(source · when · confidence) · **`ConfBar`** · `Stat` · `Button` (primary,
secondary, ghost, danger, copper) · `Segmented` · `ListRow` · `Divider` ·
`Empty` · `Loading` · `ErrorState` · `Toast`.

Charts: `Sparkline`, `LineChart`, `Bars`, `Dial` (the longevity age, with a
confidence arc), `Ring`, `StackBar`. Therapy-specific: `SessionChart` with phase
bands, `PhaseLegend`, `VerdictChip`, `SafetyChip`, `HsaiCard`. Clinical:
`InsightCard`, `PatientRow`, `PredictionCards`.

**Tokens.** Teal `#1F5C4E` — identical to
[app_colors.dart](../../mobile/lib/app/theme/app_colors.dart) — as science;
copper `#A9643A` as the human counterweight; Cloud Dancer `#F0EEE9` canvas, ink
`#1B1C1A`; a full status ramp with soft backgrounds (optimal, in range, out of
range, risk variant, typical, detected, not detected, awaiting clinician,
signed, rejected, not reviewed); complete dark mode; spacing 4/8/12/16/20/24/32/40;
radii 6/10/14/20/pill. Inter for UI, Fraunces as the display serif, the wordmark
typeface only in the logo and splash.

## 5. Backend modules

| Module | Lines | Owns |
|---|---|---|
| `main.py` | 1762 | the 154 routes |
| `therapy.py` | 1051 | catalogue, screening, sessions, verdicts, plans, live floor, phenotypes, HSAI |
| `engine.py` | 987 | PhenoAge, domain scores, event effects (OLS + Benjamini–Hochberg + split-half), lagged correlations, cross-panel rules, lab × wearable links, insights, completeness |
| `rx.py` | 415 | Formulas, supplements, medicines, IVs, DDInter interactions, plans, e-prescription, tracking |
| `twin.py` | 402 | 21-variable twin, simulate, 24-hour twin, mirror |
| `routine.py` | 390 | free text → weekly schedule, adherence |
| `physio.py` | 388 | in-session physiology priors, analytics, safety tiers, literature validation |
| `voice.py` | 347 | transcription, intent → action, voice-stress acoustics |
| `seed.py` | 322 | the 120 days of test data — **and the planted causal effects** |
| `features.py` · `derived.py` | 520 | wearable features, derived markers |
| `sinc.py` | 255 | chat with citations, drafts for clinician |
| `catalog*.py` | 572 | markers, panels, zones, evidence grades, retest intervals |
| `roles.py` | 243 | accounts, patient cards, priority, doctor and centre views |
| `labparse.py` | 235 | PDF → markers, panel classification by vote |
| `activities.py` | 234 | custom activity types, sessions, baselines |
| `devices.py` | 224 | device registry, keys, channels, telemetry, alarms |
| `diagnostics.py` | 213 | tests & scans catalogue, recommendations, gaps |
| `plans.py` | 207 | subscriptions, monthly reports, consults |
| `predict.py` | 203 | PREVENT 2024, PCE, ADA, FIB-4, KFRE, what-ifs |
| `food.py` · `exposome.py` | 356 | meal matching; air, UV, weather by city |
| `summaries.py` | 168 | deterministic report and patient summaries |
| `brief.py` | 134 | specialist brief PDF + FHIR-shaped bundle |
| `evidence.py` | 100 | citations per rule and marker |
| `tools/` | — | device simulator, MQTT bridge |

## 6. API surface, grouped

154 routes. Member: `/home` `/today` `/dashboard` `/longevity` `/vault/*`
`/signals*` `/insights*` `/predict*` `/risks` `/twin*` `/therapy/*` `/sessions*`
`/rx/*` `/meds*` `/routine*` `/activities*` `/events` `/meals*` `/nutrition/*`
`/menu*` `/tests*` `/imaging` `/documents*` `/labs/parse|save` `/reports*`
`/completeness` `/environment*` `/studies` `/brief*` `/monthly-reports*`
`/consults` `/appointments*` `/clinicians` `/plans` `/subscription` `/shares*`
`/consents*` `/memories*` `/pins` `/notifications*` `/nudges` `/action-plan`
`/protocols*` `/profile` `/sinc/*` `/voice/*` `/evidence/*` `/calculators`.
Doctor: `/doctor/today|work|patients*` `/care/queue` `/clinician-notes`
`/reports/{id}/review` `/monthly-reports/{p}/sign` `/consults/{id}/complete`
`/therapy/plans/{id}/decide` `/rx/plans/{id}/decide` `/predict/patient/{id}`.
Centre: `/centre/dashboard|members|services*|bookings*|floor|devices*|research/*|therapy-outcomes`.
Devices: `/devices/{id}/telemetry` `/devices/channels`
`/therapy/sessions/{id}/samples`. Auth: `/auth/otp/send|verify` `/accounts`.

## 7. What the inventory does not vouch for

- **The seeded effects are planted.** `seed.py` embeds alcohol → HRV −9 ms,
  sauna → deep sleep +0.25 h, a magnesium ABAB effect, and deliberately no
  effect for HBOT, red light, compression, H₂ and IV. The engine finding them is
  a correctness proof, not evidence.
- **Physiology is simulated.** `physio.py` predicts what happens inside a
  machine from literature priors; `GET /physio/validation` checks the priors
  against 11 published target ranges. No session in that repository was measured.
- **There is no authorisation.** The role is a string in device storage, the OTP
  is `000000`, and every query is for `pid = 1`.
- **HSAI, voice stress and the twin are unvalidated indices.** The prototype's
  own clinical-safety document labels them wellness indices and decision aids,
  and requires simulated values to be labelled wherever they appear. That
  document is the best thing in the repository and its rules are carried into
  the programme as decision 5 and decision 6.
