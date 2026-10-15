# F12 Therapy Spine Design

**Status:** Approved for implementation

**Date:** 2026-10-15

**Scope:** Therapy catalogue, deterministic contraindication screening, signed plans, booking/session lifecycle, subjective check-ins, and honest personalised verdicts

## 1. Context

F8 introduced deterministic event-effect analytics, F10 introduced clinician review and signatures, and F11 completed centre tenancy and operational visibility. Therapy is still represented mainly as a generic event. F12 makes therapy a first-class, auditable domain while preserving the existing `events` contract used by analytics.

F12 is the therapy spine. Machine telemetry, live physiology, in-session alarms, and delivered-dose automation remain F13 work.

## 2. Goals

1. Publish a versioned catalogue of roughly 25 therapy modalities with plain-language purpose, contraindications, dose schema, and indicative pricing.
2. Evaluate contraindications deterministically from structured Vault facts.
3. Refuse unsafe booking and session start through every server-side path, including when risk appears after a plan was signed.
4. Allow patients to propose plans and doctors to create, revise, approve, and sign them through the existing F10 signature path.
5. Keep Centre Owners operational: they may configure offerings and schedule eligible signed items, but cannot alter clinical content.
6. Record prescribed and delivered dose separately.
7. Store one or two immediate post-session subjective answers.
8. Produce all six honest verdicts: Helped, Promising, Possible negative, No reliable signal, Too early, and In-session only.
9. Preserve the P1 event contract by emitting a normal therapy event for completed sessions.
10. Deliver mobile screens that make uncertainty and safety refusal first-class outcomes rather than errors or empty states.

## 3. Non-goals

- Machine/device registry, device keys, machine telemetry, live floor, or in-session safety tiers.
- HSAI or any new unvalidated composite clinical score.
- Automated payments; all prices remain explicitly indicative.
- Response phenotypes or centre-level causal outcome claims before sufficient real session volume exists.
- Centre Owner or Super Admin clinical authorship, plan signature, or mutation of signed content.

## 4. Architectural Choice

F12 uses a hybrid model:

- Normalized tables hold catalogue content, centre offerings, plans, safety checks, bookings/sessions, doses, and check-ins.
- A completed session writes the existing `events` row shape so current context loading and analytics continue to operate without a parallel inference stack.
- The shared analytics implementation computes verdict inputs for both API and agent callers.
- The existing clinical draft and signature mechanism binds approved plan content to its immutable hash.

An events-only design was rejected because signatures, safety re-checks, prescribed-versus-delivered dose, and operational lifecycle would become unauditable JSON conventions. A separate therapy analytics subsystem was rejected because it would duplicate F8 computation and violate the one-implementation rule.

## 5. Roles and Authority

### Patient

- Browse available catalogue entries and centre offerings.
- View safety information and indicative prices.
- Propose a therapy plan for themself.
- View doctor revisions, exclusions, and signed plans.
- Start an eligible booked session and complete the post-session check-in.
- View their own sessions and verdicts.

### Doctor

- Access assigned patients only.
- Create or revise a plan, review a patient proposal, omit unsafe items, and sign the final plan.
- View session history and deterministic evidence for assigned patients.
- Never override a current hard contraindication.

### Centre Owner

- Configure whether a catalogue modality is offered and maintain its indicative local price.
- Schedule signed, currently safe plan items for patients in the centre.
- Update operational booking fields only.
- Cannot author clinical dose, dismiss a contraindication, revise a plan, or sign clinical content.

### Super Admin

- Manage global catalogue publication and administrative records.
- Read all data through audited access.
- Cannot author or sign a patient plan, change its clinical contents, or override safety.

## 6. Data Model

### 6.1 Structured profile safety facts

Add structured pregnancy status with an explicit vocabulary such as `unknown`, `not_pregnant`, `pregnant`, and `postpartum`. Safety-critical decisions must not parse free text. Existing structured conditions, medications, allergies, and observations remain deterministic inputs.

### 6.2 Therapy catalogue

`therapy_catalogue` stores stable modality identity and versioned, clinician-reviewed content:

- slug, display name, category, summary, intended experience
- dose schema and allowed units
- contraindication rule identifiers
- evidence/status metadata and content hash
- publication state and version

The initial seeded set targets approximately 25 modalities, including cryotherapy, HBOT, mild HBOT, sauna, infrared sauna, cold plunge, contrast therapy, red-light/PBM, PEMF, hydrogen inhalation, IHHT, EWOT, compression, vibroacoustic therapy, float therapy, and IV therapy variants.

### 6.3 Centre offerings

`centre_therapy_offerings` links a centre to a catalogue entry and stores availability, indicative price, currency, duration defaults, and operational notes. Every API and mobile rendering labels the price as indicative.

### 6.4 Plans

`therapy_plans` contains patient, centre/clinic context, proposer, status, version, and signature linkage. `therapy_plan_items` contains the modality, frequency, prescribed dose, ordering, and disposition.

Unsafe proposed items are retained for audit but receive an excluded disposition and a member-visible reason labelled “Left out for safety.” They are not included in the signable active regimen.

A content hash binds the exact plan version and active items to the existing clinician signature. Editing creates a new version; signed versions are immutable.

### 6.5 Safety checks

`therapy_safety_checks` is append-only and records:

- patient, modality, plan/item/session context
- evaluation point: proposal, signing, booking, or start
- catalogue/rule version
- structured fact snapshot references
- eligible/refused result
- stable reason codes and member-safe explanations
- evaluation timestamp

The latest check never replaces prior results.

### 6.6 Sessions

`therapy_service_sessions` records booking and execution lifecycle. The name is
deliberately distinct from the pre-existing legacy `therapy_sessions` Vault
journal table, which remains untouched for backward compatibility:

- patient, centre, offering, signed plan item
- scheduled, started, completed, cancelled, or refused state
- prescribed dose snapshot
- delivered dose entered at completion
- timestamps, actor, and refusal/cancellation reason
- emitted event identifier

Prescribed and delivered dose use separately validated JSON documents tied to the catalogue dose schema. A session may record partial delivery without rewriting the prescription.

### 6.7 Check-ins

`therapy_checkins` stores at most two versioned questions and answers linked to the session. F12 asks only an immediate perceived-effect question and an optional tolerability question. This is session evidence, not a general survey system.

## 7. Deterministic Safety Engine

Safety rules live beside the existing deterministic safety layer and consume only structured facts loaded through the scoped context loader. They do not call an LLM.

The initial hard-refusal matrix includes:

- pregnancy for disallowed modalities
- pacemaker/implanted electronic device for affected electromagnetic modalities
- uncontrolled blood pressure and recent cardiac event where applicable
- Raynaud disease for cold exposure
- untreated pneumothorax for HBOT
- DVT for compression
- photosensitising medication for red-light/PBM
- G6PD deficiency for high-dose IV vitamin C
- alcohol use today for sauna/heat exposure
- coronary plaque/high-risk coronary disease for whole-body cryotherapy

Rule identifiers and catalogue versions are persisted so a historical decision can be reproduced.

Safety is checked at proposal for explanation, before signature, at booking, and immediately before start. Booking and start are hard transactional gates. A previously signed plan never overrides a new contraindication.

## 8. Session and Event Flow

1. Patient or doctor creates a draft plan.
2. The server evaluates every item and records immutable safety checks.
3. Unsafe items remain visible as excluded with their reasons.
4. A verified assigned doctor reviews the safe plan version and signs its content hash.
5. Centre Owner or authorized patient books a signed active item; the server re-checks safety in the same transaction.
6. At session start, the server re-checks safety again and refuses atomically if facts changed.
7. Completion records delivered dose and writes one idempotent therapy event using the common event contract.
8. The patient answers one or two check-in questions.
9. The shared effect engine recomputes the modality verdict when evidence changes.

Retries cannot create duplicate bookings, starts, completions, or event rows. Idempotency keys and unique constraints cover each transition.

## 9. Verdict Engine

The effect engine reuses F8 before/after windows, declared hypotheses, autocorrelation adjustment, confidence intervals, and Benjamini–Hochberg correction. It adds deterministic split-half replication and a presentation classification layer.

