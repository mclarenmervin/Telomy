# Role Provisioning and Doctor Workspace Design

**Status:** Approved architecture, pending written-spec review

**Date:** 2026-10-12

**Scope:** F10 doctor workspace plus production role, centre, invitation, and patient-assignment foundations

## 1. Context

Telomy currently has four database role values (`admin`, `centre`, `doctor`, and `member`) and role-specific application shells, but centre tenancy, account provisioning, doctor-patient assignment, and the F10 doctor workspace are not yet complete.

This design turns those placeholders into a production authorization model. It also adapts the useful workflow concepts from the doctor prototype—Today, Patients, Work Queue, patient detail, notes, and report review—without copying the prototype's client-side role switching or fixed identities.

The design preserves the distinction between commercial ownership and clinical authority:

- A **centre** is a business tenant that owns its roster and operations.
- A **clinic** is an existing clinical/signing entity.
- A centre may be linked to one or more clinics, but centre ownership never grants clinical signing authority.

## 2. Goals

1. Support four user-facing roles:
   - Super Admin
   - Centre Owner
   - Doctor
   - Patient
2. Let Super Admin create centres and invite centre owners, doctors, and patients.
3. Let Centre Owners invite doctors and patients into their own centres.
4. Let verified Doctors invite patients into an active centre in which the doctor is a member.
5. Deliver login invitations by email without administrators choosing or handling user passwords.
6. Support doctors who belong to multiple centres while keeping each centre's data isolated.
7. Let Centre Owners assign multiple doctors to a patient and designate one primary doctor per centre.
8. Ensure Doctors see only patients explicitly assigned to them.
9. Let Super Admin read all patient and clinical data through audited, read-only gateway operations.
10. Implement the F10 doctor workspace with deterministic priorities, patient detail, notes, clinical draft review, and monthly reports.
11. Preserve the immutability of signed clinical content, clinician signatures, and append-only audit records for every role, including Super Admin.

## 3. Non-goals

- Therapy content authoring belongs to F12. F10 may expose an empty, stable therapy-plan queue contract.
- Prescription and supplement content belongs to F18. F10 may expose an empty, stable Rx/supplement queue contract.
- Centre booking and machine telemetry belong to later centre milestones.
- Payments and subscriptions are not part of this design.
- No role may edit a signed clinical record, forge a clinician signature, or rewrite audit history.
- This design does not grant Centre Owners automatic clinical access merely because a patient belongs to the centre.

## 4. Role Naming and Existing Values

The existing database values remain unchanged to avoid unnecessary migration risk:

| Database value | User-facing label |
|---|---|
| `admin` | Super Admin |
| `centre` | Centre Owner |
| `doctor` | Doctor |
| `member` | Patient |

`profiles.app_role` remains the platform-level role. Centre membership and doctor-patient assignment are separate authorization axes and must not be inferred from `app_role` alone.

## 5. Data Model

### 5.1 Centres

Add `centres` as the commercial tenant table:

- `id`
- `name`
- `status`: `active`, `suspended`, or `closed`
- `created_by`
- `created_at`, `updated_at`

Only Super Admin may create, suspend, or close a centre. Closing or suspending a centre disables new operational access but does not delete its records.

### 5.2 Centre memberships

Add `centre_memberships`:

- `id`
- `centre_id`
- `user_id`
- `member_kind`: `owner`, `doctor`, or `patient`
- `status`: `invited`, `pending_verification`, `active`, `suspended`, or `left`
- `invited_by`
- `accepted_at`, `suspended_at`, `left_at`
- `created_at`, `updated_at`

A unique active-membership constraint prevents duplicate memberships for the same centre, user, and member kind. Historical rows are retained.

Centre Owners and Patients normally belong to one centre. Doctors may have active memberships in multiple centres. Every centre-scoped request must carry an explicit centre identifier that is validated against the actor's membership.

