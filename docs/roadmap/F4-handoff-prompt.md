Read first, in this order:

~/.claude/plans/i-got-new-request-dynamic-emerson.md — the approved plan. F4 is the
phase; its "Verification" and "Edge cases that will bite" sections are requirements,
not commentary.
healthagent/CLAUDE.md — the Five Principles and Non-Negotiable Rules are binding.
healthagent/db/005_biomarkers.sql — `biomarker_results` and `epigenetic_results`
already exist. 006–011 are applied too; read them before adding a migration.

What F4 is: biological age computed on a published model (PhenoAge / Klemera-Doubal
tradition) from confirmed lab values, plus display of third-party epigenetic clocks
the user already has. We compute one number and we display others we never compute.

Already built (F0–F3), reuse it:

app/analytics/catalog.py + data/biomarkers.v1.yaml — 31 markers, dual standard/optimal
  ranges, citations, per-marker unit conversions, and an `aliases` table
app/analytics/units.py — to_canonical(biomarker_id, value, unit)
app/analytics/reference_ranges.py — RangeResolver (user → clinic → global),
  grade() the primitive, grade_for_display() the gated one, is_critical() ungated
app/analytics/scores.py — compute_readiness + persist_snapshot; copy this shape.
  One implementation, three callers: REST, score worker, agent tool
app/common/context_loader.py — biomarker_results(user_id, biomarker_id=None).
  Already filters to confirmed/corrected. Never write a user-scoped query elsewhere
app/activity_agent/tools.py — get_lab_results; copy for a bio-age tool
db/006_score_snapshots.sql — score_snapshots carries model_version, ranges_version,
  inputs_hash and data_quality. A bio-age snapshot belongs here, not in a new table
app/score_worker/, app/scheduler/ — the compute and cadence services already exist

Twelve things that will bite you, learned the hard way across F3:

1. The catalog is missing two of PhenoAge's nine markers. Confirmed by a script:
   7/9 present, `mcv` and `alkaline_phosphatase` absent. Adding them is medical
   content — a clinician PR, same as the range review. F4 cannot compute a real
   PhenoAge until they land. Decide early whether to ship a reduced model with an
   explicit marker count or wait.

2. A biological age IS an interpretation. `clinical_review.reviewed` is false in
   biomarkers.v1.yaml, and grade_for_display returns `ungraded` because of it. A
   number saying "your body is 48" is a far stronger claim than "this HbA1c is
   high". Gate it the same way and say so on screen; the loader refuses
   `reviewed: true` without a named reviewer and a date.

3. Censored values must be excluded. `operator` of '<' or '>' means the true value
   is unknown. They are already never projected into health_measurements, but they
   ARE in biomarker_results — filter on `operator = '='` or you will compute a
   biological age from a number nobody measured.

4. Qualitative results have `value_canonical` NULL and `value_text` set. Filter
   them out rather than letting a None reach arithmetic.

5. `collected_at` is nullable. It is null while the confirmation UI is still
   asking. A bio-age needs a date to belong to; refuse rather than defaulting to
   today.

6. The same marker appears twice legitimately. Fasting and post-prandial glucose
   are one marker and two results, separated by `context`. PhenoAge wants the
   fasting one. Do not average them and do not take whichever sorts first.

7. Sex and age are required and may be absent. RangeResolver already returns None
   for a sex-specific marker when sex is unknown, which is correct. Do the same:
   refuse to produce a number rather than assuming. Pregnancy should refuse too.

8. Every test path bypasses RLS. SQL tests run as `postgres`, Python tests use
   fakes, scripts use the service key. F3 shipped with no INSERT policy on
   lab_uploads and nothing caught it until a real device hit 42501. If F4 adds a
   table the phone reads or writes, test it with
   `set local role authenticated; set local request.jwt.claims = '{"sub":"..."}'`
   and use the `refuses_rls` helper in db/tests/lab_ingest_test.sql — an RLS denial
   is SQLSTATE 42501, not an integrity violation.

9. Migrations are numbered only, 001–011 are applied, and the runner refuses an
   edit to an applied file. db/dev_harness.sql grants anon policies and must never
   run in production, which is why a numbered prefix is how a file opts in.

10. Synthetic fixtures that are too clean prove nothing. Three fixtures across this
    programme passed while testing nothing. A bio-age fixture with every marker
    present, all mid-range, and one collection date tests almost none of the code
    you care about.

11. Verify on the device, not in the database. F3's extraction was correct in
    Postgres and invisible in the app for two separate reasons — the results list
    read a different table, and the agent had no tool. Both looked fine from a SQL
    prompt. The emulator is `Pixel_8`; `flutter emulators --launch Pixel_8`, then
    `flutter build apk --debug --dart-define-from-file=.env.supabase` and
    `adb install -r`. Note `flutter devices` lists only *running* devices.

12. A score nothing consumes is not done. Readiness reads
    TRACKED = heartRate, hrv, temperature, spo2 — no lab marker. Confirming a panel
    today enqueues a recompute that changes nothing. Decide where bio-age is read
    from (snapshot table, screen, agent tool) before computing it.

Also true, and worth not rediscovering: health_measurements.id has no default;
`.env.supabase` carries SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, API_BASE_URL and
USE_MOCKS; a Supabase Database Webhook and a hand-written trigger are the same thing
underneath, and the dashboard only lists the ones it created.

Commands:

Backend tests: cd healthagent && PYTHONPATH=. .venv/bin/python -m pytest -q (784 passing)
Mobile tests: cd mobile && flutter test (209 passing)
Mobile lint: cd mobile && flutter analyze
DB: set -a && . ./healthagent/.env && set +a then psql "$SUPABASE_DB_URL"
SQL tests: psql "$SUPABASE_DB_URL" -f healthagent/db/tests/<name>.sql (38 assertions, they roll back)
Migrate: cd healthagent && PYTHONPATH=. .venv/bin/python -m app.migrate.main --dry-run
A report through the live pipeline: PYTHONPATH=. .venv/bin/python scripts/upload_lab_report.py --demo --user-id <uuid> --cleanup

Working style: TDD throughout — write the failing test, watch it fail for the right
reason, then implement. Small commits with messages that explain why. Run both suites
before each commit. Push to staging.

Blocked: biomarkers.v1.yaml has not been reviewed by a clinician and says so in
capitals, and it is missing mcv and alkaline_phosphatase. Build F4 fully, but no
biological age should reach a user until that review happens. Flag it rather than
working around it.

Start by reading the plan and the verification requirements — minimum marker count,
per-marker contribution cap, bounded to ±N years, the ±5% perturbation stability
test, and recomputing a stored snapshot from its own inputs byte-identically — then
propose how you will sequence F4 before writing code.
