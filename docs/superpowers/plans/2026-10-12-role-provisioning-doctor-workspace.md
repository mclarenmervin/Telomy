# Role Provisioning and Doctor Workspace Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver production account provisioning for four roles and an end-to-end F10 Doctor workspace in which verified doctors see only assigned patients and can review, note, and sign immutable clinical work.

**Architecture:** Supabase Auth authenticates every role. PostgreSQL stores current roles, centre memberships, verification, assignments, consent, invitations, and append-only audit facts; gateway endpoints derive the actor from the JWT and re-check current database state before every cross-user operation. Flutter consumes role-scoped gateway APIs, while existing clinical state-machine and signature gates remain the only path to signed delivery.

**Tech Stack:** PostgreSQL/Supabase Auth and RLS, Python 3/FastAPI/Pydantic/Supabase client, Flutter/Dart/Riverpod/Dio/GoRouter, pytest, pgTAP-style SQL tests, Flutter widget/unit tests.

**Spec:** `docs/superpowers/specs/2026-10-12-role-provisioning-doctor-workspace-design.md`

## Global Constraints

- Database role values stay exactly `admin`, `centre`, `doctor`, and `member`; UI labels are Super Admin, Centre Owner, Doctor, and Patient.
- Supabase Auth proves identity; authorization is resolved from current PostgreSQL state on every protected request.
- The Supabase service-role key and invitation tokens never enter Flutter or application tables.
- Cross-user data is served only through gateway endpoints that derive the actor from the verified JWT.
- Centre ownership does not grant signing authority, and centre clinical reads require active patient consent.
- Super Admin clinical access is global, audited, and read-only.
- Doctors require an active verified licence, active centre membership, and active patient assignment.
- Signed clinical content, clinician signatures, access audit, administrative audit, and verification decisions are append-only.
- The agent and concierge gain no loader or tool capable of reading `clinical_drafts` or clinician notes.
- Summaries and priority ordering are deterministic; no LLM computes or invents clinical values.
- Every production-code change follows RED → GREEN → REFACTOR, and each task ends with its focused tests plus the relevant full suite.
- Existing uncommitted ring and signup changes in the primary checkout are not included in F10 commits.

## Review Focus

1. Existing auth user invited into a second centre must gain only that membership, never a duplicate identity or widened patient access; Task 5 tests this.
2. Role, membership, assignment, consent, or licence revoked while a screen is open must take effect on the next request despite a valid old JWT; Tasks 2, 4, 7, and 8 test this.
3. Retries after Supabase Auth succeeds but the database write times out must reconcile one identity and one membership without duplicate email delivery; Task 5 tests this.
4. Multi-centre doctors must not leak cached Centre A patients into Centre B after switching; Tasks 7 and 12 test API and Flutter cache isolation.
5. A service-role gateway read must fail closed if its append-only access-audit insert fails; Task 6 tests this.

---

## File Structure

### Database

- `healthagent/db/024_centres.sql` — centres, centre memberships, centre-clinic links, lifecycle constraints and RLS.
- `healthagent/db/025_account_invitations.sql` — invitation intents and append-only clinician-verification decisions.
- `healthagent/db/026_patient_access.sql` — doctor assignments, patient consent, access audit, and authorization functions.
- `healthagent/db/027_doctor_workspace.sql` — append-only clinician notes and versioned monthly reports.
- `healthagent/db/tests/centres_test.sql` — centre isolation and membership lifecycle.
- `healthagent/db/tests/account_invitations_test.sql` — invitation/verification immutability and authority.
- `healthagent/db/tests/patient_access_test.sql` — assignment, consent, admin-read, audit, and current-state authorization.
- `healthagent/db/tests/doctor_workspace_test.sql` — notes, report versions, hashes, and immutable signing.

### Backend

- `healthagent/app/gateway/tenancy.py` — current-state role/membership/assignment/consent predicates.
- `healthagent/app/gateway/invitations.py` — idempotent Supabase Auth invitation orchestration and reconciliation.
- `healthagent/app/gateway/access_audit.py` — fail-closed audited read wrapper.
- `healthagent/app/gateway/doctor_loader.py` — doctor-only scoped patient and clinical projections; never imported by agent tools.
- `healthagent/app/gateway/api/accounts.py` — invitation acceptance and current user's pending invitations.
- `healthagent/app/gateway/api/admin_people.py` — centres, people, invitations, verification, assignments, read-only patient viewer.
- `healthagent/app/gateway/api/centre.py` — centre roster, invitations, assignments, consent-gated patient read.
- `healthagent/app/gateway/api/doctor.py` — centres, Today, Patients, detail, notes, work queue, and report actions.
- `healthagent/app/clinical/doctor_priority.py` — deterministic priority score/reasons.
- `healthagent/app/clinical/summaries.py` — deterministic patient and report composers.
- `healthagent/app/clinical/monthly_reports.py` — evidence-cutoff generation and immutable report versioning.
- `healthagent/tests/test_tenancy.py`, `test_invitations.py`, `test_admin_people_api.py`, `test_centre_api.py`, `test_doctor_api.py`, `test_doctor_priority.py`, `test_clinical_summaries.py`, `test_monthly_reports.py` — behavior tests.

