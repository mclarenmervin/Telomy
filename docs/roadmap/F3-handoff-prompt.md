# F3 kickoff prompt

Paste the block below into a fresh Claude Code session started in
`/Users/soumyaranjannayak/Developer/Telomy/Telomy`.

---

Implement **F3** of the clinical intelligence plan: lab report ingestion.

**Read first, in this order:**
1. `~/.claude/plans/i-got-new-request-dynamic-emerson.md` — the approved plan. F3 is the phase; its "Edge cases that will bite" section is requirements, not commentary.
2. `healthagent/CLAUDE.md` — the Five Principles and Non-Negotiable Rules are binding.
3. `db/005_biomarkers.sql` — `lab_uploads` and `biomarker_results` already exist.

**What F3 is:** a user uploads a lab PDF; we extract values; the user confirms them; confirmed values become biomarker results that scores can read. Imaging/DICOM is explicitly out of scope.

**Already built (F0–F2), reuse it:**
- `app/analytics/catalog.py` + `data/biomarkers.v1.yaml` — 31 markers, dual standard/optimal ranges, citations
- `app/analytics/units.py` — `to_canonical(biomarker_id, value, unit)`, per-marker conversions
- `app/analytics/reference_ranges.py` — `RangeResolver` (user → clinic → global), `grade()`
- `app/gateway/auth.py` — `current_user_id` dependency; **endpoints never take user_id as a parameter**
- `app/activity_worker/main.py` — copy this shape for the extraction worker
- `app/gateway/activity_webhooks.py` — copy this shape for the upload webhook
- `app/migrate/main.py` — migrations auto-apply on deploy

**Five things that will bite you, learned the hard way this session:**

1. **Server writes need `origin = 'server'`.** `save_normalized_wellness` deletes every row the phone owns on each sync. A `biomarker_results` row projected into `health_measurements` without that column is deleted on the user's next sync, days later, looking like an extraction bug. See `mobile/supabase/migrations/202610060001_sync_ownership.sql`.

2. **No storage bucket exists yet.** Nothing in the repo uses Supabase Storage; `context_loader.documents()` returns `unconfigured`. Create private buckets, path `{user_id}/{yyyy}/{uuid}.pdf`, RLS on `storage.objects` keyed on `(storage.foldername(name))[1] = auth.uid()::text`. The phone uploads directly to Storage — a 20MB PDF must never pass through the gateway (P4).

3. **The LLM must never produce the number.** It may map *label → biomarker_id* and *unit string → canonical unit*. The value comes from a text-layer span, and a test must assert the extracted value appears verbatim in the page text (P2).

4. **Migrations are numbered only.** `db/NNN_*.sql`; anything else is ignored on purpose, because `db/dev_harness.sql` grants `anon` RLS policies and must never run in production. Never edit an applied migration — the runner refuses it.

5. **Synthetic test data that is too clean proves nothing.** Two fixtures this session passed while testing nothing: one had zero variance so a z-score correctly refused, another omitted `user_id` so every query returned empty. Make fixtures look like real data.

**Lab values that are not numbers** — the schema already has the columns, use them: censored results (`<0.01`, `>500`) via `operator`, qualitative results (`Positive`, `Not detected`) via `result_type` + `value_text`. A censored value may display and may escalate but must be excluded from biological age and correlations. Collection date ≠ report date ≠ upload date; trending uses collection date, and the confirmation UI asks when it cannot be extracted confidently.

**Commands:**
- Backend tests: `cd healthagent && PYTHONPATH=. .venv/bin/python -m pytest -q` (541 passing)
- Mobile tests: `cd mobile && flutter test` (110 passing)
- Mobile lint: `cd mobile && flutter analyze`
- DB: `set -a && . ./healthagent/.env && set +a` then `psql "$SUPABASE_DB_URL"`
- SQL tests: `psql "$SUPABASE_DB_URL" -f healthagent/db/tests/<name>.sql` (they roll back)

**Working style:** TDD throughout — write the failing test, watch it fail for the right reason, then implement. Small commits with messages that explain *why*. Run both suites before each commit. Push to `staging`.

**Blocked:** `biomarkers.v1.yaml` has not been reviewed by a clinician and says so in capitals. Build F3 fully, but nothing extracted should reach a user as a graded result until that review happens. Flag it rather than working around it.

Start by reading the plan and the edge cases, then propose how you will sequence F3 before writing code.