### 5.3 Centre-to-clinic bridge

Add `centre_clinics`:

- `centre_id`
- `clinic_id`
- `status`
- `linked_by`
- `linked_at`, `unlinked_at`

This preserves the rule: **a clinic signs; a centre sells**. Linking a centre to a clinic does not make a Centre Owner a clinician. Super Admin controls the bridge. Existing clinical signing checks continue to require valid clinician registration, licence, and clinic membership.

### 5.4 Doctor verification

Add `clinician_verifications` as an append-only review history:

- `id`
- `doctor_id`
- registration and licensing metadata
- `status`: `pending`, `verified`, `rejected`, `expired`, or `superseded`
- `submitted_at`
- `reviewed_by`, `reviewed_at`
- `decision_reason`
- evidence references, never raw secrets

A Centre Owner may invite a doctor and submit credential information, but only Super Admin may record a verification decision. An invited doctor stays `pending_verification` and cannot access patients, author clinical notes, claim drafts, or sign reports until verified.

Verification history is never updated in place. A new decision supersedes the prior row. The existing `clinicians` row becomes active only from a verified decision.

### 5.5 Patient-doctor assignments

Add `patient_doctor_assignments`:

- `id`
- `centre_id`
- `patient_id`
- `doctor_id`
- `is_primary`
- `assigned_by`
- `assigned_at`
- `ended_by`, `ended_at`, `end_reason`

A patient may have multiple active doctors in a centre. A partial unique constraint permits only one active primary doctor per patient per centre. Assignment history is retained rather than overwritten.

When a verified doctor invites a new patient, the doctor becomes that patient's initial primary doctor for the selected centre after the patient accepts the invitation. A Centre Owner may later add doctors or change the primary doctor. Reassignment ends the old primary assignment and creates or promotes the new one in one transaction.

### 5.6 Invitations

Add `account_invitations`:

- `id`
- normalized `email`
- `intended_role`
- `centre_id` when centre-scoped
- `invited_by`
- `invited_user_id` after auth identity resolution
- initial primary doctor when applicable
- credential-application reference for doctor invitations
- `status`: `pending`, `accepted`, `revoked`, or `expired`
- `expires_at`, default 24 hours
- `sent_at`, `accepted_at`, `revoked_at`
- idempotency key and delivery-attempt metadata

Invitation rows never store passwords, password-reset tokens, magic links, or provider secrets.

### 5.7 Clinical access consent

Add `clinical_access_consents`:

- `id`
- `patient_id`
- `centre_id`
- `purpose`
- `granted_at`
- `revoked_at`
- actor and provenance fields

Centre Owners may always read their centre's roster and operational status. They may read clinical detail only while an applicable patient consent is active. Revocation affects future reads and never deletes prior audit events.

### 5.8 Access audit

Add an append-only `access_audit` stream for cross-user data access:

- actor identity and role
- action
- patient and centre context
- resource kind and resource identifier
- request/correlation identifier
- stated operational reason or screen context
- outcome
- timestamp

Every Super Admin patient or clinical read is recorded. Centre Owner clinical reads and Doctor patient reads are also recorded. Audit insertion and the protected read must be coupled so a successful read cannot bypass its event.

### 5.9 Clinician notes

Add `clinician_notes`:

- `id`
- `patient_id`, `centre_id`, `author_doctor_id`
- `body`
- `created_at`
- optional `supersedes_id`
- optional withdrawal metadata and reason

Clinical notes are append-only. Corrections create a new note referencing the superseded note; withdrawals retain the original text and record who withdrew it and why. Only a verified, currently assigned doctor may add a note.

### 5.10 Monthly reports

Add `monthly_reports` as deterministic, evidence-backed snapshots:

- patient, centre, and reporting period
- source-data cutoff and evidence references
- generated report body and version
- status: `draft`, `in_review`, `signed`, `rejected`, or `superseded`
- reviewer note
- signing clinician, timestamp, and bound content hash

