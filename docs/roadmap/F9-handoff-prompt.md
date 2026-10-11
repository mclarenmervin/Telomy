Read first, in this order:

~/.claude/plans/i-got-new-request-dynamic-emerson.md — the approved plan. F8
was the last phase in the sequence, so F9 is the first one that has to decide
what it is. The capability table is the map of what is left: items 1-12 are
now all touched, and three of them are touched on one side only.
healthagent/CLAUDE.md — the Five Principles and Non-Negotiable Rules are binding.
healthagent/app/concierge/turn.py — read this one properly before adding
anything the agent can see. It is still the only place a model's words reach a
user with no human in between, and it now has NINE deterministic steps around
one model call; the docstring lists them and says why each is where it is.

What F8 did: correlations v2, therapies, genetics and environment. Three of
the four are complete on the server and visible to the agent; one of them
(correlations) is complete end to end. What that leaves is below, and the
first section is the honest part.

## Three features are dark, and each is dark for the same reason

The server side of genetics and environment is built, tested and deployed,
and neither does anything for any real user, because **the app cannot put
data into either of them**. Both gaps are a capture surface and both involve
a consent decision that is a product call as much as an engineering one.

1. **Genetics has no upload.** `019_genetic_ingest.sql` creates the bucket,
   the table and the policies; `genetic_webhooks.py` turns a row into a job;
   `extraction_worker/genetics_handler.py` imports it. The whole path is
   tested. Nothing in the app can write to the `genetics` bucket, so the only
   way to exercise it today is a script. What is needed is a file picker, a
   direct-to-Storage upload (the file must NOT pass through the gateway) and
   the row insert that fires the webhook — the same shape
   `lib/features/labs/` already uses for a PDF. The part that needs thought
   is not the plumbing: it is what you tell somebody before they upload a
   genome, given that we keep four rows of it and discard the rest.

2. **Environment has no location.** `021_environment_snapshots.sql`, the
   Open-Meteo adapter and the nightly sweep are built and the adapter is
   verified against the live provider. `environment.location_for` returns
   None for everybody, because nothing writes `consentLocation`,
   `coarseLatitude` or `coarseLongitude` to the profile, so the sweep runs
   every night and fetches nothing. **The sweep has never made a live call
   with a real user's coordinate, deliberately** — that is the one outward
   facing act in this programme and it should be somebody's decision rather
   than a side effect of a deploy. What is needed is a location permission
   flow, the consent flag, and a coarse coordinate on the profile.

3. **Therapies and correlations are complete and limited.** Both are ACUTE or
   same-day only. Neither answers the question a user actually asks, which is
   "is this working for me over months". Read the "deliberately left out"
   notes in `therapies.v1.yaml` and `correlations.v1.yaml` before you add a
   chronic model: sauna raises heart rate for the hour after and lowers
   resting heart rate over months, so a model with no timescale in it would
   be wrong for one of those two readings and cannot tell which.

## Already built (F0–F8), reuse it

app/analytics/statistics.py — `pearson`, `student_t_two_tailed`,
  `pearson_p_value`, `one_sample_t`, `benjamini_hochberg`,
  `effective_sample_size`. Pure Python, no scipy. Anything that produces a
  p-value uses these or it is a second implementation
app/analytics/correlations.py + therapy_effect.py — the two engines, and the
  shape to copy: a declared hypothesis set, FDR over it, an effect floor and
  a direction check, with everything tested returned and a reason attached
app/analytics/{correlation_mechanisms,therapy_catalog,variant_catalog}.py —
  three loaders in the `catalog.py` family, all signed per entry against a
  content hash, all shipping UNREVIEWED
app/agent/data_tools.py — fourteen user-scoped tools, none taking a user_id.
  `get_correlations`, `get_therapy_effects` and `get_environment` are the
  newest. A new tool goes HERE unless it only makes sense for one caller
app/agent/numbers.py — `check_numbers`, `collect_tool_numbers`
app/agent/guardrails.py — three profiles, `gate_delivery`, `body_sha256`,
  `promises_human_action`. Every gate between a model and a user is here
app/analytics/genetics.py — `import_raw`, `context_for_results`,
  `screen_for_genetic_risk`. Read the module docstring before touching any of it
app/common/context_loader.py — one method per table, every query scoped by
  user_id. `daily_measurements`, `therapy_sessions`, `readings_between`,
  `events_between`, `environment_snapshots` and `variant_context` are new

## Nine things that will bite you

