Read first, in this order:

~/.claude/plans/i-got-new-request-dynamic-emerson.md — the approved plan. F7 is
the phase; "AI health concierge — free-text, grounded in the user's own data" in
the capability table, and "Deliberately late: the concierge (F7)" in the
sequence, are requirements rather than commentary.
healthagent/CLAUDE.md — the Five Principles and Non-Negotiable Rules are binding.
healthagent/app/agent/guardrails.py — read this one properly before writing any
chat code. It is the last deterministic thing between a model and a user, it now
has two profiles, and F7 is the phase that discovers it needs a third.

What F7 is: chat. Free text, grounded in data the server has already computed,
with a human on the other end waiting — which is why `chat bypasses the job
queue` is already a decided question in CLAUDE.md. Everything it narrates has to
come from a tool; nothing it says may be arithmetic it did itself (P2).

Already built (F0–F6), reuse it:

app/activity_agent/tools.py — twelve tools, none taking a user_id. That is the
  isolation mechanism, not a style choice. `get_clinical_insights` is the newest
app/common/context_loader.py — one method per table, every query scoped by
  user_id. The *absence* of a `clinical_drafts` method is load-bearing: a table
  nothing here reads is a table no tool can reach
app/agent/guardrails.py — `apply_guardrails(text, analysis, profile=...)`,
  `gate_delivery`, `body_sha256`. AUTONOMOUS is what chat runs under
app/analytics/ — readiness, biological age, trends, supplements. Deterministic,
  already exposed through both a REST endpoint and a tool. One implementation,
  two callers; a third caller is a third caller, not a third implementation
app/clinical/ — drafts, supplement_drafts, queue_plan, sweep. The clinician
  spine. Chat must never create a draft a human has not asked for
app/analytics/supplement_rules.py + data/supplements.v1.yaml — reviewed medical
  content, signed per rule, bound to a content hash

Nine things that will bite you:

1. **The agent cannot currently repeat what a clinician signed.** This is F6's
   parting gift and the first thing F7 has to decide. A delivered supplement
   insight says "Magnesium supplementation is the usual response to a level
   below the reference range" — a clinician put their registration number
   against those exact words, the user is looking at them on the Labs screen,
   and if the agent quotes them `apply_guardrails` replaces the whole reply with
   SAFE_FALLBACK. Verified, not theorised. The honest fix is a narrow third path
   — quoting text that hashes to a delivered insight for this user — and not
   loosening the autonomous profile, because "the model says a clinician said
   it" is exactly the claim the gate exists to refuse. Until then the concierge
   will be mute about the most valuable thing in the product.

2. **The medication patterns are deliberately broad and chat will hit them.**
   F6 narrowed one (a concentration is not a dose: `92 mg/dL` used to match)
   and widened two (`vitamin D supplementation is the usual response` used to
   pass clean). Expect more of both. Every change belongs in
   `tests/test_guardrails.py` with a sentence saying which direction of error it
   chose and why, because both directions are costly here: a false positive
   makes the concierge useless, a false negative puts unreviewed medical advice
   on a screen.

3. **Grounding is a tool call, never a recollection.** The model must quote the
   number the user is looking at, which is the one in `score_snapshots`, not one
   recomputed a second later from slightly different data. That is the dual-math
   defect with extra steps, and F2 spent a phase closing it.

4. **Budget caps are not optional.** Agents loop. `max_llm_calls` and
   `wall_clock_seconds` already exist in `app/common/config.py`; a chat turn is
   the easiest place in the product to spend hundreds of dollars unnoticed.

5. **A critical value cannot wait for a conversation.** `ESCALATION_LINE` is
   appended regardless of profile and `lab_escalations` fires independently of
   anything the agent does. Chat must not be the only place a user learns
   something urgent, and must never be the thing that delays it.

6. **Nothing is clinically signed off, so most of what chat would say is
   withheld.** `biomarkers.v1.yaml` and `supplements.v1.yaml` are both
   unreviewed. Biological age is withheld, every lab value is `ungraded`, and
   `find_deficiencies` returns nothing. A concierge demo will therefore look
   oddly empty, and the fix is a clinician's signature, not a code change. Ask
   who signs before building a demo around it.

7. **`stranded_total` is the number that says this is failing.** There is still
   no clinician console, so every supplement draft eventually strands: flagged,
   expired, undeliverable. `sweep_queue` reports both the rate (`stranded`) and
   the standing total. A chat that cheerfully says "a clinician will look at
   this" while forty drafts sit stranded is the product lying.