Generating the same report version from the same cutoff is idempotent. Signed report content is immutable and uses the existing clinical signature and delivery-gate principles.

## 6. Invitation and Account Lifecycle

1. The gateway validates the inviter's role and centre scope.
2. It normalizes the email and creates or reuses a pending invitation intent.
3. A server-side invitation service calls the Supabase Auth Admin API. The service-role key never ships in the mobile app.
4. If the email already has an auth identity, Telomy sends a centre-membership invitation rather than creating a duplicate identity.
5. The returned auth user is linked to the pending invitation and intended membership.
6. The recipient follows the email flow, proves control of the email, and sets their own password.
7. On first authenticated acceptance, the gateway atomically activates the profile and eligible memberships.
8. Doctor memberships remain `pending_verification` until Super Admin verifies the licence.
9. Expired invitations can be resent, producing a fresh provider link while retaining invitation history. Revoked invitations cannot be accepted.
10. A reconciliation worker repairs partial failures, such as an auth identity created before the database transaction completed.

The operation is idempotent by normalized email, intended role, centre, and active invitation. Repeated taps or network retries must not create duplicate users, memberships, or emails within the delivery deduplication window.

## 7. Authorization Model

### 7.1 Gateway-first cross-user reads

Cross-user reads go through authenticated gateway endpoints, not broad direct mobile-to-Supabase table access. This provides one place to enforce scope and write the access audit. RLS remains defense in depth and prevents direct table access outside the actor's own safe scope.

The gateway derives the actor from the verified JWT. A request body or path may identify the target patient or centre, but never the acting user.

### 7.2 Authorization predicates

Implement reusable, database-backed predicates:

- `require_app_role(actor, allowed_roles)`
- `admin_can_read_patient(actor, patient)`
- `centre_can_manage_roster(actor, centre)`
- `centre_can_read_clinical(actor, centre, patient)`
- `doctor_can_read_patient(actor, centre, patient)`
- `doctor_can_author_clinical(actor, centre, patient)`
- `can_invite_role(actor, centre, intended_role)`

All predicates evaluate current database state on each protected request; stale role claims in an old JWT do not retain access.

### 7.3 Effective permissions

| Capability | Super Admin | Centre Owner | Doctor | Patient |
|---|---:|---:|---:|---:|
| Create/suspend centre | Yes | No | No | No |
| Invite centre owner | Yes | No | No | No |
| Invite doctor | Yes | Own centre | No | No |
| Invite patient | Yes | Own centre | Active centre | No |
| Manage centre roster | All centres | Own centre | No | No |
| Assign doctors | All centres | Own centre | No | No |
| Read patient roster | All | Own centre | Assigned only | Self |
| Read clinical data | All, audited | With active consent | Assigned only | Self |
| Add clinical note | No | No | Assigned and verified | No |
| Sign clinical content | No | No | Assigned and verified | No |
| Edit signed content/signature/audit | Never | Never | Never | Never |

Super Admin's universal access is read-only for clinical content. Administrative status changes, centre management, invitations, and licence decisions remain allowed but are distinct from clinical record mutation.

### 7.4 Isolation invariants

- Centre A receives zero Centre B roster or clinical data.
- A Doctor receives zero data for an unassigned patient, even if both are in the same centre.
- A Doctor's assignment in Centre A grants no access through Centre B.
- A suspended membership or ended assignment removes access immediately.
- A Centre Owner without active consent receives zero clinical detail, while still seeing operational roster fields.
- Concierge surfaces and tools never load clinical drafts or unrestricted clinician notes.

## 8. API Surface

All endpoints are versioned under `/api/v1`, require a verified JWT, return stable error codes, and record actor/context metadata.

### 8.1 Super Admin

