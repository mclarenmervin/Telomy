# F11 Centre Role Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> `superpowers:executing-plans` to implement this plan task by task in the
> current isolated worktree.

**Goal:** Deliver an isolated, consent-scoped Centre Owner workspace with
rooms, services, concurrency-safe bookings, deterministic dashboard metrics,
responsive Flutter UI, staging deployment, and Android verification.

**Architecture:** PostgreSQL owns centre membership, consent, operational
lifecycle constraints, booking transitions, and immutable history. FastAPI
derives the current centre from an active owner-membership header, scopes every
service-role query, audits protected member reads, and calls one deterministic
metrics implementation. Flutter consumes only those scoped APIs and uses the
existing role shell for phone and tablet layouts.

**Tech stack:** PostgreSQL/Supabase Auth and RLS, Python/FastAPI/Pydantic,
Flutter/Dart/Riverpod/Dio/GoRouter, pytest, SQL assertion tests, Railway, Android
ADB/Flutter tooling.

**Spec:**
`docs/superpowers/specs/2026-10-13-f11-centre-role-design.md`

## Global constraints

- Keep global database roles exactly `admin`, `centre`, `doctor`, and `member`.
- Centre Owner routes derive centre scope from `X-Centre-Membership`; they do
  not accept raw `centre_id` values.
- Every operational table carries an immutable `centre_id`, and every gateway
  service-role query filters by the derived scope.
- Consent is current PostgreSQL state and is checked on every member read.
- No direct authenticated booking mutation; booking state transitions are
  database commands with row locking and expected versions.
- No payment claims: prices and totals are labelled indicative everywhere.
- Centre risk output is deterministic and non-diagnostic.
- Super Admin may operate all centres but cannot mutate clinical facts.
- No new agent loader or tool can access centre or clinical workspace data.
- Follow RED → GREEN → REFACTOR for every production behavior.
- Commit only exact F11 paths from the isolated worktree.

## Task 1: Membership-derived centre context

**Files:**

- Modify: `healthagent/app/gateway/tenancy.py`
- Modify: `healthagent/tests/test_tenancy.py`
- Modify: `healthagent/tests/test_centre_api.py`

**Interface produced:** `resolve_centre_owner_scope()` and FastAPI dependency
that resolves `X-Centre-Membership` into immutable actor, membership, and centre
scope.

- [ ] Write failing tests for a valid owner membership, a foreign membership
  row, wrong owner, suspended membership, ended membership, inactive centre,
  missing header, and an owner selecting either of two valid memberships.
- [ ] Assert the resolver reads `centre_memberships` by membership ID and actor
  ID, then reads the active centre; it must not accept a centre ID.
- [ ] Run focused tests and verify RED:

  ```bash
  cd healthagent
  PYTHONPATH=. .venv/bin/python -m pytest -q \
    tests/test_tenancy.py tests/test_centre_api.py
  ```

- [ ] Implement the scope dataclass and fail-closed dependency.
- [ ] Replace the current Centre Owner `_require_owner(centre_id)` test helpers
  with the new scope contract without yet adding operations.
- [ ] Run focused tests and the F10 doctor/role regressions.
- [ ] Commit:

  ```bash
  git add healthagent/app/gateway/tenancy.py \
    healthagent/tests/test_tenancy.py healthagent/tests/test_centre_api.py
  git commit -m "refactor(tenancy): derive centre context from membership"
  ```

## Task 2: Centre operations schema and isolation

**Files:**

- Create: `healthagent/db/028_centre_operations.sql`
- Create: `healthagent/db/tests/centre_operations_test.sql`

**Interface produced:** centre timezone/currency, rooms, room hours, services,
room-service links, bookings, booking transition history, and authorization
predicates/procedures.

- [ ] Write the SQL test first. Create two centres, two owners, doctors, and
  patients; switch to the `authenticated` role with each JWT identity.
- [ ] Prove each owner sees zero rooms, services, bookings, transitions, or
  aggregates from the other centre.
- [ ] Prove direct authenticated INSERT/UPDATE/DELETE fails for all operational
  tables.
- [ ] Test room retirement, service retirement, historical references, valid
  room-hour windows, overlapping room-hour rejection, and same names allowed in
  different centres.
- [ ] Run and verify RED:

  ```bash
  cd healthagent
  set -a && . ./.env && set +a
  psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 \
    -f db/tests/centre_operations_test.sql
  ```