### Flutter

- `mobile/lib/features/roles/models/app_role.dart` — approved display labels.
- `mobile/lib/features/accounts/` — invitation models, repository, provider, acceptance screen.
- `mobile/lib/features/admin/` — centre, people, invitation, licence, patient viewer repositories/providers/screens.
- `mobile/lib/features/centre/` — centre dashboard, doctors, patients, assignments, profile.
- `mobile/lib/features/doctor/` — centre context, models, repository, providers, Today, Patients, detail, Work Queue, Profile.
- `mobile/lib/features/patient_care/` — patient's centre, doctors, and clinical-consent controls.
- `mobile/lib/app/role_routes.dart`, `mobile/lib/app/router.dart` — replace placeholders with concrete role screens and detail routes.
- `mobile/test/account_invitation_test.dart`, `admin_people_test.dart`, `centre_management_test.dart`, `doctor_repository_test.dart`, `doctor_workspace_test.dart`, `patient_care_test.dart`, `role_shell_test.dart` — unit and widget coverage.

---

### Task 1: Centre Tenant Schema

**Files:**
- Create: `healthagent/db/024_centres.sql`
- Create: `healthagent/db/tests/centres_test.sql`

**Interfaces:**
- Produces: `centres`, `centre_memberships`, `centre_clinics`; SQL helpers `active_centre_membership(uuid, uuid, text)` and `centre_owner_may_manage(uuid, uuid)`.
- Consumes: `profiles`, `clinics`, `app_role_of(uuid)` from migrations 005, 013, and 022.

- [ ] **Step 1: Write failing SQL tests** proving only admin creates a centre, an owner manages only their active centre, doctors may join two centres, suspended membership fails immediately, Centre A cannot select Centre B memberships, and lifecycle rows are ended rather than deleted.

```sql
select throws_ok(
  $$ select create_centre('Centre B', :'centre_owner_a') $$,
  '42501', null, 'a centre owner cannot create another centre'
);
select is(
  centre_owner_may_manage(:'owner_a', :'centre_b'), false,
  'Centre A owner cannot manage Centre B'
);
```

- [ ] **Step 2: Run the migration test and verify RED.**

Run: `cd healthagent && psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f db/tests/centres_test.sql`

Expected: FAIL because `centres` and `centre_owner_may_manage` do not exist.

- [ ] **Step 3: Implement `024_centres.sql`** with status checks, partial unique active memberships, immutable historical identifiers, indexes, RLS, grant/revoke rules, and `security definer` helpers with pinned `search_path`.

- [ ] **Step 4: Run the SQL test and the existing role test.**

Run: `cd healthagent && psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f db/024_centres.sql && psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f db/tests/centres_test.sql && psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f db/tests/app_role_test.sql`

Expected: all assertions pass.

- [ ] **Step 5: Commit only the migration and test.**

```bash
git add healthagent/db/024_centres.sql healthagent/db/tests/centres_test.sql
git commit -m "feat(tenancy): add isolated centre memberships"
```

### Task 2: Invitation and Clinician Verification Schema

**Files:**
- Create: `healthagent/db/025_account_invitations.sql`
- Create: `healthagent/db/tests/account_invitations_test.sql`

**Interfaces:**
- Produces: `account_invitations`, `clinician_verifications`; RPCs `create_account_invitation`, `accept_account_invitation`, `record_clinician_verification`.
- Consumes: active centre membership from Task 1 and `grant_app_role`/`clinicians` from existing migrations.

- [ ] **Step 1: Write failing SQL tests** for normalized-email idempotency, 24-hour expiry, revoke/accept conflict, existing-user linking, inviter role matrix, non-admin verification refusal, append-only verification decisions, and immediate loss of doctor eligibility after expiry/suspension.

```sql
select throws_ok(
  $$ select record_clinician_verification(:'centre_owner', :'doctor', 'verified', 'ok') $$,
  '42501', null, 'only Super Admin verifies a doctor'
);
```

- [ ] **Step 2: Run the test and verify RED.**

Run: `cd healthagent && psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f db/tests/account_invitations_test.sql`

Expected: FAIL because invitation and verification relations do not exist.

- [ ] **Step 3: Implement the migration** without password/token columns. Make decisions append-only, expose only safe invitation metadata through RLS, and update `clinicians` activation only inside the admin verification procedure.

- [ ] **Step 4: Run new and clinical-review SQL tests.**

Run: `cd healthagent && psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f db/025_account_invitations.sql && psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f db/tests/account_invitations_test.sql && psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f db/tests/clinical_review_test.sql`

Expected: all assertions pass and existing signing rules remain green.