1. **A route the database rejects is an uncapped turn.** F8 added
   `genetic_risk` to `turn.py` and not to the check constraint. The insert
   failed with 23514, `save_turn` logged and swallowed it — correctly, since
   the reply was already guarded and somebody was waiting for it — and the
   endpoint returned 200 with an answer that was never recorded.
   `turns_since` counts that table, so the turn also did not count towards
   the daily cap. Every test on both sides passed: the Python fakes have no
   constraints and the SQL test asserted that a nonsense route is refused,
   not that every real one is accepted. Both halves are covered now
   (`test_every_route_the_turn_can_produce_is_one_the_database_accepts` parses
   the constraint out of db/*.sql). **Add a route, add a migration.**

2. **`create or replace function` in a migration is not additive.** 019
   redefined `delete_own_account` by copying the body from 007 and adding a
   bucket. 007's body had been superseded by 009, which stopped deleting
   `storage.objects` rows — that makes a file unreachable without reclaiming
   it, because Postgres cannot reach the object store — and started recording
   a purge for the sweep. The copy silently reverted it, so a deleted user's
   lab PDFs would have been hidden from them rather than deleted. The SQL
   test caught it by asserting on the function body. **The version to extend
   is whichever migration last touched it, not the one that created it.**

3. **A variant may still never originate an insight, and now there are four
   places holding that up.** There is no `get_variants` tool; there is no
   loader method that returns variants without lab results first
   (`variant_context` takes them as a required argument); the allowlist keeps
   four rsids and discards 600,000; and `screen_for_genetic_risk` answers
   "do I have the Alzheimer's gene" deterministically before the model runs.
   Each has a test named after it. Widening any one of them undoes the others.

4. **Nothing is clinically signed off, and there are now five files waiting.**
   `biomarkers.v1.yaml`, `supplements.v1.yaml`, `correlations.v1.yaml`,
   `therapies.v1.yaml` and `variants.v1.yaml`. The consequence differs by
   file on purpose: a supplement rule produces nothing at all unsigned, while
   a correlation, a therapy effect and a genotype are all still REPORTED and
   only their explanation is withheld. The reasoning is that a measurement
   may be shown without a verdict — which is what the Labs screen already
   does — and an explanation is a clinical claim. If you disagree with that
   line, it is drawn in `review_status` in each of the three new loaders.

5. **Only declared pairs are tested, and that is the feature.** Both new
   engines build their hypothesis set from a catalog, so `m` for the false
   discovery rate is the number of things we were ever prepared to report.
   Adding a pair makes the correction harsher for every other pair, which is
   the correct incentive. Do not add a "test everything and filter after"
   mode; it is the thing F8 removed.

6. **Daily series are not independent samples.** Over 200 trials of two
   independent 60-day random walks, 141 clear p < 0.05 with |r| >= 0.3 on the
   raw day count and 7 do on the effective one. Anything new that correlates
   daily physiological series goes through `effective_sample_size` or it is
   reporting noise with a citation.

7. **A critical value still cannot wait.** `ESCALATION_LINE` is appended to a
   chat turn whenever `open_lab_escalations` returns anything, after every
   replacement and gated on nothing. F8 saw it survive a `guardrail_replaced`
   turn on a real device. Nothing in the chat path writes `acknowledged_at`,
   and nothing in F9 should.

8. **`stranded_total` is still the number that says this is failing**, and
   the clinician console still does not exist. Five unreviewed content files
   now depend on a review process that has never run once. That is no longer
   a gap in one feature; it is the single thing most limiting this product,
   and F9 should consider whether building the console beats building a sixth
   thing that needs signing.

9. **Verify on the device, and give it the disk.** Every phase has found a
   bug there that all the tests passed through; F8 found four. The emulator
   is `Pixel_8`, `adb` is at ~/Library/Android/sdk/platform-tools and is not
   on PATH, the package is `com.telomy.telomy`, there is no deep link so
   navigate by tapping. Each `flutter build apk --debug` writes ~200MB; the
   machine went from 23GB free to 14GB over one session.

## How to drive the device, which F8 worked out

Build ONE APK pointed at a local gateway and you can control every server
variable without touching Railway:

    cp mobile/.env.supabase mobile/.env.local-gateway.json   # then set
    #   "API_BASE_URL": "http://10.0.2.2:8099"
    cd healthagent && set -a && . ./.env && set +a
    PYTHONPATH=. .venv/bin/python -m uvicorn app.gateway.main:app --port 8099
    cd ../mobile && flutter build apk --debug \
        --dart-define-from-file=.env.local-gateway.json
    adb install -r build/app/outputs/flutter-apk/app-debug.apk

`ApiConfig` permits http only because APP_ENV defaults to `development`.
Supabase stays the real project, so the JWT verifies and history reads.
Restart the gateway with `MAX_CHAT_TURNS_PER_DAY=1` or with no model key to
exercise the 429 and the `unavailable` route. Docker holds 8000.

`db/dev_correlations_demo.sql` seeds 60 days built so exactly one declared
pair holds and two are withheld, plus 8 sauna sessions — a seed where
everything correlates proves nothing about a screen whose job is to refuse
most things. `db/dev_clinical_demo.sql` seeds the signed, SLA-released and
stranded findings. The test account is test-harness@example.com
(99f9d063-1d36-48fe-a1e1-609e4fcf269d); its one `lab_escalations` row is
acknowledged, and setting `acknowledged_at` to null is how you see the
escalation line (put it back afterwards).

## Also true, and worth not rediscovering

A model's behaviour varies between two identical runs, which is the argument
for a deterministic gate over a line in a prompt — F8 asked the model to
quote everything and the misattribution gate fired on the first try, which it
had never done against a real model before; an unreadable journal field is
absent and not zero, because the phone's reader returns 0 and that
manufactures correlations out of missing data; a night of sleep is a union of
overlapping stage records and not a measurement type; the baseline cancels
out of a before/after difference, which is why therapy evidence needs two
hours of readings per session and not a fortnight; a therapy must be excluded
from its own confounders or every session is dropped silently forever;
`FutureProvider` without `autoDispose` will keep telling a user "not enough
data yet" for the life of the app after the data arrives; `lru_cache` is on
every catalog loader and every test that repoints a YAML path has to clear
it; migrations are numbered only, 001–021 are applied, and the runner refuses
an edit to an applied file.

## Commands

Backend tests: cd healthagent && PYTHONPATH=. .venv/bin/python -m pytest -q (1541 passing)
Mobile tests: cd mobile && flutter test (363 passing)
Mobile lint: cd mobile && flutter analyze
DB: set -a && . ./healthagent/.env && set +a then psql "$SUPABASE_DB_URL"
SQL tests: psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f healthagent/db/tests/<name>.sql (163 assertions, they roll back)
Migrate: cd healthagent && PYTHONPATH=. .venv/bin/python -m app.migrate.main --dry-run
Seed: psql "$SUPABASE_DB_URL" -f healthagent/db/dev_correlations_demo.sql
Ask the concierge through the real pipeline:
  PYTHONPATH=. .venv/bin/python scripts/ask_concierge.py --user-id <uuid> --suite --dry
A report through the live pipeline: PYTHONPATH=. .venv/bin/python scripts/upload_lab_report.py --phenoage --user-id <uuid> --cleanup

## Working style

TDD throughout — write the failing test, watch it fail for the right reason,
then implement. Mutate the implementation to check a safety test actually
fails when the gate is removed; F8 ran about twenty mutations and two of them
found tests that were passing for the wrong reason. Small commits with
messages that explain why. Run both suites before each commit. Push to staging.

## Blocked, and F8 could not close it either

**Five files need a clinician's signature**, up from two. The process is
built and deliberately unused, because a signature needs a real name, a
registration number and a date. Each file says in its header what it is
claiming and what it costs to leave unsigned.

## Known and deliberately not fixed

- The clinician console still does not exist.
- Open-Meteo is free for non-commercial use only. A paid plan is a launch
  blocker, noted in the adapter where it will be found.
- **The app can time out while the server is still working.** Dio waits 90s;
  a turn may make up to `max_llm_calls` model calls plus tool calls, each
  bounded by `wall_clock_seconds` but not bounded in total. F8 added three
  tools, and a correlations call is four queries. The fix is a total deadline
  on the turn, server-side, below the client's timeout.
- **There is no way to clear a conversation without deleting the account.**
  `chat_turns` is append-only from every side on purpose.
- **No streaming.** The guardrails work on finished text.
- `insights.withdrawn_at` is still written by nobody.
- `trigger: below_optimal` is refused at load time on purpose.
- Pregnancy is detected by screening free text. The correct fix is a
  structured field on the profile.
- Cross-source wearable dedupe, and a real empty state for a user with no
  wearable at all.
- A genetics export is kept in its bucket until a retention sweep removes it,
  and that sweep is NOT written: `storage_purges` handles account deletion
  and `genetic_uploads.purged_at` has nobody to set it. A genome sitting in a
  bucket longer than intended is the most sensitive version of a chore.