- [ ] Implement additive migration `028` with checks, indexes, immutable
  identity/history triggers, RLS, grants/revokes, and security-definer helpers
  with pinned search paths.
- [ ] Run migration in a rollback-safe test database/session, then run the new
  SQL test and existing `centres_test.sql`, `patient_access_test.sql`, and
  `doctor_workspace_test.sql`.
- [ ] Commit only the migration and SQL test:

  ```bash
  git add healthagent/db/028_centre_operations.sql \
    healthagent/db/tests/centre_operations_test.sql
  git commit -m "feat(centre): add isolated operational schema"
  ```

## Task 3: Concurrency-safe booking commands

**Files:**

- Modify: `healthagent/db/028_centre_operations.sql`
- Modify: `healthagent/db/tests/centre_operations_test.sql`
- Create: `healthagent/tests/test_booking_concurrency.py`

**Interface produced:** `create_centre_booking(...)` and
`transition_centre_booking(...)` procedures with expected-version conflicts.

- [ ] Extend failing SQL tests for booking creation outside availability,
  incompatible room/service, foreign patient, inactive room/service, overlap,
  and immutable price/duration snapshots.
- [ ] Assert every transition:

  - booked → checked-in, no-show, cancelled;
  - checked-in → completed or cancelled;
  - all terminal rows reject further transitions;
  - booked → completed and checked-in → no-show are rejected;
  - no-show fails immediately before the 15-minute boundary and succeeds at it;
  - stale expected versions conflict;
  - transition history is append-only.

- [ ] Add a two-connection concurrency test showing only one of two overlapping
  room bookings commits and only one same-version transition succeeds.
- [ ] Implement transaction-scoped room locking, row locking, state-command
  mapping, version increment, and append-only transition insertion.
- [ ] Run SQL and concurrency tests until green.
- [ ] Amend only while migration `028` is still unapplied; once applied, any
  correction must be a new numbered migration.
- [ ] Commit:

  ```bash
  git add healthagent/db/028_centre_operations.sql \
    healthagent/db/tests/centre_operations_test.sql \
    healthagent/tests/test_booking_concurrency.py
  git commit -m "feat(bookings): enforce booking lifecycle in postgres"
  ```

## Task 4: Expiring consent and immediate visibility

**Files:**

- Modify: `healthagent/db/028_centre_operations.sql`
- Modify: `healthagent/db/tests/centre_operations_test.sql`
- Modify: `healthagent/app/gateway/api/accounts.py`
- Modify: `healthagent/tests/test_invitations.py`
- Modify: `mobile/lib/features/patient_care/` only where renewal/expiry display
  is required
- Modify: `mobile/test/patient_care_test.dart`

**Interface produced:** expiring and renewable `clinical_care` consent.

- [ ] Add RED tests that an active consent admits the member, expiration removes
  the member, renewal creates history rather than rewriting the grant, and
  revocation removes the member on the next query.
- [ ] Add a migration backfill for existing active grants and update
  `centre_can_read_clinical` to require `expires_at > now()`.
- [ ] Update the patient consent RPC/API without placing authorization in the
  Flutter client.
- [ ] Show expiry/renewal honestly on the patient care screen.
- [ ] Run SQL, backend consent, and Flutter patient-care tests.
- [ ] Commit:

  ```bash
  git add healthagent/db/028_centre_operations.sql \
    healthagent/db/tests/centre_operations_test.sql \
    healthagent/app/gateway/api/accounts.py healthagent/tests \
    mobile/lib/features/patient_care mobile/test/patient_care_test.dart
  git commit -m "feat(consent): expire and renew centre clinical access"
  ```

## Task 5: Scoped Centre Owner loader and audited members

**Files:**

- Create: `healthagent/app/gateway/centre_loader.py`
- Create: `healthagent/tests/test_centre_loader.py`
- Modify: `healthagent/app/gateway/access_audit.py`
- Modify: `healthagent/tests/test_centre_api.py`

**Interface produced:** one centre-scoped loader for operations and consented
member projections, plus fail-closed batch audit.

- [ ] Write RED tests with mixed Centre A/Centre B tables and prove every loader
  method returns only the resolved centre.
- [ ] Prove patient roster rows without current consent never enter member
  results, counts, risk candidates, or not-seen candidates.
