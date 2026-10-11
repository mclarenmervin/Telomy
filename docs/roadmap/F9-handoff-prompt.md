Read first, in this order:

docs/roadmap/2026-10-11-demo-parity-programme.md — the programme this phase
opens. §2 (the role model), §3 (the design system is already shared) and §6
decisions 1, 2 and 3 are requirements rather than commentary.
healthagent/CLAUDE.md — the Five Principles and Non-Negotiable Rules are binding.
In this phase the security rules are the phase, not a constraint on it.
healthagent/db/013_clinical_review.sql — read it properly before adding any
role column. `clinic_members.role` already exists, already means something, and
`clinician_may_sign()` already depends on it. F9 adds a second axis without
touching the first.

What F9 is: the spine three roles stand on, and the fourth role nobody has
designed yet. Four pieces: `app_role` enforced in Postgres; a navigation shell
per role in Flutter; the platform-admin surface; and the design tokens plus the
component vocabulary — `Prov` and `ConfBar` above all — that every later phase
spends. No clinical feature ships in F9. If something in F9 computes a health
number, it is in the wrong phase.

Already built (F0–F8), reuse it:

healthagent/db/013_clinical_review.sql — `clinics`, `clinic_members`,
  `clinician_may_sign()`, and the policy discipline. The comment about a
  recursive policy on `clinic_members` is a scar; read it before writing a
  policy that reads the table it protects
healthagent/app/gateway/auth.py — `current_user_id()`, which never reads a user
  id from a path, query or body. Role resolution belongs beside it and obeys
  the same rule: the role comes from the token's subject, never from the request
healthagent/app/common/context_loader.py — one method per table, every query
  scoped by user_id. A doctor or centre reading another person's rows is a new
  scoping question, and the answer is a new loader, not a widened one
mobile/lib/app/router.dart — the `StatefulShellRoute.indexedStack` with four
  branches, and a redirect that already knows how to send an unauthenticated
  user to `/onboarding`. Role routing is the same mechanism with one more fact
mobile/lib/core/widgets/app_shell.dart — the shell, the rail at ≥ 760 px, and
  the floating log button. A doctor does not log a meal; the shell takes the
  role or there will be three forks of it by F11
mobile/lib/app/theme/app_colors.dart — teal `#1F5C4E`, identical to the
  prototype's. The palette is extended here, not replaced

Eight things that will bite you:

1. **A role in client storage is not authorisation.** The prototype keeps the
   role in `AsyncStorage` and every endpoint trusts it, which is fine for a
   simulator and is a cross-tenant leak in production. `app_role` is a column on
   the profile, every policy reads the column, and the JWT claim — if you add
   one — is a cache that grants nothing on its own. Write the test that proves
   it: mint a token whose claim says `doctor` for a user whose column says
   `member`, and assert the doctor paths return zero rows.

2. **`clinic_members.role` is a different axis and must stay one.** It is
   membership inside one clinic (`patient`, `clinician`, `admin`) and
   `clinician_may_sign()` reads it at signing time by design. `app_role` is what
   the person is on the platform. One human can be a member, a clinician at two
   clinics and an operator of a centre; the moment those two columns are
   conflated, a booking path starts consulting a signing function.

3. **A centre is not a clinic.** Decision 3 in the programme doc: new table,
   because a clinic signs and a centre sells. F11 builds it, but F9 is where the
   role name is chosen, and choosing `clinic_owner` here means renaming it in
   F11 across policies that will by then be load-bearing.

4. **The admin role is the one that can read everything, so define what it
   cannot.** Recommendation, and the prompt is where to argue with it if it is
   wrong: an admin may read every *operational* row — queue depth, licences,
   centres, devices, consent state, erasure requests — and no member's health
   rows without a consent row saying so. Admin actions are append-only in their
   own table and visible to admins, including the admin who performed them.
   An admin who can silently read a Vault is a DPDP problem wearing a support
   ticket.

5. **`stranded_total` goes on the admin dashboard in this phase.**
   `app/clinical/sweep.py` already reports it, and it has been the number that
   says the product is lying since F5: drafts flagged, expired, undeliverable,
   because no console exists to claim them. F9 is the first phase that can show
   it to someone who can act. It belongs on the admin surface before the queue
   has a single real user.

