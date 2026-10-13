# F10 completion report — role provisioning and doctor workspace

**Date:** 2026-10-13  
**Branch:** `codex/f10-role-workspace`  
**Target:** `staging`

## Outcome

F10 implements the four-role account and tenancy model requested for Telomy:

| Product role | Database role | Authority delivered |
|---|---|---|
| Super Admin | `admin` | Creates and manages centres, doctors, and patients; can read all patient data through an audited, read-only path; cannot alter clinical content |
| Centre Owner | `centre` | Manages doctors and patients in owned centres, assigns doctors to patients, and reads clinical data only while the patient has active consent |
| Doctor | `doctor` | Creates/invites patients, sees only currently assigned patients, adds append-only notes, and reviews/signs eligible clinical work while licence and membership remain active |
| Patient | `member` | Sees centres and assigned care team, controls centre clinical consent, and cannot assign doctors or widen access |

Supabase Auth authenticates every role. The gateway derives the actor from the verified JWT and resolves current role, centre membership, assignment, consent, and clinician eligibility from PostgreSQL for each protected request. Invitation emails and identity creation remain server-side; no service-role credential or invitation token is shipped in Flutter.

## Delivered work

All 16 tasks in
[`2026-10-12-role-provisioning-doctor-workspace.md`](../superpowers/plans/2026-10-12-role-provisioning-doctor-workspace.md)
are implemented:

1. Centre tenant schema and isolation.
2. Safe invitation intents and append-only clinician verification history.
3. Patient assignments, consent, current-state authorization, and access audit.
4. Append-only clinician notes and immutable signed monthly reports.
5. Idempotent Supabase Auth invitation orchestration and reconciliation.
6. Current-state gateway authorization and fail-closed audited reads.
7. Super Admin and Centre Owner management APIs.
8. Doctor-scoped loader plus deterministic summaries and priority scoring.
9. Doctor APIs for assigned patients, five-segment queue, notes, decisions, and reports.
10. Flutter role labels, invitation acceptance, and shared API errors.
11. Flutter Super Admin and Centre Owner management screens.
12. Centre-isolated Flutter doctor data layer.
13. Doctor Today, Patients, and patient detail screens.
14. Doctor Work Queue and Profile screens.
15. Patient care team and centre-consent controls.
16. Staging migrations, full automated verification, Android installation, and deployment evidence.

The F12 Therapy Plans and F18 Rx/Supplements queue segments are deliberately present but empty until those roadmap phases provide their domain models.

## Commits

| Commit | Change |
|---|---|
| `39ff113` | Centre tenancy and isolated memberships |
| `1e1d4b4` | Invitations and verification history |
| `11cea06` | Assignments, consent, and audited reads |
| `bc72d90` | Notes and monthly reports |
| `32993c9` | Supabase Auth invitation orchestration |
| `e987079` | Current-state authorization |
| `762daf4` | Admin and centre provisioning APIs |
| `3d3544d` | Doctor scoping and deterministic summaries |
| `4702125` | Assigned patients and clinical work queue |
| `0e73021` | Mobile invitation acceptance |
| `003146f` | Mobile centre/doctor/patient management |
| `8864de0` | Centre-scoped doctor data layer |
| `83826ac` | Doctor patients and priorities |
| `dc0e9a5` | Five-segment queue review/sign flow |
| `069ac33` | Patient care team and consent |
| `c85340f` | Production-schema alignment for F10 reads |
| `7df1490` | Mobile password recovery and native deep-link handling |
| `9b64d7b` | Release builds cannot silently use mock authentication |

## Database verification

Migrations `024_centres.sql`, `025_account_invitations.sql`,
`026_patient_access.sql`, and `027_doctor_workspace.sql` were dry-run in a
transaction, applied to staging in numeric order, and recorded in
`schema_migrations` with their normalized SHA-256 checksums. A fresh migration
runner check reports `schema is up to date`.