- `POST /admin/centres`
- `GET /admin/centres`
- `PATCH /admin/centres/{centre_id}/status`
- `POST /admin/invitations`
- `GET /admin/invitations`
- `POST /admin/clinicians/{doctor_id}/verification-decisions`
- `GET /admin/patients`
- `GET /admin/patients/{patient_id}`
- `GET /admin/patients/{patient_id}/clinical-record` — audited and read-only
- `GET /admin/access-audit`

### 8.2 Centre Owner

- `GET /centre/{centre_id}/dashboard`
- `GET /centre/{centre_id}/doctors`
- `GET /centre/{centre_id}/patients`
- `POST /centre/{centre_id}/invitations`
- `POST /centre/{centre_id}/patients/{patient_id}/assignments`
- `PATCH /centre/{centre_id}/patients/{patient_id}/primary-doctor`
- `DELETE /centre/{centre_id}/patients/{patient_id}/assignments/{assignment_id}` — ends, never deletes, the assignment
- `GET /centre/{centre_id}/patients/{patient_id}/clinical-record` — requires active consent and is audited

### 8.3 Doctor

- `GET /doctor/centres`
- `GET /doctor/{centre_id}/today`
- `GET /doctor/{centre_id}/patients`
- `GET /doctor/{centre_id}/patients/{patient_id}`
- `GET /doctor/{centre_id}/patients/{patient_id}/summary`
- `GET /doctor/{centre_id}/patients/{patient_id}/reports`
- `GET /doctor/{centre_id}/patients/{patient_id}/notes`
- `POST /doctor/{centre_id}/patients/{patient_id}/notes`
- `POST /doctor/{centre_id}/patient-invitations`
- `GET /doctor/{centre_id}/work-queue`
- queue claim, review, revise, sign, reject, and release operations built on existing clinical draft/review primitives

### 8.4 Invitation recipient

- `GET /invitations/pending`
- `POST /invitations/{invitation_id}/accept`
- `POST /invitations/{invitation_id}/decline`

Error responses distinguish unauthenticated, forbidden, inactive membership, unverified doctor, expired invitation, consent required, conflict, and validation failure without leaking whether an out-of-scope patient exists.

## 9. F10 Doctor Workspace

### 9.1 Navigation

The Doctor shell has four primary tabs:

1. **Today**
2. **Patients**
3. **Work Queue**
4. **Profile**

A multi-centre doctor selects an active centre. All data and actions refresh from that explicit centre context. The app never silently merges patient lists across centres.

### 9.2 Today

Today shows deterministic, server-computed counts and priority lists:

- assigned patient count
- drafts awaiting review
- overdue or critical lab follow-ups
- monthly reports due
- consults requiring attention
- high-priority assigned patients

Priority reasons are visible and stable, such as critical result, overdue follow-up, unsigned report, or recent concerning trend. The ordering is derived from documented clinical/operational rules, not an opaque language-model score.

Critical lab escalation is a separate safety workflow with acknowledgement and escalation timestamps; it is not merely a high-priority list item.

### 9.3 Patients

The Patients tab supports search and safe filters over the doctor's assigned patients only. Each card shows minimum useful clinical context, centre, primary status, last activity, and deterministic priority reason. Counts and pagination are computed after authorization filtering.

### 9.4 Patient detail

Patient detail contains:

- demographics and centre context
- conditions and safety flags
- deterministic summary with evidence provenance
- all permitted reports and key values
- predictions clearly labelled as predictions
- clinical drafts awaiting review
- clinician notes and correction history
- recent visits
- therapy outcomes when F12 provides them

The screen uses explicit loading, empty, stale-data, partial-failure, and error states. It never fills missing clinical data with generated guesses.

### 9.5 Work Queue

The queue exposes five stable segments:

1. Monthly reports
2. Sinc drafts
3. Consults
4. Therapy plans
5. Prescriptions and supplements

For F10, therapy plans and prescriptions/supplements return authorized empty contracts until their later milestones are implemented.