8. **Every test path bypasses RLS.** SQL tests run as `postgres`, Python tests
   use fakes, scripts use the service key. F3 shipped with no INSERT policy on
   lab_uploads, F4 found the identical hole in epigenetic_results, F5 found a
   recursive policy on `clinic_members`, and F6 found that a user with a signed
   recommendation could not delete their account — *because the test asserted
   `confdeltype = 'c'` instead of deleting an account*. If F7 adds a table or a
   cascade, test the behaviour, not the schema.

9. **Verify on the device.** Every phase so far has found a bug there that all
   the tests passed through. The emulator is `Pixel_8`; `flutter emulators
   --launch Pixel_8`, then `flutter build apk --debug
   --dart-define-from-file=.env.supabase` and `adb install -r`. `adb` is at
   ~/Library/Android/sdk/platform-tools and is not on PATH; `flutter devices`
   lists only *running* devices; the package is `com.telomy.telomy` and there is
   no deep link, so navigate by tapping (Labs lives under You → Lab results).
   The signed-in account is test-harness@example.com, and
   `db/dev_clinical_demo.sql` seeds a signed trend, an SLA-released trend, a
   signed supplement recommendation and one deliberately stranded.

Also true, and worth not rediscovering: the flags on a draft come from the
guardrail and never from the producer, and a supplement draft the guardrail
would not flag is refused rather than written — widen that and the SLA path eats
the gate; `convert_to` is STABLE so a sha256 of text cannot be a generated
column; a policy on a table that reads the same table recurses; `rules_for`,
`review_status` and `load_catalog` are all lru_cached and every test that
repoints a YAML path has to clear them; migrations are numbered only, 001–015
are applied, and the runner refuses an edit to an applied file.

Commands:

Backend tests: cd healthagent && PYTHONPATH=. .venv/bin/python -m pytest -q (1190 passing)
Mobile tests: cd mobile && flutter test (314 passing)
Mobile lint: cd mobile && flutter analyze
DB: set -a && . ./healthagent/.env && set +a then psql "$SUPABASE_DB_URL"
SQL tests: psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f healthagent/db/tests/<name>.sql (130 assertions, they roll back)
Migrate: cd healthagent && PYTHONPATH=. .venv/bin/python -m app.migrate.main --dry-run
Seed the clinician demo: psql "$SUPABASE_DB_URL" -f healthagent/db/dev_clinical_demo.sql
Fingerprint a supplement rule: PYTHONPATH=. .venv/bin/python -c \
  "from app.analytics.supplement_rules import rule_fingerprint as f; print(f('vitamin_d_repletion'))"
A report through the live pipeline: PYTHONPATH=. .venv/bin/python scripts/upload_lab_report.py --phenoage --user-id <uuid> --cleanup

Working style: TDD throughout — write the failing test, watch it fail for the
right reason, then implement. Mutate the implementation to check a safety test
actually fails when the gate is removed. Small commits with messages that
explain why. Run both suites before each commit. Push to staging.

Blocked, and F6 could not close it either: **two files need a clinician's
signature.** `biomarkers.v1.yaml` (nine markers unblock biological age: albumin,
creatinine, glucose_fasting, hs_crp, lymphocyte_percent, mcv, rdw,
alkaline_phosphatase, wbc) and `supplements.v1.yaml` (four rules: vitamin D,
B12, iron, magnesium). Both are signed per entry and bound to a content hash, so
each signature is small and editing the entry withdraws it automatically. The
process is built and deliberately unused, because a signature needs a real
name, registration and date. Until then F6 produces no supplement drafts at all
— which is the phase working, not the phase failing, but it does mean the
feature has never run end to end against live data.

Known and deliberately not fixed: the clinician console still does not exist.
F5's schema, policies and `clinician_may_sign` are built and tested for it, and
`db/dev_clinical_demo.sql` stands in by doing in SQL what the console would do.
Until that repo exists nothing claims a draft, so every flagged draft strands.

Deliberately left for later:
- `insights.withdrawn_at` is still written by nobody. The column, the filter in
  `ContextLoader.clinical_insights` and the repository's `isFilter` are all
  there; a clinician who signs something they regret still cannot take it back.
- `trigger: below_optimal` is refused at load time on purpose. Recommending a
  supplement for a value inside the reference range is optimisation, on a much
  weaker evidence base, and adding it is a clinical decision rather than a
  config change.
- Pregnancy is detected by screening free text, which both misses and
  over-refuses. The correct fix is a structured field on the profile, and it
  would improve biological age and supplements together.
- Cross-source wearable dedupe, and a real empty state for a user with no
  wearable at all.
