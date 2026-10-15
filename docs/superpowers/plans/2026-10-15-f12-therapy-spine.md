# F12 Therapy Spine Implementation Plan

> **For Codex:** Execute this plan task by task with strict test-first development. Do not start F13 machine telemetry or weaken a safety refusal to satisfy a UI path.

**Goal:** Make therapy a first-class, safely bookable and trackable object with signed plans, session evidence, and six honest verdicts.

**Architecture:** Add normalized Supabase records for catalogue offerings, plans, safety evaluations, and sessions. Keep `events` as the single analytics contract by emitting one idempotent event when a session completes. Reuse F10 signatures and F8 statistics; keep all classification and contraindication decisions deterministic.

**Tech Stack:** PostgreSQL/Supabase RLS, Python/FastAPI/Pydantic/Pytest, Flutter/Riverpod, existing fake Supabase test harness

---

## Task 1: Establish the F12 schema and RLS boundaries

**Files:**
- Create: `healthagent/db/029_therapy_spine.sql`
- Create: `healthagent/db/tests/therapy_spine_test.sql`
- Modify: `healthagent/tests/test_migrate.py`

**Test first:** Add SQL assertions for structured pregnancy status; therapy catalogue and centre offerings; versioned plan/items; append-only safety checks; sessions with separate prescribed/delivered doses; maximum-two check-ins; immutable signed/completed records; role and cross-centre RLS denial.

**Implement:** Add constrained tables, foreign keys, indexes, idempotency keys, updated-at behavior only where mutation is allowed, and explicit RLS policies following migrations 024–028. Do not create an admin clinical-mutation policy.

**Verify:**

```bash
cd healthagent
pytest tests/test_migrate.py -q
./scripts/test-db.sh db/tests/therapy_spine_test.sql
```

**Commit:** `feat: add therapy spine data model`

## Task 2: Expand and validate the operational catalogue

**Files:**
- Modify: `healthagent/app/analytics/data/therapies.v1.yaml`
- Modify: `healthagent/app/analytics/therapy_catalog.py`
- Modify: `healthagent/tests/test_therapy_effect.py`
- Create: `healthagent/tests/test_therapy_catalogue.py`

**Test first:** Require approximately 25 unique modalities, plain-language description, dose schema, contraindication IDs, event type, indicative-price-compatible metadata, and valid effect declarations only where evidence is declared. Assert unsafe or incomplete entries fail closed.

**Implement:** Split operational catalogue fields from optional reviewed effect hypotheses while retaining the current signed-effect fingerprint contract. Seed the required modalities without pretending every modality has a wearable-detectable acute effect.

**Verify:** `cd healthagent && pytest tests/test_therapy_catalogue.py tests/test_therapy_effect.py -q`

**Commit:** `feat: publish the versioned therapy catalogue`

## Task 3: Implement deterministic contraindication screening

**Files:**
- Create: `healthagent/app/analytics/therapy_safety.py`
- Modify: `healthagent/app/analytics/safety.py`
- Modify: `healthagent/app/common/context_loader.py`
- Modify: `healthagent/app/analytics/subject.py`
- Create: `healthagent/tests/test_therapy_safety.py`
- Modify: `healthagent/tests/test_subject.py`

**Test first:** Cover pregnancy, pacemaker, uncontrolled BP, recent cardiac event, Raynaud disease, untreated pneumothorax/HBOT, DVT/compression, photosensitising medicine/PBM, G6PD/IV vitamin C, alcohol today/sauna, and coronary plaque/cryo. Prove unknown required facts do not silently pass.

**Implement:** Load structured safety facts once, evaluate versioned rule IDs, and return stable refusal codes plus member-safe explanations. Remove pregnancy free-text inference from safety gating in favor of the structured profile field.

**Verify:** `cd healthagent && pytest tests/test_therapy_safety.py tests/test_safety.py tests/test_subject.py -q`

**Commit:** `feat: enforce therapy contraindication rules`

## Task 4: Build plan drafting and clinical signature integration

