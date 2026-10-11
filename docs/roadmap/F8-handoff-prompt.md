Read first, in this order:

~/.claude/plans/i-got-new-request-dynamic-emerson.md — the approved plan. F8 is
"correlations v2 · genetics · environment · therapies — additive, any order",
which is the only phase in the sequence written as a list rather than a
commitment. Items 5, 9, 10 and 11 in the capability table are the requirements.
healthagent/CLAUDE.md — the Five Principles and Non-Negotiable Rules are binding.
healthagent/app/concierge/turn.py — read this one properly before adding
anything the agent can see. It is the only place a model's words reach a user
with no human in between, and every tool you add is reachable from it.

What F8 is: four features that share nothing with each other and everything
with what is already built. Correlations v2 needs significance filtering and a
plausibility gate; genetics needs file import and the discipline that a variant
can never *originate* an insight; environment needs a real source behind the
free-text form; therapies need before/after evidence. Each one is additive.
None of them is allowed to become a second implementation of something that
already exists.

Already built (F0–F7), reuse it:

app/agent/data_tools.py — ten user-scoped tools, none taking a user_id, shared
  by the activity agent and the concierge. A new tool goes HERE unless it only
  makes sense for one caller
app/agent/numbers.py — `check_numbers` and `collect_tool_numbers`. A figure in
  prose must trace to a value a tool returned. Shared by the report and chat
app/agent/guardrails.py — `apply_guardrails(text, analysis, profile=...,
  signed_bodies=...)`, three profiles, `gate_delivery`, `body_sha256`,
  `promises_human_action`. Every gate between a model and a user is in this file
app/concierge/ — turn, tools, prompt, grounding. `turn.py` documents the order
  of the deterministic steps and why each one is where it is
app/common/context_loader.py — one method per table, every query scoped by
  user_id. `chat_turns`, `turns_since` and `open_lab_escalations` are the newest
app/analytics/ — readiness, biological age, trends, supplements, safety.
  Deterministic, exposed through a REST endpoint AND a tool. One implementation
app/clinical/ — drafts, supplement_drafts, queue_plan, sweep. Anything that
  tells a user to do something goes through here and comes back signed

Nine things that will bite you:

1. **The concierge can now repeat a clinician's words, and only those.** The
   `quoting_signed` guardrail profile exempts text that appears verbatim in an
   insight delivered to *this* user, supplied from the scoped loader. With
   nothing signed it IS the autonomous profile. If F8 adds a surface where a
   model quotes something — a correlation a clinician reviewed, say — it uses
   this mechanism or it does not quote.

2. **A genetic variant may never originate an insight.** The plan names APOE as
   the live hazard and the rule is in the risk table: a variant appears only as
   context beside a measured marker. The temptation will be a `get_variants`
   tool that the concierge can reach on its own, and that tool is a diagnosis
   generator with extra steps. Whatever you build, ask what the concierge says
   when somebody asks "do I have the Alzheimer's gene" — the answer has to be
   deterministic and it has to be decided before the tool exists.

3. **Correlation is the easiest place in this product to say something false.**
   ~45 pairs with no multiple-comparison correction is the current state, and
   the plan asks for significance filtering *and* a physiological-plausibility
   gate. The second one is the harder half: a statistically clean correlation
   between two things with no mechanism is noise with a p-value, and a
   conversational interface will narrate it confidently.

4. **Chat costs money per request and the caps are the only thing stopping it.**
   `max_chat_turns_per_day` before the model, `max_llm_calls` and
   `max_tool_calls` inside it, `wall_clock_seconds` on the model. A new tool
   that is slow or that the model likes calling repeatedly changes the economics
   of every turn.

5. **A critical value still cannot wait.** `ESCALATION_LINE` is appended to a
   chat turn whenever `open_lab_escalations` returns anything, after every
   replacement and gated on nothing — including on whether the model worked.
   Nothing in the chat path writes `acknowledged_at`, and nothing in F8 should.

6. **Nothing is clinically signed off.** `biomarkers.v1.yaml` and
   `supplements.v1.yaml` are both unreviewed, so biological age is withheld,
   every lab value is `ungraded` and `find_deficiencies` returns nothing. The
   concierge therefore says "I can describe it but not grade it" a great deal.
   That is the product working. The fix is a signature, not code.

7. **`stranded_total` is still the number that says this is failing.** There is
   still no clinician console. The concierge is now deterministically forbidden
   from promising that one will look at something — `promises_human_action`,
   and `UNKEEPABLE_PROMISE_FALLBACK` — which makes the product honest, not
   working. A user who asks "can a doctor check this" is told we cannot promise
   that. Read that sentence and decide whether it is acceptable for another
   phase.

8. **Every test path still bypasses RLS.** SQL tests run as `postgres`, Python
   tests use fakes, scripts use the service key. F3 shipped with no INSERT
   policy on lab_uploads, F4 found the same hole in epigenetic_results, F5
   found a recursive policy on `clinic_members`, F6 found that a user with a
   signed recommendation could not delete their account, and F7's
   `chat_turns` test deletes an account rather than asserting `confdeltype`.
   If F8 adds a table, test the behaviour.

9. **Verify on the device, and give it the disk to run on.** Every phase so far
   has found a bug there that all the tests passed through; F7 found two. The
   emulator is `Pixel_8` and it refuses to start under about 3GB free —
   `flutter build apk --debug` writes 200MB per build and the machine filled up
   mid-verification. `adb` is at ~/Library/Android/sdk/platform-tools and is not
   on PATH; the package is `com.telomy.telomy`; there is no deep link, so
   navigate by tapping (chat is the "Sinc" tab, bottom nav, third). The signed
   in account is test-harness@example.com. `db/dev_clinical_demo.sql` seeds a
   signed trend, an SLA-released trend, a signed supplement recommendation and
   one deliberately stranded.