- [ ] **Step 5: Commit.**

```bash
git add healthagent/db/025_account_invitations.sql healthagent/db/tests/account_invitations_test.sql
git commit -m "feat(accounts): persist safe invitations and verification history"
```

### Task 3: Assignments, Consent, and Audited Access Schema

**Files:**
- Create: `healthagent/db/026_patient_access.sql`
- Create: `healthagent/db/tests/patient_access_test.sql`

**Interfaces:**
- Produces: `patient_doctor_assignments`, `clinical_access_consents`, `access_audit`; SQL functions `doctor_can_read_patient`, `doctor_can_author_clinical`, `centre_can_read_clinical`, `admin_can_read_patient`, `assign_patient_doctor`, `set_primary_doctor`, `record_access_event`.
- Consumes: Tasks 1–2 membership and verification facts.

- [ ] **Step 1: Write failing SQL tests** for multiple assigned doctors, one active primary per patient/centre, transactional reassignment, ended-assignment denial, unverified-doctor denial, centre consent grant/revoke, cross-centre zero rows, Super Admin read permission, Super Admin clinical write denial, and append-only access audit.

```sql
select is(
  doctor_can_read_patient(:'doctor_a', :'centre_a', :'patient_b'), false,
  'a valid doctor cannot browse an unassigned patient'
);
select throws_ok(
  $$ update access_audit set action = 'hidden' where actor_id = :'admin' $$,
  '55000', null, 'access audit is append-only'
);
```

- [ ] **Step 2: Run the test and verify RED.**

Run: `cd healthagent && psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f db/tests/patient_access_test.sql`

Expected: FAIL on missing assignment relation.

- [ ] **Step 3: Implement the migration** with partial unique primary constraint, history-preserving end operations, consent history, append-only audit trigger, current-state predicates, and RLS that never grants broad direct cross-user mobile access.

- [ ] **Step 4: Run Tasks 1–3 database tests plus existing app-role tests.**

Run: `cd healthagent && for f in db/tests/centres_test.sql db/tests/account_invitations_test.sql db/tests/patient_access_test.sql db/tests/app_role_test.sql; do psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f "$f" || exit 1; done`

Expected: all tests pass.

- [ ] **Step 5: Commit.**

```bash
git add healthagent/db/026_patient_access.sql healthagent/db/tests/patient_access_test.sql
git commit -m "feat(access): enforce assignments consent and audited reads"
```

### Task 4: Notes and Monthly Report Schema

**Files:**
- Create: `healthagent/db/027_doctor_workspace.sql`
- Create: `healthagent/db/tests/doctor_workspace_test.sql`

**Interfaces:**
- Produces: `clinician_notes`, `monthly_reports`; procedures `append_clinician_note`, `withdraw_clinician_note`, `create_monthly_report_version`, `sign_monthly_report`.
- Consumes: `doctor_can_author_clinical`, existing clinician signing check, and SHA-256 delivery-binding pattern.

- [ ] **Step 1: Write failing SQL tests** showing only assigned verified doctors append notes, corrections reference but never overwrite originals, withdrawals retain text/reason, report regeneration creates a version, non-empty reviewer note is required, signature binds body plus note, and signed versions reject update/delete.

- [ ] **Step 2: Verify RED.**

Run: `cd healthagent && psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f db/tests/doctor_workspace_test.sql`

Expected: FAIL because `clinician_notes` is absent.

- [ ] **Step 3: Implement the migration** using append-only triggers and signing-time `clinician_may_sign` plus assignment checks. Store `signed_body_sha256` only on signed rows and compare it to `digest(delivery_body_with_note, 'sha256')`.

- [ ] **Step 4: Run doctor-workspace and existing clinical-review tests.**

Run: `cd healthagent && psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f db/027_doctor_workspace.sql && psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f db/tests/doctor_workspace_test.sql && psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f db/tests/clinical_review_test.sql`

Expected: all pass, including the one-character post-sign edit rejection.

- [ ] **Step 5: Commit.**

```bash
git add healthagent/db/027_doctor_workspace.sql healthagent/db/tests/doctor_workspace_test.sql
git commit -m "feat(clinical): add append-only notes and monthly reports"
```

### Task 5: Supabase Invitation Orchestration

**Files:**
- Create: `healthagent/app/gateway/invitations.py`
- Create: `healthagent/app/gateway/api/accounts.py`
- Create: `healthagent/tests/test_invitations.py`
- Modify: `healthagent/app/gateway/main.py`

**Interfaces:**
- Produces: `InvitationService.invite(actor_id, email, intended_role, centre_id, primary_doctor_id, idempotency_key) -> InvitationResult`, `InvitationService.reconcile(invitation_id)`, `/api/v1/invitations/pending`, `/accept`, `/decline`.
- Consumes: Task 2 RPCs, Supabase Auth admin `invite_user_by_email`, verified JWT actor.