**Files:**
- Create: `healthagent/app/clinical/therapy_plans.py`
- Modify: `healthagent/app/clinical/drafts.py`
- Modify: `healthagent/app/clinical/queue_plan.py`
- Modify: `healthagent/app/gateway/api/doctor.py`
- Create: `healthagent/tests/test_therapy_plans.py`
- Modify: `healthagent/tests/test_clinical_queue_plan.py`
- Modify: `healthagent/tests/test_doctor_api.py`

**Test first:** Patient proposal, doctor-authored plan, assigned-doctor review, safe-item inclusion, unsafe-item exclusion with “Left out for safety,” immutable signed version, stale-hash refusal, and empty F10 `therapy_plans` queue becoming populated.

**Implement:** Build a signable plan snapshot and content hash using the existing clinical review primitives. Enforce that only a verified assigned doctor signs; Centre Owner and Super Admin are denied clinical mutation.

**Verify:** `cd healthagent && pytest tests/test_therapy_plans.py tests/test_clinical_queue_plan.py tests/test_doctor_api.py -q`

**Commit:** `feat: add signed therapy plans`

## Task 5: Add booking and session lifecycle with hard safety gates

**Files:**
- Create: `healthagent/app/clinical/therapy_sessions.py`
- Create: `healthagent/app/gateway/api/therapy_sessions.py`
- Modify: `healthagent/app/gateway/main.py`
- Modify: `healthagent/app/common/context_loader.py`
- Create: `healthagent/tests/test_therapy_sessions.py`
- Create: `healthagent/tests/test_therapy_session_api.py`

**Test first:** Booking refusal, start refusal, newly introduced contraindication after signing, valid state transitions, retry idempotency, prescribed/delivered dose mismatch preservation, maximum-two check-ins, patient ownership, centre scope, and exactly-one event emission on completion.

**Implement:** Add transactional application services for booking/start/finish. Re-run safety inside booking and start; never trust a client-provided eligibility result. Emit the P1 therapy event once and expose reconciliation state if emission is pending.

**Verify:** `cd healthagent && pytest tests/test_therapy_sessions.py tests/test_therapy_session_api.py tests/test_context_loader.py -q`

**Commit:** `feat: track safe therapy sessions`

## Task 6: Replace reported/withheld output with six reversible verdicts

**Files:**
- Modify: `healthagent/app/analytics/therapy_effect.py`
- Modify: `healthagent/app/analytics/statistics.py`
- Modify: `healthagent/tests/test_therapy_effect.py`
- Modify: `healthagent/tests/test_therapies_api.py`

**Test first:** One fixture for every verdict; split-half replication; Helped to Promising downgrade without replication; Helped to No reliable signal downgrade without significance; possible-negative policy; no-wearable In-session only; fewer-than-five Too early; evidence/provenance fields.

**Implement:** Reuse the existing one-sample/FDR functions, add deterministic split-half evaluation, and classify in the approved order. Return one verdict per modality/outcome with effect estimate, CI, p/q, replication, coverage, and next milestone. Preserve compatibility fields temporarily if existing mobile tests require a staged migration.

**Verify:** `cd healthagent && pytest tests/test_therapy_effect.py tests/test_therapies_api.py tests/test_correlations.py tests/test_statistics.py -q`

**Commit:** `feat: classify honest therapy verdicts`

## Task 7: Add patient and centre therapy APIs

**Files:**
- Modify: `healthagent/app/gateway/api/therapies.py`
- Modify: `healthagent/app/gateway/api/centre.py`
- Modify: `healthagent/app/gateway/centre_loader.py`
- Modify: `healthagent/app/gateway/main.py`
- Create: `healthagent/tests/test_therapy_catalogue_api.py`
- Create: `healthagent/tests/test_therapy_plan_api.py`
- Modify: `healthagent/tests/test_centre_api.py`

**Test first:** Patient self-scope, doctor assignment scope, centre operational scope, admin audited read-only behavior, cross-centre zero rows, catalogue/offering reads, indicative-price label contract, proposal, safe scheduling, and forbidden clinical mutation.

**Implement:** Keep routers thin and application services authoritative. Derive actor identity from JWT and validate every patient/centre relation server-side.

**Verify:** `cd healthagent && pytest tests/test_therapy_catalogue_api.py tests/test_therapy_plan_api.py tests/test_centre_api.py tests/test_security.py -q`

