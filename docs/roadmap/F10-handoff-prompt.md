Read first, in this order:

~/.claude/plans/i-got-new-request-dynamic-emerson.md — the approved plan. Its
sequence ran out at F8, so F9 and this one are chosen rather than given. The
capability table is now touched on every row; what is left is the quality of
each, and one thing that blocks a third of them at once.
healthagent/CLAUDE.md — the Five Principles and Non-Negotiable Rules are binding.
healthagent/app/concierge/turn.py — read properly before adding anything the
agent can see. Nine deterministic steps around one model call; the docstring
lists them and says why each is where it is.
docs/roadmap/F9-handoff-prompt.md — its "three features are dark" section is
now obsolete, and the rest of it still holds. F9 closed two of the three.

## Where this actually is

Every capability in the plan now has a working vertical, and two of them were
finished in F9:

| # | Capability | State |
|---|---|---|
| 5 | Correlations v2 | Complete, verified end to end |
| 9 | Genetics | Complete, verified end to end with a real file |
| 10 | Environment | Complete, verified against the live provider |
| 11 | Therapies | Complete, verified through chat and a screen |

"Complete" means a user can reach it and it tells them something true. It does
NOT mean it tells them much, and the reason is the next section.

## The one thing worth doing before anything else

**Five content files need a clinician's signature and nothing else will move
until they get one.** `biomarkers.v1.yaml`, `supplements.v1.yaml`,
`correlations.v1.yaml`, `therapies.v1.yaml`, `variants.v1.yaml`.

What that costs today, on real screens:

* biological age is withheld — "Not yet. Awaiting clinical review."
* every lab value is `ungraded`, so the concierge says "I can describe it but
  not grade it" constantly
* `find_deficiencies` returns nothing, so the supplement queue stays empty
* a correlation says "Nobody has reviewed why these two are related"
* a therapy effect says "Nobody has reviewed why this happens"
* a genotype says "Nobody has reviewed what they mean yet"

Four of those six sentences were added in the last two phases. Every phase
now adds another thing that needs signing, and the rate is increasing.

**The database knows of exactly one clinician and it is a fixture**: Dr Meera
Raghavan, KMC-2019-44871, in "Bonphul Demo Clinic", seeded by
`dev_clinical_demo.sql`. `clinical_reviews` has two rows, both demo. There is
no real backlog yet because there are no real users, which is precisely why
this is the moment to fix it rather than after there is one.

Two halves, and only one of them is code:

1. the clinician console, a separate repo per the plan — CRUD over Postgres
   with RLS on `clinic_members`, no agent access
2. a real person with a registration number willing to sign

Building (1) without (2) produces nothing. F10 should establish whether (2)
is obtainable before committing to (1), and if it is not, should consider
whether a sixth unsigned file is worth adding.

## Not deployed, which matters more than it looks

Everything F8 and F9 built runs locally and on the device against a local
gateway. Check each of these before assuming a user can reach any of it:

* **the Railway gateway has none of the new code.** `/api/v1/correlations`,
  `/api/v1/therapies`, `/api/v1/environment`, `/api/v1/genetics/variants` and
  `/webhooks/genetic-uploads` exist only on this branch. Four screens will
  show their offline state against production right now.
* **the scheduler must be running** or the environment sweep never fires and
  no genetics upload is ever imported. Confirm it is deployed and ticking.
* **`genetic_uploads` has no webhook trigger** and cannot get one from a
  migration — the `lab_uploads` one was made in the dashboard because it
  embeds the shared secret. F9 made this survivable rather than fatal: the
  scheduler sweeps `uploaded` rows every tick, so the import works without
  the trigger. Adding the trigger is still worth doing (it drops the wait
  from up to 60s to immediate) and is no longer load-bearing.
* migrations 001–021 are applied to the live database.

## Nine things that will bite you