- [ ] **Step 1: Write failing pytest cases** for new identity, existing identity, forbidden inviter, normalized-email dedupe, retry after auth-success/database-timeout, expired/revoked acceptance, doctor pending-verification, and no password/token persistence or response leakage.

```python
def test_retry_after_auth_success_links_one_identity_and_one_membership(service):
    first = service.invite(**INVITE, idempotency_key="same")
    second = service.invite(**INVITE, idempotency_key="same")
    assert second.invitation_id == first.invitation_id
    assert service.auth.invite_calls == 1
```

- [ ] **Step 2: Run and verify RED.**

Run: `cd healthagent && pytest -q tests/test_invitations.py`

Expected: import failure for `app.gateway.invitations`.

- [ ] **Step 3: Implement minimal orchestration** that persists intent before provider delivery, records provider identity after delivery, recovers a partial attempt by lookup/reconciliation, and never logs or returns a magic link.

- [ ] **Step 4: Register recipient routes and run focused plus auth suites.**

Run: `cd healthagent && pytest -q tests/test_invitations.py tests/test_gateway_auth.py tests/test_app_role.py`

Expected: all pass.

- [ ] **Step 5: Commit.**

```bash
git add healthagent/app/gateway/invitations.py healthagent/app/gateway/api/accounts.py healthagent/app/gateway/main.py healthagent/tests/test_invitations.py
git commit -m "feat(accounts): invite every role through Supabase Auth"
```

### Task 6: Current-state Authorization and Fail-closed Audit

**Files:**
- Create: `healthagent/app/gateway/tenancy.py`
- Create: `healthagent/app/gateway/access_audit.py`
- Create: `healthagent/tests/test_tenancy.py`

**Interfaces:**
- Produces: `require_centre_member(kind)`, `require_doctor_patient_access()`, `require_centre_clinical_access()`, `audited_read(...)`.
- Consumes: JWT actor from `current_user_id`, database role from `app_role_of`, Task 3 SQL predicates/audit function.

- [ ] **Step 1: Write failing tests** that exercise every role, two centres, two doctors, unassigned patient, stale JWT after revocation, suspended licence, revoked consent, admin read, admin mutation refusal, and audit insertion failure.

```python
def test_audit_failure_returns_no_patient_data(client, audit_store):
    audit_store.fail_next_insert()
    response = client.get(f"/protected/patients/{PATIENT}")
    assert response.status_code == 503
    assert PATIENT_NAME not in response.text
```

- [ ] **Step 2: Run and verify RED.**

Run: `cd healthagent && pytest -q tests/test_tenancy.py`

Expected: import failure for `app.gateway.tenancy`.

- [ ] **Step 3: Implement dependencies** that query current state per request, return generic 403s, validate explicit centre context, and execute audit-before-return for protected reads.

- [ ] **Step 4: Run focused and existing role/API security tests.**

Run: `cd healthagent && pytest -q tests/test_tenancy.py tests/test_app_role.py tests/test_admin_api.py`

Expected: all pass.

- [ ] **Step 5: Commit.**

```bash
git add healthagent/app/gateway/tenancy.py healthagent/app/gateway/access_audit.py healthagent/tests/test_tenancy.py
git commit -m "feat(authz): enforce current tenant and patient scope"
```

### Task 7: Super Admin and Centre Owner Management APIs

**Files:**
- Create: `healthagent/app/gateway/api/admin_people.py`
- Create: `healthagent/app/gateway/api/centre.py`
- Create: `healthagent/tests/test_admin_people_api.py`
- Create: `healthagent/tests/test_centre_api.py`
- Modify: `healthagent/app/gateway/main.py`
- Modify: `healthagent/app/gateway/api/admin.py`

**Interfaces:**
- Produces: spec §8.1 and §8.2 endpoints for centres, invitations, verification, rosters, assignments, consent-gated clinical reads, and admin read-only clinical views.
- Consumes: Tasks 5–6 services/dependencies and Task 3 RPCs.

- [ ] **Step 1: Write failing API tests** for admin centre creation, centre-owner invitation, doctor verification, patient invitation, list pagination after authorization, assignment/reassignment, cross-centre guessed ID, consent-required read, audited admin read, and absent clinical mutation routes.

- [ ] **Step 2: Run and verify RED.**

Run: `cd healthagent && pytest -q tests/test_admin_people_api.py tests/test_centre_api.py`

Expected: 404/import failures for the new routers.

- [ ] **Step 3: Implement thin routers** using Pydantic request models with normalized email, UUID validation, bounded pagination, idempotency header, generic out-of-scope 404/403 behavior, and no direct trust of actor IDs in payloads.

- [ ] **Step 4: Register routers and run all gateway tests.**

Run: `cd healthagent && pytest -q tests/test_admin_people_api.py tests/test_centre_api.py tests/test_admin_api.py tests/test_app_role.py tests/test_gateway_auth.py`

Expected: all pass; admin clinical payload contains data and a matching audit event, with no mutation endpoint.