**Commit:** `feat: expose role-scoped therapy workflows`

## Task 8: Build the mobile catalogue and safety experience

**Files:**
- Create: `mobile/lib/features/therapies/models/therapy_catalogue.dart`
- Modify: `mobile/lib/features/therapies/data/therapy_repository.dart`
- Modify: `mobile/lib/features/therapies/providers/therapy_provider.dart`
- Create: `mobile/lib/features/therapies/screens/therapy_catalogue_screen.dart`
- Create: `mobile/lib/features/therapies/screens/therapy_detail_screen.dart`
- Create: `mobile/lib/features/therapies/widgets/safety_refusal_card.dart`
- Modify: `mobile/lib/app/router.dart`
- Create: `mobile/test/therapy_catalogue_test.dart`
- Create: `mobile/test/therapy_safety_refusal_test.dart`

**Test first:** Catalogue loading, indicative price wording, safety details, refusal button disabled with reason visible, and patient-only route behavior.

**Implement:** Use existing design tokens and responsive patterns. Safety refusal is a dedicated state and cannot be dismissed into an enabled booking/start action.

**Verify:** `cd mobile && flutter test test/therapy_catalogue_test.dart test/therapy_safety_refusal_test.dart && flutter analyze`

**Commit:** `feat: add therapy catalogue and safety screens`

## Task 9: Build mobile plans, sessions, and check-ins

**Files:**
- Create: `mobile/lib/features/therapies/models/therapy_plan.dart`
- Create: `mobile/lib/features/therapies/models/therapy_session.dart`
- Create: `mobile/lib/features/therapies/screens/therapy_plan_screen.dart`
- Create: `mobile/lib/features/therapies/screens/therapy_session_screen.dart`
- Create: `mobile/lib/features/therapies/widgets/therapy_checkin_sheet.dart`
- Modify: `mobile/lib/features/doctor/widgets/work_queue_segment.dart`
- Modify: `mobile/lib/features/doctor/screens/doctor_work_queue_screen.dart`
- Create: `mobile/test/therapy_plan_test.dart`
- Create: `mobile/test/therapy_session_test.dart`
- Modify: `mobile/test/doctor_workspace_test.dart`

**Test first:** Patient proposal, doctor review/sign state, unsafe item section, centre operational-only controls, booking/start/finish transitions, prescribed-versus-delivered rendering, and one/two-question limit.

**Implement:** Connect the F10 therapy-plan queue segment and preserve role shells. Do not add a Centre Owner clinical editing control.

**Verify:** `cd mobile && flutter test test/therapy_plan_test.dart test/therapy_session_test.dart test/doctor_workspace_test.dart && flutter analyze`

**Commit:** `feat: add therapy plan and session flows`

## Task 10: Render all verdicts and complete regression verification

**Files:**
- Modify: `mobile/lib/features/therapies/models/therapy_effect.dart`
- Modify: `mobile/lib/features/therapies/widgets/therapy_effects_section.dart`
- Modify: `mobile/test/therapy_effect_test.dart`
- Create: `docs/roadmap/F12-completion-report.md`

**Test first:** Dedicated copy/layout for all six states, with No reliable signal and Too early as complete screens, In-session only without an error treatment, downgrade fixture rendering, evidence provenance, and non-causal wording.

**Implement:** Replace positive-only reported/withheld presentation with the six-state contract while keeping accessibility, small-screen layout, and loading/error states distinct from honest negative evidence.

**Verify all:**

```bash
cd healthagent
pytest -q

cd ../mobile
flutter test
flutter analyze
```

Build and install the exact commit on the connected Android device or `Pixel_8`. Exercise catalogue, hard refusal, mixed safe/unsafe plan, doctor signature state, booking, start, completion with different delivered dose, check-in, and verdict screens. Capture commit, APK SHA-256, device, and sanitized results in the completion report.

**Commit:** `test: verify F12 therapy spine`

## Release gate

Push only after the full backend and Flutter suites pass, static analysis is clean, the worktree contains no unrelated changes, database migrations apply from a clean schema, and device verification proves the unsafe path cannot be bypassed. Push the completed branch to `staging` only when all F12 acceptance criteria are met.