Also true, and worth not rediscovering: a model's behaviour varies between two
identical runs, which is the argument for a deterministic gate over a line in a
prompt — F7 asked the same question twice and got a misattributed signature
once; the quoting exemption is matched byte for byte and nothing is normalised,
so a model that reflows a quote gets refused rather than approximately
approved; the app's API base URL is the Railway gateway, so a local gateway
needs a rebuilt APK and a port Docker has not already taken (it holds 8000);
`rules_for`, `review_status` and `load_catalog` are all lru_cached and every
test that repoints a YAML path has to clear them; migrations are numbered only,
001–016 are applied, and the runner refuses an edit to an applied file.

Commands:

Backend tests: cd healthagent && PYTHONPATH=. .venv/bin/python -m pytest -q (1299 passing)
Mobile tests: cd mobile && flutter test (342 passing)
Mobile lint: cd mobile && flutter analyze
DB: set -a && . ./healthagent/.env && set +a then psql "$SUPABASE_DB_URL"
SQL tests: psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f healthagent/db/tests/<name>.sql (139 assertions, they roll back)
Migrate: cd healthagent && PYTHONPATH=. .venv/bin/python -m app.migrate.main --dry-run
Seed the clinician demo: psql "$SUPABASE_DB_URL" -f healthagent/db/dev_clinical_demo.sql
Ask the concierge through the real pipeline, one question per gate:
  PYTHONPATH=. .venv/bin/python scripts/ask_concierge.py --user-id <uuid> --suite --dry
A report through the live pipeline: PYTHONPATH=. .venv/bin/python scripts/upload_lab_report.py --phenoage --user-id <uuid> --cleanup

Working style: TDD throughout — write the failing test, watch it fail for the
right reason, then implement. Mutate the implementation to check a safety test
actually fails when the gate is removed. Small commits with messages that
explain why. Run both suites before each commit. Push to staging.

Inherited from F7, and the first thing to clear: **four paths exist only in
tests and have never been seen on a screen.** F7's device session ran out of
disk before they were reached, and all four are cheap now that the plumbing
works — the chat endpoint, the emulator and `scripts/ask_concierge.py` are all
proven. Do these before starting new work, because each one is a rendering
path, and a rendering bug is exactly what every phase's tests have passed
through: F4 shipped "Rdw" and "Hs crp" to a real screen with everything green.

  1. **The emergency card.** `screen_for_emergency` fires correctly through the
     real pipeline — verified, `route=emergency`, no model call — but the red
     `_Emergency` widget has only ever rendered in a widget test. Type "I think
     I'm having a heart attack" into the app and look at it.
  2. **The escalation line on a chat turn.** Thoroughly unit-tested, never
     exercised on a device, because the test account had no open row. Insert
     one into `lab_escalations` with `acknowledged_at` null, ask any question,
     and confirm the line is appended AND that nothing acknowledged the
     escalation afterwards.
  3. **The misattribution refusal.** The gate has never fired against a real
     model: the defect appeared in the first live run and the model stopped
     reproducing it after the fix. Reproduce it deliberately — ask the model to
     quote everything, with `dev_clinical_demo.sql` seeded so an `sla_expired`
     finding is present — or accept that it is unit and mutation tested only
     and say so.
  4. **The daily cap, the `unavailable` route and the wide layout.** Set
     `MAX_CHAT_TURNS_PER_DAY=1` and confirm the app shows the 429's message
     rather than a crash; unset the model key and confirm the honest fallback;
     open the app on a tablet-sized window and confirm the composer still
     clears the shell's floating button, which moves to the other corner there.

Blocked, and F7 could not close it either: **two files need a clinician's
signature.** `biomarkers.v1.yaml` (nine markers unblock biological age: albumin,
creatinine, glucose_fasting, hs_crp, lymphocyte_percent, mcv, rdw,
alkaline_phosphatase, wbc) and `supplements.v1.yaml` (four rules: vitamin D,
B12, iron, magnesium). Both are signed per entry and bound to a content hash.
The process is built and deliberately unused, because a signature needs a real
name, registration and date. F7 makes this more visible rather than less: the
concierge is now the surface where a user asks "is this normal" and is told,
honestly, that nobody has reviewed the ranges yet.

Known and deliberately not fixed: the clinician console still does not exist.

Deliberately left for later:
- **The app can time out while the server is still working.** Dio waits 90s;
  a turn may make up to `max_llm_calls` model calls plus tool calls, each
  bounded by `wall_clock_seconds` but not bounded in total. The server then
  finishes and records a turn the user never saw. The fix is a total deadline
  on the turn, server-side, below the client's timeout — not a longer timeout.
- **There is no way to clear a conversation without deleting the account.**
  `chat_turns` is append-only from every side on purpose, and erasure is by
  cascade. How long a medical conversation is kept is a product decision and
  guessing at it in a schema is how a retention policy gets set by accident.
- **No streaming.** The guardrails work on finished text and nothing can un-say
  a token already on a screen. Progress events are a legitimate thing to stream
  later; the reply is not.
- `insights.withdrawn_at` is still written by nobody. A clinician who signs
  something they regret still cannot take it back — and the concierge will
  quote it until they can.
- `trigger: below_optimal` is refused at load time on purpose.
- Pregnancy is detected by screening free text, which both misses and
  over-refuses. The correct fix is a structured field on the profile.
- Cross-source wearable dedupe, and a real empty state for a user with no
  wearable at all.