- [ ] Prove revoked/expired consent disappears without reconstructing the
  loader and that no email/phone/address/raw clinical value is returned.
- [ ] Prove each returned member receives an access-audit event and any audit
  insert failure prevents the payload from being returned.
- [ ] Implement separate gateway-only loader; do not modify agent
  `ContextLoader` or tool registration.
- [ ] Run focused tests plus context-loader and concierge-tool tests to prove no
  new model-reachable method exists.
- [ ] Commit:

  ```bash
  git add healthagent/app/gateway/centre_loader.py \
    healthagent/app/gateway/access_audit.py healthagent/tests
  git commit -m "feat(centre): load and audit consented members"
  ```

## Task 6: Single deterministic centre metrics implementation

**Files:**

- Create: `healthagent/app/analytics/centre_metrics.py`
- Create: `healthagent/tests/test_centre_metrics.py`
- Modify only if reuse requires it: `healthagent/app/analytics/severity.py`
- Modify only if reuse requires it: `healthagent/app/analytics/marker_trends.py`

**Interface produced:** pure calculation of dashboard metrics and safe
follow-up projection.

- [ ] Write a hand-worked fixture covering current and previous calendar months,
  timezone boundaries, completed/cancelled/no-show/future/inside-grace bookings,
  two services, two rooms, zero denominators, a never-seen member, and a
  recently active member.
- [ ] Assert exact indicative booking values, session counts, member counts,
  active/not-seen lists, today's bookings, no-show numerator/denominator/rate,
  and per-service capacity minutes/utilised minutes/rate.
- [ ] Assert the 15-minute no-show boundary on both sides.
- [ ] Assert risk output contains only evidence class/date and the safe action,
  never marker values, diagnosis, or treatment text.
- [ ] Implement pure functions with documented formulas. Reuse severity and
  marker-trend decisions; do not copy their math.
- [ ] Run focused analytics tests plus existing severity/marker-trend tests.
- [ ] Commit:

  ```bash
  git add healthagent/app/analytics/centre_metrics.py \
    healthagent/tests/test_centre_metrics.py
  git commit -m "feat(analytics): define reconciled centre metrics"
  ```

## Task 7: Centre and Super Admin operational APIs

**Files:**

- Modify: `healthagent/app/gateway/api/centre.py`
- Create: `healthagent/app/gateway/api/admin_centre_operations.py`
- Modify: gateway router registration file discovered from current source
- Modify: `healthagent/tests/test_centre_api.py`
- Create: `healthagent/tests/test_admin_centre_operations_api.py`

**Interface produced:** Centre Owner and Super Admin API surfaces from the spec.

- [ ] Write RED API tests for dashboard, members, doctors, invitations,
  assignments, rooms/hours, services/compatibility, booking lists/creation, and
  transition commands.
- [ ] Assert Centre Owner requests use `X-Centre-Membership`, old centre-ID
  routes no longer exist, foreign object IDs return 404, and invalid/stale
  transitions return 409.
- [ ] Assert authentication is 401, authorization is 403, protected read audit
  failure is 503, and pagination is bounded.
- [ ] Assert Super Admin can perform operational actions for either centre but
  cannot call clinical mutation procedures.
- [ ] Implement thin endpoints over the scope dependency, loader, metrics, and
  database procedures. Do not duplicate formulas in route code.
- [ ] Run focused API tests, then all gateway/auth/role tests.
- [ ] Commit:

  ```bash
  git add healthagent/app/gateway/api/centre.py \
    healthagent/app/gateway/api/admin_centre_operations.py \
    healthagent/app/gateway healthagent/tests
  git commit -m "feat(gateway): expose scoped centre operations"
  ```

## Task 8: Flutter centre context, models, and repository

**Files:**

- Modify: `mobile/lib/features/centre/models/centre_roster.dart`
- Create: `mobile/lib/features/centre/models/centre_operations.dart`
- Modify: `mobile/lib/features/centre/data/centre_repository.dart`
- Modify: `mobile/lib/features/centre/providers/centre_provider.dart`
- Modify: `mobile/test/centre_management_test.dart`

**Interface produced:** membership-selected, centre-scoped mobile data layer.

- [ ] Write RED repository tests proving `mine` returns membership IDs, every
  Centre Owner operation sends `X-Centre-Membership`, and no operation puts a
  centre ID in its URL/body.
- [ ] Add parsing tests for dashboard, booking status/version/transitions,
  members, rooms, room hours, services, currency minor units, and errors.
