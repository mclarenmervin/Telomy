# Telomy — Combined Build Sequence

**Date:** 2026-10-06
**Sources merged:** `Telomy_10_Groundbreaking_USPs.pdf` (U01–U10) and
`Telomy_10_Features_To_Build_Next.pdf` (F01–F10), both 05-Oct-2026, plus the
engineering backlog in [healthagent/CLAUDE.md](../../healthagent/CLAUDE.md)
Build Order that neither document covers.
**Status column verified against the code on 2026-10-06**, not against the
documents' own claims.

---

## 1. Why this document exists

The two source documents were written independently and overlap in five places:
U02 and F03 are the same thread; U03 and F05 are the same thread; U09 gates
F10; U10 and F10 are two halves of one feature; U01 subsumes F08 and U06.
Sequenced separately they would be built twice.

They also share a blind spot. Both are product documents, and neither mentions
the platform work the features sit on — the telemetry pipeline, the REST
layer, the scheduler, the extraction worker. Two of the highest-value features
in the decks (F01 Provenance, F02 Confidence) cannot be built correctly until
a correctness bug in that layer is closed. A sequence that ignores it stalls in
week three.

This document merges the twenty items into **eight waves**, ordered by
dependency first and cost second.

## 2. Ground truth: what is already built

| Item | Status | Evidence |
|---|---|---|
| **U02 Event-tagging data model** | **Built** | `events` table, agent, mid-event check-ins, phone capture — proven in production 2026-10-04 |
| U01 Six-stream vault | Partial | Labs, wearable, life events, medications have tables. Imaging and clinic streams absent |
| U03 Sinc drafts → clinician signs | Partial | Deterministic guardrails, escalation flag, consultations screen. No sign-off workflow |
| U09 DPDP per-purpose consent | Partial | RLS and per-source toggles. No research/marketing/third-party consent |
| F01 Provenance chip | Primitive exists | `health_measurements.source` and `.quality` are populated on every row; no UI uses them |
| F03 Life-event overlay | Data model real | Was a flat journal list; now backed by real events with before/during/after deltas |
| Everything else | Not started | — |

**One correction to carry into any investor conversation.** U02 claims *"every
biomarker point carries its event-window context."* It does not, at storage
level: readings sit in `health_measurements` with no event reference, and the
window is computed at analysis time. The behaviour is real; the storage claim
is not. Wave 2 makes it true.

## 3. The sequence

### Wave 0 — Close what is already open (this week)

Not in either document. All three are live defects or live risk.

| # | Item | Why now |
|---|---|---|
| 0.1 | **Reset demo thresholds on Railway** | `CHECK_IN_MIN_ELAPSED_SECONDS=0` means a real user is interrupted after 60 seconds of data |
| 0.2 | **One source of truth for scores** | Readiness and Biological Age are computed in Dart on the phone *and* narrated from Python. They cannot agree. Everything in Wave 1 depends on a number having one definition |
| 0.3 | **Remove `demo_seed` rows** | ~2,700 synthetic readings on the demo user, after the investor demo |

0.2 is the real work: the deterministic REST endpoints from the platform Build
Order, step 4. It is unglamorous and it blocks the two highest-value features
in the roadmap, because a provenance chip on a number that has two definitions
is worse than no chip.

### Wave 1 — The trust layer (weeks 1–4)

**F01 Provenance chip → F02 Confidence gradient → F06 Open methods**

One thread, built in that order. Each is additive over a primitive that
already exists, which is why this wave is first despite not being the flashiest.

- **F01** — `source` and `quality` are already on every measurement row. This
  is a UI layer over existing data, and it structurally fixes the audit's P0
  (sample data blending into Biological Age): if every value is sourced,
  blending becomes visible.
- **F02** — promotes `coverage` and `confidence` from text to saturation. Needs
  F01's per-value sourcing to know what to desaturate.
- **F06** — "How this is calculated" opens the formula, the reference study,
  the known limits, the model version. Cheap once F01 and F02 have made the
  inputs legible.

**Exit test:** no number anywhere in the app can be read without also reading
where it came from and how sure we are.

### Wave 2 — The moat, finished (weeks 3–8, overlaps Wave 1)

**U02 completion → F03 Life-event overlay**

The half-built differentiator. Three pieces:

1. **Stamp `event_id` onto readings** inside an event window, so the storage
   claim in U02 becomes true and the overlay has an index to draw from.
2. **The longitudinal view** — U02's "30 days later the system shows the
   measurable effect." Today each event is analysed alone; nothing aggregates
   across repeats of the same event type. This is the sentence the decks sell.
3. **F03 overlay** — the vertical band on every biomarker chart.