6. **The two unsigned YAML files are the admin surface's first real job.**
   `app/analytics/data/biomarkers.v1.yaml` (nine markers that unblock biological
   age) and `supplements.v1.yaml` (four rules) are signed per entry and bound to
   a content hash. F6 built the mechanism and left it unused because a signature
   needs a real name, registration and date. Build the interface that collects
   one. It does not produce the signatory — that is still the open question from
   F6 — but it removes the excuse.

7. **Every number on every existing screen has to go through `Prov`.** This is
   the roadmap's F01 and F02 arriving as components rather than as a feature, and
   it is the only reason F9 touches screens that are already shipped. The
   primitive is already populated — `health_measurements.source` and `.quality`
   on every row — and no UI reads it. After this phase a number rendered without
   a source, a time and a confidence is a review failure, which is a cheap rule
   to hold only if the component exists first. Port the vocabulary by name:
   `Screen`, `Card` (with `tone`), `Row`, `Section`, `T`, `Chip`, `StatusChip`,
   `Prov`, `ConfBar`, `Stat`, `Segmented`, `ListRow`, `Empty`, `Loading`,
   `ErrorState`, `Toast`. The prototype's 73 screens are built from these and
   nothing else, which is why they look like one product.

8. **`Empty`, `Loading` and `ErrorState` are not polish.** The prototype's empty
   states say what will appear here and when ("Sessions appear here five minutes
   before the booked slot"), its loaders say what is loading ("Reading your
   Vault…"), and its errors retry. Three phases from now the therapy tab's most
   common state will be "no reliable signal yet", and if `Empty` is a shrug by
   then it will read as a broken feature. Build them properly once.

Verification that is the point of the phase, not a checkbox:

- A test per role that runs **as the other three** and asserts zero rows. Not a
  schema assertion — F7's prompt is explicit that every test path bypasses RLS,
  and F3, F4, F5 and F6 each shipped a policy hole that a schema test passed.
  Authenticate as each role and read.
- Deep-link a member's session at a doctor route and at an admin route. The
  router must refuse it; the API must refuse it independently. Two gates, both
  tested, because the router is not a security boundary.
- An admin action written, then an attempt by an admin to edit or delete it.
- A stale JWT claim granting nothing (bite 1).
- Then on the device: `Pixel_8`, all four roles, and the rail layout at ≥ 760 px.

Commands:

Backend tests: cd healthagent && PYTHONPATH=. .venv/bin/python -m pytest -q
Mobile tests: cd mobile && flutter test
Mobile lint: cd mobile && flutter analyze
DB: set -a && . ./healthagent/.env && set +a then psql "$SUPABASE_DB_URL"
SQL tests: psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f healthagent/db/tests/<name>.sql
Migrate: cd healthagent && PYTHONPATH=. .venv/bin/python -m app.migrate.main --dry-run
Device: flutter emulators --launch Pixel_8, then cd mobile && flutter build apk
  --debug --dart-define-from-file=.env.supabase and adb install -r. adb is at
  ~/Library/Android/sdk/platform-tools and is not on PATH; the package is
  com.telomy.telomy; there is no deep link, so navigate by tapping.

Migrations are numbered only and the runner refuses an edit to an applied file.
016 is applied; F8 takes the next numbers, so check what landed before claiming
one.

Working style: TDD throughout — write the failing test, watch it fail for the
right reason, then implement. Mutate the implementation to check a safety test
actually fails when the gate is removed; in this phase that means deleting a
policy and watching a role test go red. Small commits with messages that explain
why. Run both suites before each commit. Push to staging.

Blocked, and F9 cannot close it: **decision 1 in the programme doc.** The
approved plan put the clinician console in a separate repo with no agent access;
F10 puts the doctor role in this app. F9 can build the role spine either way —
that is why it is first — but F10 should not start until whoever owns the
regulatory posture has said yes. Ask before building the shell that assumes it.

Deliberately left for later:
- No health computation, no clinical surface, no therapy, no telemetry. Those
  are F10 onward and the temptation to "just add the doctor's patient list" here
  is how a spine phase becomes three phases.
- Payments stay out (decision 7). Any price rendered in F9 is indicative and
  labelled.
- The centre tenancy tables are F11's. F9 chooses the role name only.