- [ ] **Step 5: Commit.**

```bash
git add healthagent/app/gateway/api/admin_people.py healthagent/app/gateway/api/centre.py healthagent/app/gateway/api/admin.py healthagent/app/gateway/main.py healthagent/tests/test_admin_people_api.py healthagent/tests/test_centre_api.py
git commit -m "feat(management): add admin and centre provisioning APIs"
```

### Task 8: Doctor-scoped Loader and Deterministic Composers

**Files:**
- Create: `healthagent/app/gateway/doctor_loader.py`
- Create: `healthagent/app/clinical/doctor_priority.py`
- Create: `healthagent/app/clinical/summaries.py`
- Create: `healthagent/tests/test_doctor_loader.py`
- Create: `healthagent/tests/test_doctor_priority.py`
- Create: `healthagent/tests/test_clinical_summaries.py`

**Interfaces:**
- Produces: `DoctorLoader.for_actor(supabase, doctor_id, centre_id)`, `.patients()`, `.patient(patient_id)`, `.drafts(patient_id=None)`; `priority_for(PatientSignals) -> Priority`; `compose_patient_summary(facts) -> ComposedSummary`.
- Consumes: Task 6 authorization predicates and existing analytics functions; never imported by agent/context-loader/tool modules.

- [ ] **Step 1: Write failing tests** for second-doctor zero rows, centre switching, ended assignment, deterministic priority ordering/reasons, critical escalation shown independently, stable summary output, and every number traceable to the supplied fact set.

- [ ] **Step 2: Verify RED.**

Run: `cd healthagent && pytest -q tests/test_doctor_loader.py tests/test_doctor_priority.py tests/test_clinical_summaries.py`

Expected: missing-module failures.

- [ ] **Step 3: Implement loader and pure composers** with scoped queries, typed dataclasses, explicit missing-data sentences, and no LLM calls.

- [ ] **Step 4: Add an import-boundary test** that scans `app/agent` and tool registries and fails if `doctor_loader`, `clinical_drafts`, or clinician notes become reachable.

- [ ] **Step 5: Run focused tests plus number/provenance suites.**

Run: `cd healthagent && pytest -q tests/test_doctor_loader.py tests/test_doctor_priority.py tests/test_clinical_summaries.py tests/test_agent_numbers.py tests/test_report_numbers.py tests/test_concierge_tools.py`

Expected: all pass.

- [ ] **Step 6: Commit.**

```bash
git add healthagent/app/gateway/doctor_loader.py healthagent/app/clinical/doctor_priority.py healthagent/app/clinical/summaries.py healthagent/tests/test_doctor_loader.py healthagent/tests/test_doctor_priority.py healthagent/tests/test_clinical_summaries.py
git commit -m "feat(doctor): scope patients and compose deterministic summaries"
```

### Task 9: Doctor API, Work Queue, Notes, and Reports

**Files:**
- Create: `healthagent/app/gateway/api/doctor.py`
- Create: `healthagent/app/clinical/monthly_reports.py`
- Create: `healthagent/tests/test_doctor_api.py`
- Create: `healthagent/tests/test_monthly_reports.py`
- Modify: `healthagent/app/gateway/main.py`

**Interfaces:**
- Produces: all spec §8.3 doctor endpoints; queue response segments `monthly_reports`, `sinc_drafts`, `consults`, `therapy_plans`, `rx_supplements`; report `generate`, `review`, `sign`, and `reject` actions.
- Consumes: Tasks 4, 6, and 8 plus existing `clinical_drafts`, `clinical_reviews`, `gate_delivery`, and queue claim state machine.

- [ ] **Step 1: Write failing API tests** for Today counts, authorized patient search, detail, notes, five queue segments, empty therapy/Rx contracts, claim/release, note-required decisions, stale version, monthly generation idempotency, signed trail, one-character mutation failure, and escalation bypassing the queue.

```python
def test_every_decision_requires_a_nonempty_note(doctor_client, draft_id):
    response = doctor_client.post(
        f"/api/v1/doctor/{CENTRE}/work/{draft_id}/sign",
        json={"note": "   ", "version": 1},
    )
    assert response.status_code == 422
```

- [ ] **Step 2: Run and verify RED.**

Run: `cd healthagent && pytest -q tests/test_doctor_api.py tests/test_monthly_reports.py`

Expected: 404/import failure for doctor routes.

- [ ] **Step 3: Implement routes and report composer** as thin orchestration over existing clinical machinery. Recompute edited delivery bodies before hashing; do not implement F12 therapy or F18 Rx content.

- [ ] **Step 4: Register router and run clinical/backend suites.**

Run: `cd healthagent && pytest -q tests/test_doctor_api.py tests/test_monthly_reports.py tests/test_clinical_drafts.py tests/test_clinical_sweep.py tests/test_guardrails.py`

Expected: all pass and `stranded_total` can reach zero via claim/review actions.