Queue items use the existing server-controlled state machine and claim semantics. Every complete, sign, reject, or decision action requires a non-empty clinician note in both the UI and API. The note, evidence, content version, reviewer, and decision are included in the bound hash or immutable decision record so the delivered content cannot diverge from what was reviewed.

### 9.6 Monthly reports

Monthly reports are generated from a fixed source-data cutoff and evidence set, reviewed by an assigned verified doctor, and signed through the same immutable-delivery principles as other clinical content. Regeneration creates a new version; it never overwrites a signed report.

### 9.7 Profile

Profile shows the doctor's identity, verification state, active centre memberships, clinic/signing memberships, and licence-expiry warnings. It does not allow the doctor to self-verify or change authoritative registration fields.

## 10. Role-specific Mobile Screens

### 10.1 Super Admin

- Overview
- Centres
- People
- Invitations
- Licence verification
- Patient read-only viewer
- Access and administrative audit
- Existing platform health and catalogue tools

Clinical views are visually marked read-only. No edit, sign, withdraw, or correction controls are rendered for the Super Admin role.

### 10.2 Centre Owner

- Dashboard
- Doctors
- Patients
- Invitations
- Doctor assignments
- Profile

Clinical detail is hidden or replaced by a consent-required state until patient consent is active.

### 10.3 Doctor

- Today
- Patients
- Work Queue
- Profile

### 10.4 Patient

The existing patient experience gains:

- centre membership details
- assigned doctors and primary doctor
- pending invitation acceptance
- clinical-access consent controls and history

## 11. Immutability and Audit Boundaries

Database triggers and restrictive policies enforce the following regardless of application UI:

- Signed clinical bodies cannot be updated or deleted.
- Clinician signatures cannot be updated, reassigned, or deleted.
- Audit events cannot be updated or deleted.
- Historical assignments and memberships are ended, not removed.
- Verification decisions are appended, not rewritten.
- Clinical note corrections append a superseding record.
- Super Admin clinical access writes an audit event but grants no mutation capability.

Service credentials bypassing ordinary RLS are confined to narrow gateway operations. Each operation still calls explicit authorization and immutable-write procedures; there is no generic administrative table proxy.

## 12. Failure Handling and Idempotency

- Every state-changing request accepts an idempotency key.
- Invitation delivery records distinguish database intent from provider delivery.
- Provider timeouts may be retried without duplicating identities or memberships.
- Assignment changes run in one database transaction.
- Queue claims have expiry/lease semantics to recover abandoned work.
- Signing rejects stale content versions and mismatched hashes.
- Audit writes fail closed for protected cross-user reads.
- Background reconciliation is observable and alerts on repeatedly unrecoverable invitation states.

## 13. Verification and Definition of Done

### 13.1 Database and gateway tests

- Test every role against every protected capability and against every other role's scope.
- Prove Centre A cannot obtain Centre B data through list, detail, count, search, export, or guessed identifiers.
- Prove a Doctor sees only active assignments and loses access immediately when an assignment or membership ends.
- Prove multi-centre Doctor access is isolated by explicit centre context.
- Prove stale JWT role claims do not override current database state.
- Prove Centre Owner clinical access fails without consent and succeeds, audited, with consent.
- Prove every Super Admin clinical read is audited and every Super Admin clinical mutation is refused.
- Prove signed records, signatures, audits, verification decisions, and history cannot be altered.
- Prove invitation authority, idempotency, expiry, resend, revocation, existing-user linking, and reconciliation.
- Prove an unverified Doctor cannot access patients, author notes, claim drafts, or sign.
- Prove only Super Admin can approve clinician verification.
- Prove assignment primary uniqueness and transactional reassignment.
- Prove concierge routes and tools cannot load clinical drafts or unrestricted notes.
- Prove priority ordering is deterministic from documented inputs.
- Prove clinician notes are required for queue completion/sign/reject/decision.
- Prove monthly report generation, versioning, evidence cutoff, hash binding, and immutable signing trail.