All 15 SQL test files under `healthagent/db/tests` ran against the deployed
staging schema with `ON_ERROR_STOP=1` and exit code 0. They run in rollback
transactions, so the role-matrix fixtures do not persist. Coverage includes:

- two-centre isolation and a doctor with memberships in both centres;
- assigned versus unassigned patients and a second doctor;
- immediate denial after membership, assignment, licence, or consent ends;
- patient consent grant/revoke and centre clinical-read denial;
- global Super Admin audited reads with clinical writes denied;
- doctor note/report authorization and signed-content mutation rejection;
- append-only administrative, access, verification, note, and signature facts.

Operational reconciliation on 2026-10-13 returned:

- pending unlinked invitations: **0**;
- invitation delivery errors: **0**.

## Backend and mobile verification

| Check | Result |
|---|---|
| Backend pytest suite | **1,680 passed**, 0 failed; 2 existing warnings |
| Flutter test suite | **517 passed**, 0 failed |
| Flutter analyzer | **No issues found** |
| Android staging release APK | Release APK built successfully with the Supabase/Railway staging definitions (66.6 MB) |
| Credential scan | No service-role credential name/value or invitation secret found in Flutter source or APK strings |

The backend suite includes fail-closed audit behavior: if the access-audit
insert fails, the protected patient read returns an error rather than data.
It also proves the clinical sweep can reduce `stranded_total` to zero and
that expired/suspended clinician eligibility is visible and enforced on the
next request.

Release builds cannot use mock authentication, even if `USE_MOCKS` is omitted
or set incorrectly. Staging APKs must be built with `.env.supabase`; this keeps
an unconfigured artifact from accepting credentials locally while its Supabase
features fail later.

## Android evidence

- **Pixel_8 emulator:** APK installed and launched on Android 17 / API 37;
  `com.telomy.telomy/.MainActivity` was foreground; crash-only log inspection
  was clean.
- **Moto G60 physical device:** APK installed and launched on Android 12 /
  API 31; the same activity was foreground with a live process. The patient
  account logged in successfully, `/api/v1/account/care` and
  `/api/v1/invitations/pending` both returned `200`, the patient care screen
  showed the expected no-centre state, ring characteristics streamed
  continuously, and a fresh smoking event completed a full start/stop cycle.
  The UI entered its in-progress state and returned to idle; staging recorded
  the same manual event first as `started` and then as `ended` with a 48-second
  duration. No authentication, gateway, app-level BLE, or crash error occurred.
- **Password recovery:** The final release APK cold-started from
  `telomy://auth/reset-password` on the Pixel emulator and rendered the
  pre-login new-password form. Four focused tests cover the redirect request,
  Supabase password update plus local sign-out, form submission, and router
  handling. The same URI is registered for Android and iOS and is present in
  the staging Supabase Auth redirect allow list.

No credentials are captured in this report.

## Deployment state

The F10 code and this report are pushed to `staging`, and migrations 024–027
are present in staging Supabase. The first Railway gateway deployment failed
because those manually applied migrations had not yet been entered in
`schema_migrations`; predeploy therefore tried to apply the intentionally
non-idempotent files again. The four exact migration checksums were recorded
and a fresh runner reported the schema current.

The staging deployment containing the final auth fix (`7df1490`) is green for
all six Railway services:
gateway, scheduler, worker, activity worker, extraction worker, and score
worker. Live probes then returned `200` for `/health` and the expected `401`
for unauthenticated `/api/v1/account/care`, proving that the F10 route is
deployed (the prior gateway returned `404`).

## Re-run commands

```bash
cd healthagent
PYTHONPATH=. .venv/bin/python -m pytest -q

cd ../mobile
flutter test
flutter analyze
flutter build apk --release --dart-define-from-file=.env.supabase
```

Database tests use `psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f` for every
file under `healthagent/db/tests`; every test transaction rolls back.