1. **A route the database rejects is an uncapped turn.** F8 added
   `genetic_risk` to `turn.py` and not to the check constraint. The insert
   failed with 23514, `save_turn` logged and swallowed it — correctly, the
   reply was guarded and somebody was waiting — and the endpoint returned
   200 with an answer that was never recorded. `turns_since` counts that
   table, so the turn also escaped the daily cap. Covered now by a test that
   parses the constraint out of db/*.sql. **Add a route, add a migration.**

2. **`create or replace function` in a migration is not additive.** 019
   redefined `delete_own_account` by copying from 007, silently reverting
   009's change from deleting `storage.objects` rows to recording a purge —
   which is the difference between deleting a file and hiding it. The SQL
   test caught it. **Extend whichever migration last touched it.**

3. **The app writes strings; the server read a boolean.** Every consent in
   this product is `profile['consentX'] == 'true'`, because
   `user_preferences.profile` is a `Map<String, String>`. F8's location gate
   accepted only the boolean, so the nightly sweep would have found nobody
   for the life of the feature with no symptom but an empty screen. Found
   only by writing the app half. There are now drift tests in both
   directions; add one whenever a key crosses that boundary.

4. **A variant may still never originate an insight, and five things hold
   that up.** No `get_variants` tool; no loader method that returns variants
   without lab results first; an allowlist that keeps 4 rsids of ~600,000;
   `screen_for_genetic_risk` answering before any model runs; and
   `describe_stored` kept deliberately separate from `context_for_results`
   so the screen's path cannot become the agent's. Each has a test named
   after it. Widening any one undoes the others.

5. **Only declared pairs are tested, and that is the feature.** Both
   statistical engines build their hypothesis set from a catalog, so `m` for
   the false discovery rate is the number of things we would ever report.
   Adding a pair makes the correction harsher for every other pair, which is
   the correct incentive. Do not add a "test everything and filter after"
   mode.

6. **Daily series are not independent samples.** Over 200 trials of two
   independent 60-day random walks, 141 clear p < 0.05 with |r| >= 0.3 on
   the raw day count and 7 do on the effective one. Anything new that
   correlates daily series goes through `effective_sample_size`.

7. **A critical value still cannot wait.** `ESCALATION_LINE` is appended
   whenever `open_lab_escalations` returns anything, after every replacement
   and gated on nothing — F8 watched it survive a `guardrail_replaced` turn
   on a device. Nothing in the chat path writes `acknowledged_at`.

8. **Published scales are banded on whole numbers.** A UV peak of 10.2 was
   labelled "extreme" on a real screen; WHO rounds to the nearest integer, so
   10.2 is 10 and "very high". Half-up is written out because Python's
   `round` goes to even. If a third scale arrives, it rounds too.

9. **Verify on the device, and give it the disk.** Every phase has found a
   bug there that all tests passed through: F8 found four, F9 found four
   more (a consent sheet whose buttons were off the bottom of the screen,
   variants rendering as bare rsids, the UV band, and a page blurb that had
   become false). Each `flutter build apk --debug` writes ~200MB.

## How to drive the device

One APK pointed at a local gateway gives control of every server variable
without touching Railway:

    cp mobile/.env.supabase mobile/.env.local-gateway.json   # then set
    #   "API_BASE_URL": "http://10.0.2.2:8099"
    cd healthagent && set -a && . ./.env && set +a
    PYTHONPATH=. .venv/bin/python -m uvicorn app.gateway.main:app --port 8099
    cd ../mobile && flutter build apk --debug \
        --dart-define-from-file=.env.local-gateway.json
    adb install -r build/app/outputs/flutter-apk/app-debug.apk

`ApiConfig` permits http only because APP_ENV defaults to `development`.
Supabase stays the real project, so the JWT verifies. Restart the gateway
with `MAX_CHAT_TURNS_PER_DAY=1` or no model key to exercise the 429 and the
`unavailable` route. Docker holds 8000. `adb` is at
~/Library/Android/sdk/platform-tools and is not on PATH; the package is
`com.telomy.telomy`; there is no deep link, so navigate by tapping.

### The test account's state

test-harness@example.com, 99f9d063-1d36-48fe-a1e1-609e4fcf269d. It now has:

* 3 insights (signed trend, SLA-released trend, signed supplement) and one
  deliberately stranded draft, from `dev_clinical_demo.sql`
* 60 days of HRV / resting heart rate / sleep and 8 sauna sessions, from
  `dev_correlations_demo.sql` — built so exactly one declared pair holds and
  two are withheld, because a seed where everything correlates proves nothing
  about a screen whose job is to refuse most things
* 4 wellness genotypes from two real imports (a 23andMe export and a VCF),
  and **no APOE**, which is the point
* a coarse location of Bengaluru and one environment snapshot
* one `lab_escalations` row, acknowledged. Setting `acknowledged_at` to null
  is how you see the escalation line; put it back afterwards
* `/sdcard/Download/genome.txt` on the emulator, a synthetic 5,009-row export
  containing APOE, HFE and TCF7L2, for re-testing the refusal

## Also true, and worth not rediscovering

A model's behaviour varies between two identical runs, which is the argument
for a deterministic gate over a line in a prompt; an unreadable journal field
is absent and not zero, because the phone's reader returns 0 and that
manufactures correlations out of missing data; a night of sleep is a union of
overlapping stage records and not a measurement type; the baseline cancels
out of a before/after difference, which is why therapy evidence needs two
hours of readings per session and not a fortnight; a therapy must be excluded
from its own confounders or every session is dropped silently forever;
`FutureProvider` without `autoDispose` will keep telling a user "not enough
data yet" for the life of the app after the data arrives — this has now cost
two screens; a Flutter test asserting inside a callback that never fires is a
test that passes having checked nothing; `lru_cache` is on every catalog
loader and every test that repoints a YAML path has to clear it; migrations
are numbered only and the runner refuses an edit to an applied file.

## Commands

Backend tests: cd healthagent && PYTHONPATH=. .venv/bin/python -m pytest -q (1566 passing)
Mobile tests: cd mobile && flutter test (410 passing)
Mobile lint: cd mobile && flutter analyze
DB: set -a && . ./healthagent/.env && set +a then psql "$SUPABASE_DB_URL"
SQL tests: psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f healthagent/db/tests/<name>.sql (163 assertions, they roll back)
  — check psql's EXIT CODE when scripting these. A dropped connection prints
    "psql: error:" in lower case and a grep for ERROR counts it as a pass.
Migrate: cd healthagent && PYTHONPATH=. .venv/bin/python -m app.migrate.main --dry-run
Seed: psql "$SUPABASE_DB_URL" -f healthagent/db/dev_correlations_demo.sql
Ask the concierge: PYTHONPATH=. .venv/bin/python scripts/ask_concierge.py --user-id <uuid> --suite --dry

## Working style

TDD throughout — failing test, watch it fail for the right reason, then
implement. Mutate the implementation to check a safety test actually fails
when the gate is removed; across F8 and F9 about thirty mutations found four
tests that were passing for the wrong reason. Small commits explaining why.
Both suites before each commit. Push to staging.

## Known and deliberately not fixed

- The clinician console does not exist. See the second section.
- Open-Meteo is free for NON-COMMERCIAL use only. A paid plan is a launch
  blocker, noted in the adapter where it will be found.
- **A genetics export is never purged.** `genetic_uploads.purged_at` has
  nobody to set it and `019`'s retention story is unimplemented, so a genome
  sits in its bucket indefinitely — which contradicts what the consent sheet
  tells people ("the file itself is deleted once the import has worked").
  That is a promise the product is currently not keeping, and it is the
  smallest high-value thing on this list.
- **The app can time out while the server is still working.** Dio waits 90s;
  a turn has no total bound and now has fourteen tools to choose from. The
  fix is a server-side deadline below the client's timeout.
- No way to clear a conversation without deleting the account.
- No streaming; the guardrails work on finished text.
- `insights.withdrawn_at` is written by nobody.
- `trigger: below_optimal` is refused at load time on purpose.
- Pregnancy is detected by screening free text; the fix is a structured field.
- Cross-source wearable dedupe, and a real empty state for a user with no
  wearable at all.
- Correlations and therapy effects are same-day and acute only. Neither
  answers "is this working for me over months", which is what people ask.
  Read the "deliberately left out" notes in both catalogs before adding a
  chronic model: sauna raises heart rate for the hour after and lowers
  resting heart rate over months.