- [ ] **Step 5: Run full backend suite.**

Run: `cd healthagent && pytest -q`

Expected: zero failures.

- [ ] **Step 6: Commit.**

```bash
git add healthagent/app/gateway/api/doctor.py healthagent/app/clinical/monthly_reports.py healthagent/app/gateway/main.py healthagent/tests/test_doctor_api.py healthagent/tests/test_monthly_reports.py
git commit -m "feat(doctor): expose assigned patients and clinical work queue"
```

### Task 10: Flutter Role Labels, Invitations, and Shared API Errors

**Files:**
- Modify: `mobile/lib/features/roles/models/app_role.dart`
- Create: `mobile/lib/features/accounts/models/account_invitation.dart`
- Create: `mobile/lib/features/accounts/data/account_repository.dart`
- Create: `mobile/lib/features/accounts/providers/account_provider.dart`
- Create: `mobile/lib/features/accounts/screens/pending_invitation_screen.dart`
- Create: `mobile/test/account_invitation_test.dart`
- Modify: `mobile/test/role_shell_test.dart`

**Interfaces:**
- Produces: UI labels and invitation acceptance flow; `AccountRepository.pending/accept/decline`.
- Consumes: Task 5 recipient API and existing authenticated Dio client.

- [ ] **Step 1: Write failing Dart tests** for exact labels, pending invitation rendering, expired/revoked states, accept refresh of role/membership, decline, and server error mapping without exposing raw internals.

- [ ] **Step 2: Run and verify RED.**

Run: `cd mobile && flutter test test/account_invitation_test.dart test/role_shell_test.dart`

Expected: label mismatch and missing invitation classes.

- [ ] **Step 3: Implement models/repository/provider/screen** using gateway Dio only; invalidate `roleProvider` after acceptance.

- [ ] **Step 4: Run focused tests and analyzer.**

Run: `cd mobile && flutter test test/account_invitation_test.dart test/role_shell_test.dart && flutter analyze`

Expected: all tests pass and no analyzer issues.

- [ ] **Step 5: Commit.**

```bash
git add mobile/lib/features/roles/models/app_role.dart mobile/lib/features/accounts mobile/test/account_invitation_test.dart mobile/test/role_shell_test.dart
git commit -m "feat(accounts): accept role invitations in the app"
```

### Task 11: Flutter Super Admin and Centre Owner Management

**Files:**
- Create/modify: `mobile/lib/features/admin/models/people.dart`
- Create/modify: `mobile/lib/features/admin/data/admin_repository.dart`
- Create/modify: `mobile/lib/features/admin/providers/admin_provider.dart`
- Create: `mobile/lib/features/admin/screens/centres_screen.dart`
- Create: `mobile/lib/features/admin/screens/licence_verification_screen.dart`
- Create: `mobile/lib/features/admin/screens/patient_viewer_screen.dart`
- Create: `mobile/lib/features/centre/models/centre_roster.dart`
- Create: `mobile/lib/features/centre/data/centre_repository.dart`
- Create: `mobile/lib/features/centre/providers/centre_provider.dart`
- Create: `mobile/lib/features/centre/screens/centre_dashboard_screen.dart`
- Create: `mobile/lib/features/centre/screens/doctors_screen.dart`
- Create: `mobile/lib/features/centre/screens/patients_screen.dart`
- Create: `mobile/lib/features/centre/screens/assignments_screen.dart`
- Create: `mobile/lib/features/centre/screens/centre_profile_screen.dart`
- Create: `mobile/test/admin_people_test.dart`
- Create: `mobile/test/centre_management_test.dart`
- Modify: `mobile/lib/app/role_routes.dart`
- Modify: `mobile/lib/app/router.dart`
- Modify: `mobile/test/role_shell_test.dart`

**Interfaces:**
- Produces: centre/people/invitation/licence/assignment workflows and read-only admin patient viewer.
- Consumes: Task 7 APIs.

- [ ] **Step 1: Write failing repository and widget tests** for create centre, invite each permitted role, verify/reject doctor, centre-scoped rosters, assignment/reassignment, consent-required clinical state, and admin viewer containing no edit/sign controls.

- [ ] **Step 2: Run and verify RED.**

Run: `cd mobile && flutter test test/admin_people_test.dart test/centre_management_test.dart`

Expected: missing classes/screens.

- [ ] **Step 3: Implement focused models, repositories, providers, and screens** with loading, empty, error, forbidden, consent-required, and retry states. Replace the Centre Owner placeholders with Dashboard, Doctors, Patients, Assignments, and Profile branches; expose Super Admin Centres, Invitations, Licence Verification, and read-only Patient Viewer from its management surface.

- [ ] **Step 4: Run focused tests and analyzer.**

Run: `cd mobile && flutter test test/admin_people_test.dart test/centre_management_test.dart test/role_shell_test.dart && flutter analyze`

Expected: all green.

- [ ] **Step 5: Commit.**