**Why second, not first:** it is the deepest moat and the hardest to copy, but
it reads as a chart feature without Wave 1's trust layer underneath it. An
overlay claiming a causal link needs a visible confidence number next to it.

### Wave 3 — Revenue, and the end of fiction (weeks 5–10)

**F05 Pending-clinician queue → U03 Sinc sign-off**

`marketplace_catalog.dart` ships hardcoded listings at `price: 1499` with no
payment path. That is a release blocker today and a revenue stream after this
wave. F05 replaces the fake listings with a real one-tap review request routed
to the Bonphul network; U03 then turns that into the full drafts-then-signs
workflow the regulatory position depends on.

**Dependency:** needs Wave 1. A clinician signing off on a number with two
definitions is a liability, not a moat.

### Wave 4 — Distribution artifacts (weeks 9–12)

**F07 Specialist pack → F08 Vault completeness**

- **F07** replaces the `Clipboard.setData` export — a genuine privacy failure,
  since Samsung clipboard history retains it — with specialty-tailored,
  FHIR-compliant, QR-shareable PDFs. Fixes a P0 and becomes the clinic
  distribution motion.
- **F08** promotes the existing per-score `coverage` to a Vault-level number
  with a concrete list of what raises it. Small lift once Wave 1 has made
  coverage trustworthy.

### Wave 5 — Retention (weeks 11–14)

**F04 Daily reflection**

The qualitative slot the audit found misimplemented (asking for waist
circumference under "How you feel"). Small build, disproportionate retention
effect, and it becomes input to the agent: *"you mentioned a difficult meeting
on Tuesday — HRV reflected that evening."*

### Wave 6 — Platform depth (weeks 12–20)

**Document extraction → U01 six-stream vault → U06 imaging**

- **Document extraction** (Build Order step 7) is the missing ingest path.
  `ContextLoader.documents()` currently returns `unconfigured`. Every
  competitor has lab-PDF upload; Ultrahuman gave theirs away free as
  top-of-funnel. This is table stakes, not differentiation.
- **U01** is then mostly real: labs, wearable, life events, medications, clinic.
- **U06 DICOM** is the one nobody else has. Significant pipeline investment plus
  radiology partners — it earns its place here, not earlier.

### Wave 7 — Compounding assets (weeks 16–28)

**U09 consent → U10 Telomy Labs → F10 Preprint reader → U04 N-of-1 studies**

Strict dependency chain. No research consent means no ethical aggregate
research, which means no preprints, which means nothing for the preprint reader
to show. U04's N-of-1 trials need the same consent primitive plus the
longitudinal engine from Wave 2.

Start U09 early — it is a schema and consent-flow change, and retrofitting it
later is exactly the trap the deck says competitors are in.

### Wave 8 — The long bets (6+ months)

| Item | Note |
|---|---|
| **F09 / Household dashboard** | Needs U09's per-member consent. The strongest India-specific differentiator |
| **U07 Telomy Care (clinician SaaS)** | Needs Wave 3's clinician workflow proven with real doctors first |
| **U05 Telomy Halo** | Capital-intensive hardware, engineering locked, Phase 2 |
| **U08 Clinic-network distribution** | Not an engineering item. Gated on U07 |

## 4. The parallel platform track

These are not in either document and have no plan written. They do not block
Waves 1–5, but Wave 6 onward stalls without them.

| Item | Build Order step | Blocks |
|---|---|---|
| Deterministic REST endpoints | 4 | Wave 0.2 — **start now** |
| Telemetry ingest + feature pipeline | 3 | Scale beyond demo volume; the detector |
| Scheduler (digests, weekly reports, threshold alerts) | 6 | Retention; competitor parity on proactive nudges |
| Document extraction worker | 7 | Wave 6 |
| Voice event capture | 8 | — |
| Detector (auto-detected events) | 9 | The "effortless" story; blocked on the wearable decision |

**Open question that blocks two of these:** the PRD's *"which wearable?"* is
still unanswered. Sensor channels and sampling rates determine whether
detection is feasible at all, and how the telemetry tables should be sized.

## 5. Sequencing rationale in one paragraph

Trust before moat, moat before revenue, revenue before distribution,
distribution before compounding. Wave 1 is first not because it is the most
differentiated but because every later claim — a causal overlay, a clinician
signature, a specialist brief, a published preprint — is only as credible as
the provenance of the numbers underneath it. Wave 2 is the thing no competitor
can copy in a quarter and is already half-built, so it is cheap relative to its
value. Everything after that is ordered by what unblocks what.

## 6. Deliberately not sequenced

- **U08 clinic distribution** — an operator asset, not a build.
- **F02 before F01** — confidence without provenance is a colour with no
  referent.
- **Detector work** — until the wearable question is answered, any plan is a
  guess, and the PRD already flags training-data volume as the top risk.
