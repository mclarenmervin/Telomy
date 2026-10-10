Read first, in this order:

~/.claude/plans/i-got-new-request-dynamic-emerson.md — the approved plan. F6 is the
phase; "Personalised supplements, biomarker-driven, clinician-reviewed" in the
capability table, and the guardrail's `clinician_queue` profile under
Doctor-in-loop, are requirements rather than commentary.
healthagent/CLAUDE.md — the Five Principles and Non-Negotiable Rules are binding.
healthagent/db/013_clinical_review.sql — the spine F6 produces into. Read it
before adding a migration; 001–014 are applied.

What F6 is: supplements. Biomarker-driven recommendations that go through the
clinician spine F5 built, which means they are the first drafts in the system
that **cannot** be delivered unreviewed. Everything F5 shipped was observation-
only and therefore eligible for the SLA escape hatch; a supplement draft
carries a routing flag, and the database refuses to deliver a flagged draft
without a signature. That asymmetry is the whole point and is tested from both
sides — do not widen it.

Already built (F0–F5), reuse it:

app/clinical/drafts.py — `trend_drafts` / `create_drafts` / `DraftCandidate`.
  Copy this shape. A producer builds candidates with a `dedupe_key`, and
  `create_drafts` writes the ones that do not exist
app/clinical/queue_plan.py — pure decisions over rows; `insight_row` is the
  single place a draft becomes a delivery, and it calls `gate_delivery`
app/clinical/sweep.py — one pass per scheduler tick: queue, expire claims,
  deliver signatures, expire the SLA. Already wired into `scheduler/main.tick`
app/agent/guardrails.py — `apply_guardrails(text, analysis, profile=...)`,
  `gate_delivery`, `body_sha256`. `CLINICIAN_QUEUE` is the profile a supplement
  draft must be built with; `AUTONOMOUS` would replace the text with
  SAFE_FALLBACK and the queue would fill with drafts that say nothing
app/analytics/marker_trends.py — the deterministic "does this deserve a human"
  rule. A supplement rule is the same shape: ordinary Python, no LLM, and
  nothing in it writes a sentence
app/analytics/catalog.py — `review_status(biomarker_id)` and
  `marker_fingerprint`. Per-marker sign-off, bound to a content hash
app/common/context_loader.py — one method per table, every query scoped by
  user_id. `clinical_insights` and `treating_clinic_id` are the newest. Never
  write a user-scoped query anywhere else
app/activity_agent/tools.py — eleven tools, none taking a user_id
db/tests/clinical_review_test.sql — the RLS test shape, under `set local role
  authenticated` with a JWT claim. 123 assertions across five files

Nine things that will bite you:

1. **A supplement draft can never be delivered unreviewed, and that is enforced
   in three places that must stay in agreement.** `routing_flags` on the draft,
   the `enforce_delivery_gate` trigger in 013, and `gate_delivery` in Python.
   The trigger is the enforcement — the console is a separate repo — and the
   Python exists so the sweep does not fire inserts it knows will fail. If you
   add a delivery path, it goes through `queue_plan.insight_row` or it is not a
   delivery path.

2. **The flags come from the guardrail, not from the producer.** Build the body,
   run `apply_guardrails(body, {"metrics": {}}, profile=CLINICIAN_QUEUE)`, and
   use the flags it returns. A producer that set `routing_flags=['supplement']`
   by hand would drift from what the autonomous profile actually blocks, and a
   draft could reach a user unflagged carrying text the other profile would
   have replaced. There is a test asserting the two profiles agree.

3. **`stranded` is the metric that tells you this phase is failing.** A flagged
   draft that expired can never be delivered, so every supplement draft nobody
   signs is a user who was promised nothing and told nothing.
   `sweep_queue` already counts them. Watch it from day one — with F5 it was
   always zero, because nothing produced a flagged draft yet. F6 is when it can
   move.

4. **A supplement recommendation needs the user's medications, and
   `safety_facts` already fetches them deterministically.** The plan says
   medications must feed interpretation and not only guardrails. A magnesium
   recommendation for someone on a potassium-sparing diuretic is the kind of
   thing this phase exists to route to a human — but it is also the kind of
   thing the draft itself should name in its evidence.

5. **Do not let a supplement draft sit in front of the escalation path.**
   `drafts.draft_for_trend` refuses to draft when the latest value is critical,
   for the reason `lab_escalations` exists. Whatever F6 adds, the same rule
   applies: a potassium of 7 does not get a supplement suggestion, it gets an
   escalation that already fired.