```bash
git add mobile/lib/features/admin mobile/lib/features/centre mobile/lib/app/role_routes.dart mobile/lib/app/router.dart mobile/test/admin_people_test.dart mobile/test/centre_management_test.dart mobile/test/role_shell_test.dart
git commit -m "feat(management): manage centres doctors and patients"
```

### Task 12: Flutter Doctor Data Layer and Centre Isolation

**Files:**
- Create: `mobile/lib/features/doctor/models/doctor_models.dart`
- Create: `mobile/lib/features/doctor/data/doctor_repository.dart`
- Create: `mobile/lib/features/doctor/providers/doctor_provider.dart`
- Create: `mobile/test/doctor_repository_test.dart`

**Interfaces:**
- Produces: `DoctorRepository.centres/today/patients/patient/workQueue/addNote/claim/sign/reject/generateReport`; family providers keyed by centre and patient.
- Consumes: Task 9 API.

- [ ] **Step 1: Write failing tests** for JSON contracts, pagination, error mapping, mandatory note validation before request, centre-keyed caches, invalidation after decisions, and Centre A data absent after switching to Centre B.

- [ ] **Step 2: Run and verify RED.**

Run: `cd mobile && flutter test test/doctor_repository_test.dart`

Expected: missing doctor data layer.

- [ ] **Step 3: Implement immutable models, gateway repository, and auto-dispose family providers** whose keys always contain explicit centre context.

- [ ] **Step 4: Run focused tests and analyzer.**

Run: `cd mobile && flutter test test/doctor_repository_test.dart && flutter analyze`

Expected: all green.

- [ ] **Step 5: Commit.**

```bash
git add mobile/lib/features/doctor/models mobile/lib/features/doctor/data mobile/lib/features/doctor/providers mobile/test/doctor_repository_test.dart
git commit -m "feat(doctor): add centre-scoped mobile data layer"
```

### Task 13: Flutter Doctor Today, Patients, and Patient Detail

**Files:**
- Create: `mobile/lib/features/doctor/screens/doctor_today_screen.dart`
- Create: `mobile/lib/features/doctor/screens/doctor_patients_screen.dart`
- Create: `mobile/lib/features/doctor/screens/doctor_patient_detail_screen.dart`
- Create: `mobile/lib/features/doctor/widgets/centre_selector.dart`
- Create: `mobile/lib/features/doctor/widgets/priority_reason.dart`
- Create: `mobile/test/doctor_workspace_test.dart`
- Modify: `mobile/lib/app/router.dart`

**Interfaces:**
- Produces: navigable Today, Patients, detail, notes, report and escalation views.
- Consumes: Task 12 providers and existing `Prov`, `ConfBar`, `Loading`, `ErrorState`, and app tokens.

- [ ] **Step 1: Write failing widget tests** for centre selection, Today counts, visible deterministic reason, critical escalation separate from queue, assigned-only search, patient detail evidence/provenance, append note, and loading/empty/stale/partial/error states.

- [ ] **Step 2: Run and verify RED.**

Run: `cd mobile && flutter test test/doctor_workspace_test.dart`

Expected: doctor placeholders remain and required widgets are absent.

- [ ] **Step 3: Implement screens/widgets and replace Today/Patients placeholders.** Add an authenticated detail route carrying patient and centre IDs, while the provider independently enforces scope.

- [ ] **Step 4: Run workspace/role tests and analyzer.**

Run: `cd mobile && flutter test test/doctor_workspace_test.dart test/role_shell_test.dart && flutter analyze`

Expected: all green.

- [ ] **Step 5: Commit.**

```bash
git add mobile/lib/features/doctor/screens mobile/lib/features/doctor/widgets mobile/lib/app/router.dart mobile/test/doctor_workspace_test.dart
git commit -m "feat(doctor): show assigned patients and priorities"
```

### Task 14: Flutter Work Queue and Doctor Profile

**Files:**
- Create: `mobile/lib/features/doctor/screens/doctor_work_queue_screen.dart`
- Create: `mobile/lib/features/doctor/screens/doctor_profile_screen.dart`
- Create: `mobile/lib/features/doctor/widgets/work_queue_segment.dart`
- Create: `mobile/lib/features/doctor/widgets/clinical_decision_sheet.dart`
- Modify: `mobile/lib/app/router.dart`
- Modify: `mobile/test/doctor_workspace_test.dart`

**Interfaces:**
- Produces: five-segment queue, claim/review/sign/reject actions, report generation, and verification/licence profile.
- Consumes: Task 12 repository; therapy/Rx segments consume empty lists only.

- [ ] **Step 1: Add failing widget tests** for all five segment labels, intentional therapy/Rx empty copy, keyboard-safe note entry, disabled blank-note actions, server validation display, claim/release, signed success refresh, stale-content conflict, monthly generate/sign, and licence-expiry warning.

- [ ] **Step 2: Run and verify RED.**

Run: `cd mobile && flutter test test/doctor_workspace_test.dart`