Classification order is explicit:

1. **In-session only** — usable subjective sessions exist but wearable outcome data is unavailable.
2. **Too early** — fewer than five eligible sessions.
3. **Helped** — beneficial direction, confidence interval excludes zero, passes FDR, and split-half replication agrees.
4. **Promising** — beneficial direction, raw `p < 0.01`, confidence interval excludes zero, and split-half replication agrees, but the result has not passed FDR.
5. **Possible negative** — adverse direction with sufficient negative evidence under the declared outcome rules.
6. **No reliable signal** — none of the above.

The exact negative threshold is encoded as a named deterministic policy, not inferred by language. Verdict output includes session count, effect estimate, confidence interval, p/q values when available, replication result, wearable coverage, and the next evidence milestone.

Downgrade behavior is mandatory: removing replication from a Helped fixture yields Promising; removing statistical significance yields No reliable signal. No verdict is sticky.

## 10. API and Mobile Surfaces

Gateway endpoints provide role-scoped catalogue/offering reads, plan proposal/review/signing, booking, session transitions, check-ins, and verdict retrieval. The verified JWT supplies the actor; request bodies never nominate the acting user.

Mobile adds:

- catalogue and modality detail
- clear contraindication/refusal presentation
- plan builder and doctor review state
- signed plan with a “Left out for safety” section
- booking and session start/finish flows
- short completion check-in
- six dedicated verdict states, especially useful Too early and No reliable signal screens

Every price carries an “Indicative” label. Every effect screen states that the result is an association in the member’s data, not proof of causation.

## 11. Security, Privacy, and Audit

- RLS and gateway checks enforce patient, assignment, and centre scope.
- Cross-user reads follow the F10/F11 audited gateway pattern.
- Service-role queries remain explicitly patient-scoped.
- Safety check inputs are referenced/minimized rather than copied as unrestricted clinical text.
- Signed plan versions, safety checks, and completed sessions are immutable; corrections append new records.
- Super Admin reads are audited and do not grant clinical mutation.
- Centre Owners never receive a safety override capability.

## 12. Failure Handling

- Missing or unknown safety-critical facts produce a safe refusal or explicit needs-review state according to the modality rule; they never silently pass.
- A stale plan version cannot be signed or booked.
- Concurrent lifecycle transitions use conditional updates and return the current state rather than duplicating work.
- Event emission is retryable and idempotent. A completed session that has not yet emitted its event is visible to reconciliation.
- Analytics failures do not change the session record; the UI shows evidence processing, not a positive result.

## 13. Verification and Acceptance

Automated tests must prove:

1. Every catalogue entry has required content, dose schema, contraindication mapping, and indicative-price behavior.
2. Each hard contraindication refuses both booking and start.
3. A contraindication added after signature still refuses the session.
4. A mixed plan signs only safe items and displays the unsafe item with its reason.
5. Prescribed and delivered dose remain distinct.
6. Completion emits exactly one correctly owned therapy event.
7. All six verdict fixtures classify correctly.
8. Helped downgrades to Promising without replication and to No reliable signal without significance.
9. A member without wearable coverage receives In-session only rather than an error.
10. Cross-role and cross-centre attempts return no protected data and cannot mutate clinical fields.
11. Centre Owner and Super Admin cannot sign or modify clinical plan content.
12. Backend tests, Flutter tests, and static analysis pass.

Device verification on Android covers catalogue browsing, refusal that cannot be bypassed, mixed-plan safety explanation, plan signing state, booking/start/finish, delivered dose, check-in, and all feasible verdict layouts. The build under test must be tied to a commit and APK hash.

## 14. Deferred Evidence Requirements

F13 consumes F12 sessions for in-session physiology and machine telemetry. Response phenotypes require enough repeated sessions per modality and patient to form stable within-person features; centre-level outcome evidence requires a predeclared minimum cohort, adequate wearable coverage, and confounder-aware aggregation. Until those thresholds are designed and met, the product shows session counts and individual evidence only, never a centre effectiveness ranking.