6. **The catalog gate is per marker now.** `review_status(biomarker_id)` and a
   sign-off bound to `marker_fingerprint`. A supplement recommendation that
   leans on a reference range needs that marker signed off, exactly as
   biological age needs its nine. Editing a range withdraws the sign-off
   automatically, so a recommendation can stop being deliverable because
   somebody touched a number — that is correct, and worth a test.

7. **Every test path bypasses RLS.** SQL tests run as `postgres`, Python tests
   use fakes, scripts use the service key. F3 shipped with no INSERT policy on
   lab_uploads, F4 found the identical hole in epigenetic_results, and F5 found
   that a policy on `clinic_members` which reads `clinic_members` recurses. If
   F6 adds a table the phone or the console touches, test it as `authenticated`
   with a JWT claim.

8. **Add the foreign key to auth.users with `on delete cascade`,** and check
   what the cascade reaches. `clinical_reviews.clinician_id` is deliberately
   RESTRICT — a signature is a professional act and must not be erasable by the
   signer — which means deleting a clinician's account fails while signatures
   exist. That is intended. Do not "fix" it.

9. **Verify on the device.** F5 found two bugs on the emulator that every test
   passed through: the confirmed-results list printed `hba1c` and `5.4 %`
   because the tests asserted the identifier, and the dispute box promised "the
   clinician who reviewed it" on a card whose own badge said nobody had. The
   emulator is `Pixel_8`; `flutter emulators --launch Pixel_8`, then
   `flutter build apk --debug --dart-define-from-file=.env.supabase` and
   `adb install -r`. `adb` is at ~/Library/Android/sdk/platform-tools and is not
   on PATH. `flutter devices` lists only *running* devices. The signed-in
   account on the emulator is test-harness@example.com, and
   `db/dev_clinical_demo.sql` seeds a signed finding and an unreviewed one
   against it.

Also true, and worth not rediscovering: there is **no webhook on a signature**
and that is deliberate — the console is a separate repo, and delivery that
depended on it calling us would strand insights forever, so `sweep_queue` runs
every scheduler tick and delivers signed drafts it finds; Railway auto-deploys
from the staging branch; `convert_to` is STABLE so a sha256 of text cannot be a
generated column; a policy on a table that reads the same table recurses, which
is why membership resolves through `clinician_clinic_ids`; migrations are
numbered only, 001–014 are applied, and the runner refuses an edit to an
applied file.

Commands:

Backend tests: cd healthagent && PYTHONPATH=. .venv/bin/python -m pytest -q (1098 passing)
Mobile tests: cd mobile && flutter test (297 passing)
Mobile lint: cd mobile && flutter analyze
DB: set -a && . ./healthagent/.env && set +a then psql "$SUPABASE_DB_URL"
SQL tests: psql "$SUPABASE_DB_URL" -f healthagent/db/tests/<name>.sql (123 assertions, they roll back)
Migrate: cd healthagent && PYTHONPATH=. .venv/bin/python -m app.migrate.main --dry-run
Seed the clinician demo: psql "$SUPABASE_DB_URL" -f healthagent/db/dev_clinical_demo.sql
A report through the live pipeline: PYTHONPATH=. .venv/bin/python scripts/upload_lab_report.py --phenoage --user-id <uuid> --cleanup

Working style: TDD throughout — write the failing test, watch it fail for the
right reason, then implement. Small commits with messages that explain why. Run
both suites before each commit. Push to staging.

Blocked, and this is the one F5 could not close: **biomarkers.v1.yaml is still
unreviewed, so biological age is still withheld.** F5 built the process —
per-marker sign-off bound to a content hash, documented in the YAML with the
command that prints a fingerprint — and deliberately signed nothing, because
that needs a real clinician's name, registration and date. Nine markers
(albumin, creatinine, glucose_fasting, hs_crp, lymphocyte_percent, mcv, rdw,
alkaline_phosphatase, wbc) unblock biological age; a supplement recommendation
leaning on a range needs that marker signed too. Ask who signs before assuming
F6 can show a graded result.

Known and deliberately not fixed: the clinician console does not exist. F5's
schema, policies and `clinician_may_sign` are built and tested for it, and
`db/dev_clinical_demo.sql` stands in by doing in SQL what the console would do.
Until that repo exists, nothing claims a draft and every flagged draft will
eventually strand. That is the correct behaviour and the reason `stranded` is
instrumented, but it means F6's end-to-end story is incomplete without either
the console or a decision to stub it.

Deliberately left for later: `insights.withdrawn_at` is written by nobody. The
column, the filter in `ContextLoader.clinical_insights` and the repository's
`isFilter` are all in place, so withdrawing is one endpoint away — but there is
no path that sets it, and a clinician who signs something they regret currently
has no way to take it back.