Expected: Work/Profile placeholders and missing controls.

- [ ] **Step 3: Implement Work Queue and Profile** with a scrollable keyboard-safe decision sheet, note trimming, explicit evidence/version display, confirmation before irreversible signing, and provider invalidation after success.

- [ ] **Step 4: Replace final doctor placeholders and run full Flutter suite.**

Run: `cd mobile && flutter test && flutter analyze`

Expected: zero test failures and no analyzer issues.

- [ ] **Step 5: Commit.**

```bash
git add mobile/lib/features/doctor mobile/lib/app/router.dart mobile/test/doctor_workspace_test.dart
git commit -m "feat(doctor): review and sign the five-segment work queue"
```

### Task 15: Patient Membership, Assigned Doctors, and Consent

**Files:**
- Create: `mobile/lib/features/patient_care/models/patient_care.dart`
- Create: `mobile/lib/features/patient_care/data/patient_care_repository.dart`
- Create: `mobile/lib/features/patient_care/providers/patient_care_provider.dart`
- Create: `mobile/lib/features/patient_care/screens/patient_care_screen.dart`
- Create: `mobile/test/patient_care_test.dart`
- Modify: `mobile/lib/features/profile/screens/profile_screen.dart`
- Modify: `healthagent/app/gateway/api/accounts.py`
- Modify: `healthagent/tests/test_invitations.py`

**Interfaces:**
- Produces: self-scoped centre membership, assigned doctors/primary doctor, and grant/revoke consent endpoints and UI.
- Consumes: Tasks 3 and 5.

- [ ] **Step 1: Write failing backend and Flutter tests** for patient-only self read, primary/additional doctor display, consent grant history, immediate revoke, centre clinical denial after revoke, and no ability to assign doctors.

- [ ] **Step 2: Run and verify RED.**

Run: `cd healthagent && pytest -q tests/test_invitations.py -k patient_care; cd ../mobile && flutter test test/patient_care_test.dart`

Expected: missing endpoints and classes.

- [ ] **Step 3: Implement self-scoped API and patient UI** and link it from Profile; actor always comes from the JWT.

- [ ] **Step 4: Run focused tests, full suites, and analyzer.**

Run: `cd healthagent && pytest -q; cd ../mobile && flutter test && flutter analyze`

Expected: all green.

- [ ] **Step 5: Commit.**

```bash
git add healthagent/app/gateway/api/accounts.py healthagent/tests/test_invitations.py mobile/lib/features/patient_care mobile/lib/features/profile/screens/profile_screen.dart mobile/test/patient_care_test.dart
git commit -m "feat(patient): show care team and control centre consent"
```

### Task 16: Integration, Device Verification, and Staging Readiness

**Files:**
- Create: `docs/roadmap/F10-completion-report.md`
- Modify only if a failing verification proves necessary: files owned by Tasks 1–15, with a new failing regression test first.

**Interfaces:**
- Produces: evidence that the design's acceptance matrix passes on database, gateway, Flutter, and Android device.
- Consumes: all previous tasks.

- [ ] **Step 1: Apply all new migrations to the staging Supabase database** in numeric order and run every SQL test, recording migration versions and outputs in the completion report.

- [ ] **Step 2: Run backend verification.**

Run: `cd healthagent && pytest -q`

Expected: zero failures.

- [ ] **Step 3: Run Flutter verification.**

Run: `cd mobile && flutter test && flutter analyze`

Expected: zero failures and no analyzer issues.

- [ ] **Step 4: Run the end-to-end role matrix** with two centres, one multi-centre doctor, a second doctor, assigned/unassigned patients, consent grant/revoke, admin audited read, doctor note/sign flow, and attempted signed-content mutation. Record request IDs and audit IDs, not patient health values.

- [ ] **Step 5: Verify on `Pixel_8`**: invitation login, each role home, centre switching, patient assignment, five queue segments, keyboard note, report signing, and ring reconnect/smoking-event regression.

- [ ] **Step 6: Confirm operational signals**: `stranded_total` can reach zero, audit insert failures alert, invitation reconciliation is empty, licence expiry is visible, and no service-role or invitation secret appears in app/log artifacts.

- [ ] **Step 7: Write `F10-completion-report.md`** with commits, migrations, test counts, device evidence, intentionally empty F12/F18 queue segments, and any externally blocked deployment step.

- [ ] **Step 8: Commit verification evidence.**

```bash
git add docs/roadmap/F10-completion-report.md
git commit -m "docs: record F10 verification and staging readiness"
```

## Execution Order and Commit Discipline

Execute Tasks 1–16 in order. Tasks 1–4 establish enforceable facts; Tasks 5–9 expose only those facts through the gateway; Tasks 10–15 render the authorized workflows; Task 16 proves the complete system. Do not begin a consuming task until its producing task is green and committed. Stage exact paths only so the pre-existing ring/signup work in the primary checkout is never swept into an F10 commit.