- [ ] Assert switching membership invalidates all centre-specific providers and
  stale Centre A results cannot appear in Centre B.
- [ ] Implement immutable models, repository calls, and provider families.
- [ ] Map 409 conflicts to a refresh-specific domain error and 403/503 to honest
  messages.
- [ ] Run focused Flutter tests and analyzer on changed files.
- [ ] Commit:

  ```bash
  git add mobile/lib/features/centre mobile/test/centre_management_test.dart
  git commit -m "feat(centre): add membership-scoped mobile data layer"
  ```

## Task 9: Responsive dashboard

**Files:**

- Replace: `mobile/lib/features/centre/screens/centre_dashboard_screen.dart`
- Create: `mobile/lib/features/centre/widgets/centre_metric_card.dart`
- Create: `mobile/lib/features/centre/widgets/centre_dashboard_sections.dart`
- Create: `mobile/test/centre_dashboard_test.dart`

- [ ] Write widget tests for all required metrics, current-versus-previous
  indicative booking value, sessions, members, active, no-shows, today's
  bookings, utilisation, follow-up members, and not seen in 30 days.
- [ ] Assert “indicative” and configured-capacity explanations are visible.
- [ ] Assert empty/loading/error states and F12/F13 honest placeholders.
- [ ] Pump at phone width and ≥760 px; prove no overflow and appropriate
  multi-column/rail behavior.
- [ ] Implement the dashboard with existing design tokens and shared surfaces.
- [ ] Run focused widget tests.
- [ ] Commit:

  ```bash
  git add mobile/lib/features/centre/screens/centre_dashboard_screen.dart \
    mobile/lib/features/centre/widgets mobile/test/centre_dashboard_test.dart
  git commit -m "feat(centre): render responsive operational dashboard"
  ```

## Task 10: Booking management UI

**Files:**

- Create: `mobile/lib/features/centre/screens/bookings_screen.dart`
- Create: `mobile/lib/features/centre/screens/booking_editor_screen.dart`
- Create: `mobile/lib/features/centre/widgets/booking_card.dart`
- Create: `mobile/test/centre_bookings_test.dart`

- [ ] Write RED widget tests for date/status filters, create validation, legal
  command visibility, no-show grace messaging, stale-version refresh, and
  disabled terminal bookings.
- [ ] Implement create flow and command actions using returned status/version.
- [ ] Keep server authority: never infer success locally after a 409.
- [ ] Run focused tests and analyzer.
- [ ] Commit:

  ```bash
  git add mobile/lib/features/centre/screens/bookings_screen.dart \
    mobile/lib/features/centre/screens/booking_editor_screen.dart \
    mobile/lib/features/centre/widgets/booking_card.dart \
    mobile/test/centre_bookings_test.dart
  git commit -m "feat(centre): manage booking lifecycle"
  ```

## Task 11: Consent-scoped members and team workflows

**Files:**

- Replace/modify: `mobile/lib/features/centre/screens/patients_screen.dart`
- Modify: `mobile/lib/features/centre/screens/doctors_screen.dart`
- Modify: `mobile/lib/features/centre/screens/assignments_screen.dart`
- Modify: `mobile/lib/features/centre/screens/centre_profile_screen.dart`
- Create: `mobile/test/centre_members_test.dart`

- [ ] Write RED tests showing consented members only, never-consented and
  revoked members absent, contact fields absent, safe follow-up wording, last
  visit/next booking, and assignment actions.
- [ ] Preserve doctor invitation and patient assignment behavior from F10 while
  separating roster membership from consented members.
- [ ] Move Team entry points into Members/Profile as designed.
- [ ] Run new tests plus `centre_management_test.dart` and role regressions.
- [ ] Commit:

  ```bash
  git add mobile/lib/features/centre/screens mobile/test/centre_members_test.dart
  git commit -m "feat(centre): show consented members and team"
  ```

## Task 12: Services, rooms, and navigation

**Files:**

- Create: `mobile/lib/features/centre/screens/services_screen.dart`
- Create: `mobile/lib/features/centre/screens/service_editor_screen.dart`
- Create: `mobile/lib/features/centre/screens/room_editor_screen.dart`
- Modify: `mobile/lib/app/role_routes.dart`
- Modify: `mobile/lib/app/router.dart`
- Modify: `mobile/test/app_role_test.dart`
- Modify: `mobile/test/role_shell_test.dart`
- Create: `mobile/test/centre_services_test.dart`