### 13.2 Flutter tests

- Route guards and role shells for all four roles.
- Correct user-facing role labels.
- Invitation acceptance, expiry, resend, and existing-account states.
- Centre switching and no cross-centre UI cache leakage.
- Centre roster and assignment workflows.
- Consent-required centre clinical state.
- Doctor Today, Patients, patient detail, Work Queue, and Profile states.
- Loading, empty, partial, offline/stale, forbidden, and retry states.
- Super Admin clinical screens contain no mutation controls.
- Patient centre, assigned-doctor, and consent screens.

### 13.3 End-to-end acceptance

1. Super Admin creates two centres and their owners.
2. Each owner invites doctors and patients by email.
3. One doctor joins both centres and remains isolated by selected centre.
4. Super Admin verifies the doctor.
5. Centre Owner assigns and reassigns primary/additional doctors.
6. Doctor sees only assigned patients and completes a note-bound review.
7. Patient grants and revokes centre clinical consent.
8. Centre Owner clinical access follows the consent immediately.
9. Super Admin reads any patient's clinical record; the read appears in audit; mutation is denied.
10. Signed content remains unchanged under attempted writes from every role.
11. The Android device build passes login, invitation, role navigation, and doctor workflow smoke tests without regressing ring connectivity.

## 14. Migration and Deployment

1. Introduce new tables, enums/checks, constraints, triggers, audit procedures, and RLS without changing existing role values.
2. Backfill existing users into memberships only from reliable existing relationships; ambiguous users remain unassigned for explicit review.
3. Deploy gateway authorization helpers and read-only APIs behind feature flags.
4. Deploy invitation service and reconciliation worker with provider credentials only in server environments.
5. Enable Super Admin and Centre Owner provisioning screens.
6. Enable Doctor workspace per centre after verification and assignment data exists.
7. Monitor denied-access rates, invitation reconciliation, licence expiry, audit insertion failures, and queue lease recovery.
8. Roll out patient consent and assignment visibility.

No migration deletes clinical or identity data. Rollback disables new endpoints and UI flags while preserving newly written history.

## 15. Implementation Sequence

### Phase A — Identity and authorization foundation

- Database migrations for centres, memberships, invitations, verification, assignments, consent, audit, notes, and reports
- Authorization helpers, RLS, immutability triggers, and role labels
- Invitation service and reconciliation worker

### Phase B — Super Admin and Centre Owner management

- Centre, people, invitation, verification, consent-aware viewer, and assignment APIs
- Super Admin and Centre Owner mobile screens

### Phase C — F10 doctor backend

- Doctor patient projection and deterministic prioritization
- Today, patient detail, notes, work-queue, and monthly-report APIs
- Existing clinical review/signing integration

### Phase D — F10 doctor and patient mobile experience

- Doctor navigation and screens
- Patient membership, doctor, invitation, and consent screens
- Multi-centre selection and cache isolation

### Phase E — Verification and rollout

- Database, backend, Flutter, and end-to-end test matrix
- Android device smoke test including ring regression coverage
- Feature-flagged staging deployment and observability review

## 16. Security Invariants Summary

The implementation is acceptable only if all of these remain true:

1. Platform role does not imply centre membership.
2. Centre membership does not imply doctor-patient assignment.
3. Centre ownership does not imply clinical signing authority.
4. Centre roster access does not imply clinical access without patient consent.
5. Super Admin can read all patient data only through audited, read-only operations.
6. A verified Doctor can access only actively assigned patients in the selected active centre.
7. No role can alter signed clinical content, signatures, or audit history.
8. Passwords and invitation secrets never pass through or persist in Telomy application data.
9. Authorization is decided from current server-side state, not client-provided roles or stale JWT claims.
10. Every delivered clinical artifact is provably the exact version a qualified clinician reviewed and signed.
