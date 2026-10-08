Read first, in this order:

~/.claude/plans/i-got-new-request-dynamic-emerson.md — the approved plan. F5 is the
phase; its "Doctor-in-loop" section, "Clinical workflow" under edge cases, and the
"Clinician gate" verification line are requirements, not commentary.
healthagent/CLAUDE.md — the Five Principles and Non-Negotiable Rules are binding.
healthagent/db/005_biomarkers.sql — `clinics` and `clinic_members` already exist.
006–012 are applied too; read them before adding a migration.

What F5 is: the clinician spine. Drafts the agent writes, reviews a clinician
signs, insights the user finally sees, and a gate that makes an unsigned draft
physically unreadable. It blocks F6 (supplements) and F7 (concierge), and it is
what finally unblocks the biological age F4 built.

Already built (F0–F4), reuse it:

app/analytics/scores.py — compute_readiness + compute_biological_age + the
  COMPUTERS registry. One implementation, three callers: REST, score worker,
  agent tool. Copy this shape for anything new that produces a number
app/analytics/biological_age.py — `biological_age_for_display` is the pattern
  for a gated artefact: the ungated function and the gated one side by side,
  with the gate applied before anything can be persisted
app/analytics/reference_ranges.py — grade() / grade_for_display() / is_critical()
app/common/context_loader.py — one method per table, every query scoped by
  user_id. `score_snapshot(user_id, kind)` and `epigenetic_results` are the
  newest. Never write a user-scoped query anywhere else
app/activity_agent/tools.py — ten tools, none taking a user_id
app/agent/guardrails.py — where the `profile` parameter goes
db/tests/biological_age_test.sql — the RLS test shape, under `set local role
  authenticated` with a JWT claim. 65 assertions across four files
tests/conftest.py — the suite is hermetic now; it pins its own environment

Nine things that will bite you, learned across F3 and F4:

1. `clinical_drafts` has NO user-facing select policy. That is the enforcement,
   not a filter in a query someone has to remember. Write the SQL test that
   proves a user cannot read a draft before you write the table — and note that
   an UPDATE or DELETE blocked by an absent policy matches no rows and succeeds
   trivially rather than raising 42501, so what you assert is the absence of the
   policy in pg_policies. An INSERT does raise, because WITH CHECK runs on the
   new row. db/tests/biological_age_test.sql has both shapes.

2. Every test path bypasses RLS. SQL tests run as `postgres`, Python tests use
   fakes, scripts use the service key. F3 shipped with no INSERT policy on
   lab_uploads and nothing caught it until a real device hit 42501; F4 found the
   identical hole in epigenetic_results. If F5 adds a table the phone or the
   console reads or writes, test it as `authenticated` with a JWT claim.

3. Add the foreign key to auth.users with `on delete cascade`. 006 did not, and
   every score snapshot outlived the account it described until 012 fixed it.
   `delete_own_account` deletes the auth.users row and relies on cascades for
   everything else, so a missing FK is a silent DPDP failure. Drafts, reviews
   and insights all need one.

4. The delivery gate is a hash comparison, not a status check:
   `review.signed_body_sha256 == sha256(delivery_body)`. A one-character edit
   after signing must make the insight structurally undeliverable. Test the edit,
   not just the happy path.

5. `clinician_may_sign()` is checked at SIGNING time, not at claim time. A
   clinician whose licence lapses mid-review must not be able to sign what they
   claimed an hour ago.

6. Safety is never gated on a human. `ESCALATION_LINE` already bypasses the
   guardrail rewrite, and `is_critical` is deliberately ungated and deliberately
   not routed through RangeResolver. A potassium of 7 cannot wait in a queue.
   Whatever F5 adds, do not let it sit in front of that path.

7. The guardrail `profile` parameter must default to today's behaviour.
   `autonomous` is the current default and must stay byte-identical;
   `clinician_queue` attaches routing flags instead of replacing text — in that
   profile, today's guardrail would block exactly the content a clinician is
   meant to sign.

8. A score nothing consumes is not done, and F4 is the live example. Biological
   age is computed, stored, rendered and agent-readable — and withheld, because
   `clinical_review.reviewed` is false in biomarkers.v1.yaml. **F5 is what
   unblocks it.** Decide early whether the clinician review of the catalog is
   part of F5's workflow or a separate manual step, because right now it is a
   hand-edit to a YAML file with no process around it.

9. Verify on the device, not in the database. F3's extraction was correct in
   Postgres and invisible in the app; F4's marker labels read "Rdw" and "Hs crp"
   on screen with every test green, and the clock form showed stale errors under
   corrected input. Both looked fine from a SQL prompt and from `flutter test`.
   The emulator is `Pixel_8`; `flutter emulators --launch Pixel_8`, then
   `flutter build apk --debug --dart-define-from-file=.env.supabase` and
   `adb install -r`. `adb` is at ~/Library/Android/sdk/platform-tools and is not
   on PATH. `flutter devices` lists only *running* devices. The signed-in account
   on the emulator is test-harness@example.com.

Also true, and worth not rediscovering: Railway auto-deploys from the staging
branch, so a push updates the workers — F4's catalog change reached the deployed
extraction worker that way, and until it did, the live pipeline silently
extracted the old marker set; `health_measurements.id` has no default;
`.env.supabase` carries SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, API_BASE_URL and
USE_MOCKS; migrations are numbered only, 001–012 are applied, and the runner
refuses an edit to an applied file.

Commands:

Backend tests: cd healthagent && PYTHONPATH=. .venv/bin/python -m pytest -q (913 passing)
Mobile tests: cd mobile && flutter test (255 passing)
Mobile lint: cd mobile && flutter analyze
DB: set -a && . ./healthagent/.env && set +a then psql "$SUPABASE_DB_URL"
SQL tests: psql "$SUPABASE_DB_URL" -f healthagent/db/tests/<name>.sql (65 assertions, they roll back)
Migrate: cd healthagent && PYTHONPATH=. .venv/bin/python -m app.migrate.main --dry-run
A report through the live pipeline: PYTHONPATH=. .venv/bin/python scripts/upload_lab_report.py --phenoage --user-id <uuid> --cleanup

Working style: TDD throughout — write the failing test, watch it fail for the
right reason, then implement. Small commits with messages that explain why. Run
both suites before each commit. Push to staging.

Blocked: biomarkers.v1.yaml still has not been reviewed by a clinician and says
so in capitals. Biological age is built, tested and deliberately withheld —
`biological_age_for_display` returns no number and writes none, so nothing leaks
through the select policy on score_snapshots. Flipping `reviewed: true` with a
named reviewer and a date is the only change needed, and it is F5's business to
decide who does that and how it is recorded.

Known and deliberately not fixed: PhenoAge cannot satisfy the plan's "perturb one
marker ±5%, age moves <1 year". RDW carries the model's largest coefficient, so
5% at a typical 13.5% is 2.47 years and MCV is 1.34. The tests assert the model's
real bound plus the property the requirement was reaching for — that assay
imprecision moves the answer by under a year. Do not "fix" this by capping a
published coefficient.

Start by reading the plan and the clinician-gate verification requirements —
the state machine, the no-select-policy enforcement, the signing-time licence
check, and the post-signature hash check — then propose how you will sequence F5
before writing code.