- [ ] Write RED tests for service create/retire, duration, indicative price,
  currency formatting, compatible rooms, room hours, validation, and immutable
  historical booking display.
- [ ] Update Centre Owner tabs to Dashboard, Bookings, Members, Services,
  Profile and map router branches from the same tab list.
- [ ] Assert other roles are redirected from every new centre route.
- [ ] Assert tablet rail and phone bottom bar both expose the five destinations.
- [ ] Implement screens and routing without forking the shared shell.
- [ ] Run focused tests, role-shell tests, and analyzer.
- [ ] Commit:

  ```bash
  git add mobile/lib/features/centre mobile/lib/app/role_routes.dart \
    mobile/lib/app/router.dart mobile/test
  git commit -m "feat(centre): manage services rooms and navigation"
  ```

## Task 13: Full verification and review

**Files:** Modify only when a failing test proves necessary, with a new
regression test first.

- [ ] Run every SQL test against a database with migrations through `028` and
  check command exit codes.
- [ ] Run backend suite:

  ```bash
  cd healthagent
  PYTHONPATH=. .venv/bin/python -m pytest -q
  ```

- [ ] Run Flutter suite and analyzer:

  ```bash
  cd mobile
  flutter test
  flutter analyze
  ```

- [ ] Search for forbidden Centre Owner raw centre IDs, unscoped operational
  queries, payment wording, contact export, and new agent loader methods.
- [ ] Review branch diff against the specification and F11 handoff acceptance
  matrix.
- [ ] Run the `superpowers:requesting-code-review` and
  `superpowers:verification-before-completion` skills before integration.
- [ ] Commit any test-led corrections separately.

## Task 14: Staging migration and deployment

**Files:**

- Create: `docs/roadmap/F11-completion-report.md`

- [ ] Run migration dry-run using the exact staging environment and confirm
  only `028_centre_operations.sql` is pending.
- [ ] Push the reviewed branch to `staging` only after all local suites are
  green.
- [ ] Confirm the gateway pre-deploy runner records the `028` checksum and all
  Railway services reach green state.
- [ ] Probe `/health`, unauthenticated Centre Owner routes (401), authenticated
  centre membership resolution, and a cross-centre object attempt (404).
- [ ] Execute a staging two-centre scenario: create separate rooms/services,
  confirm zero cross-rows, create/transition a booking, verify metrics, grant
  then revoke consent, and verify immediate disappearance.

## Task 15: Android and tablet verification

**Files:**

- Modify: `docs/roadmap/F11-completion-report.md`

- [ ] Confirm connected Android devices with `adb devices` and Flutter device
  discovery.
- [ ] Build a release APK using staging Supabase configuration:

  ```bash
  cd mobile
  flutter build apk --release --dart-define-from-file=.env.supabase
  ```

- [ ] Install on the connected phone and verify Centre Owner login, centre
  switching, dashboard, services/rooms, booking lifecycle, members, assignments,
  and consent revocation.
- [ ] Verify ≥760 px layout on an Android tablet/emulator with NavigationRail,
  readable dashboard cards, and no overflow.
- [ ] Run a patient/ring smoking-event regression so F11 does not break the
  already verified F10/device path.
- [ ] Record device IDs/models, APK provenance, timestamps, staging commit,
  migration checksum, test counts, API evidence, and screenshots/log references
  without storing patient values or secrets.
- [ ] Commit the completion report:

  ```bash
  git add docs/roadmap/F11-completion-report.md
  git commit -m "docs: record F11 staging and device verification"
  ```

## Task 16: Final completion audit

- [ ] Map every explicit F11 roadmap and approved-spec requirement to current
  evidence in SQL tests, backend tests, Flutter tests, staging state, and device
  verification.
- [ ] Confirm no requirement is supported only by intent or indirect evidence.
- [ ] Confirm the worktree contains no unrelated changes.
- [ ] Confirm `origin/staging` points at the verified F11 completion commit.
- [ ] Only then mark the F11 goal complete.

## Execution order

Execute Tasks 1–16 in order. Database facts and tenant isolation land before
their API consumers; APIs land before Flutter consumers; deployment happens
only after full local verification. Use small, exact-path commits and do not
modify or sweep in changes from the dirty primary checkout.
