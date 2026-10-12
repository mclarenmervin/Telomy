Read first, in this order:

docs/roadmap/2026-10-11-demo-parity-programme.md — §2, §5 (F10) and decision 1.
The decision has to have been answered before this phase starts; if nobody has
answered it, stop and ask.
healthagent/CLAUDE.md — the Five Principles and Non-Negotiable Rules are binding.
healthagent/app/clinical/ — drafts, supplement_drafts, queue_plan, sweep. Read
all four. F5 and F6 built a complete clinician spine and it has never had an
interface; F10 is that interface and should add no new clinical machinery.
healthagent/app/agent/guardrails.py — `gate_delivery`, `body_sha256`, the three
profiles. This is what makes a signature mean something, and F10 must not route
around it.

What F10 is: the doctor's screen. A work queue in five segments — monthly
reports, Sinc drafts, consults, therapy plans, Rx plans — a patient panel
ordered by a deterministic priority, a patient detail view, clinician notes, the
report summary and the patient summary, and monthly report generate → sign.
Therapy plans and Rx plans are empty until F12 and F18; build their segments
anyway, because the empty state is the contract those phases fill.

Already built (F0–F9), reuse it:

app/clinical/drafts.py + supplement_drafts.py — a draft is produced with the
  guardrail's flags, never the producer's. A draft the guardrail would not flag
  is refused rather than written. Widen that and the SLA path eats the gate
app/clinical/sweep.py — `sweep_queue`, the SLA release, `stranded` and
  `stranded_total`. The queue already knows how to expire; F10 is what finally
  claims
db/013_clinical_review.sql — `clinical_drafts` has **no user-facing RLS select
  policy at all**, which is the enforcement that a user cannot read an
  unreviewed draft. The doctor's read path is a new policy for a new role, not
  a loosening of that one
db/dev_clinical_demo.sql — seeds a signed trend, an SLA-released trend, a signed
  supplement recommendation and one deliberately stranded. It stands in for the
  console that does not exist; after F10 it stands in for nothing
app/analytics/ — readiness, biological age, trends, marker_trends, severity.
  Deterministic, already exposed as both an endpoint and a tool. The patient
  summary is a fourth caller, not a fourth implementation
app/agent/numbers.py — `check_numbers`, `collect_tool_numbers`. A figure in
  prose traces to a value a tool returned. The summaries in this phase are prose
  full of figures

Nine things that will bite you:

1. **The summaries are composed, not generated.** The prototype's
   `summaries.py` is a deterministic composer: it assembles sentences from
   values it already has. That is P2, and it is also the only way
   `check_numbers` can pass. If an LLM writes the patient summary, every number
   in it needs a tool receipt, and the honest version of that is the composer.

2. **Nothing is signable without a note.** The prototype disables every sign
   button until a free-text note is non-empty, on all five segments. Copy it,
   and enforce it server-side too — a disabled button is a courtesy, not a rule.

3. **The signature binds to the body, and the body cannot change afterwards.**
   `review.signed_body_sha256 == sha256(delivery_body)` already makes a
   post-signature edit structurally undeliverable. The doctor's note is part of
   what is delivered, so decide — and test — whether the note is inside the
   hashed body. Recommendation: yes, because a note that can be edited after
   signing is a signature on words nobody read, which is the exact defect commit
   `cd6bc9e` fixed in the concierge.

4. **A doctor may edit an item and a dose before signing, and that is not an
   edit to a signed thing.** The prototype's Rx segment lets the doctor drop
   items and overwrite doses, then signs what is left. The order matters: the
   decision payload carries `keep` and `doses`, the server recomputes the body,
   *then* hashes. Build it in that order or bite 3 fires on your own feature.

5. **Priority is a rule, not a model.** The prototype's `_priority` is
   deterministic and that is the correct choice: a queue ordered by an LLM is a
   queue no clinician can predict or audit. Rank on what is already computed —
   escalations open, severity, staleness, SLA remaining — and put the reason on
   the row, because a doctor who cannot see why someone is at the top will sort
   by name instead.

6. **A critical value does not enter this queue.** `lab_escalations` fires
   independently and `ESCALATION_LINE` bypasses the guardrail rewrite. The
   queue is for recommendations; an emergency that waits for a work queue is the
   worst failure this product can have. Test that an escalation is visible to
   the doctor *and* that it did not wait for them.

7. **The agent still gets no path to `clinical_drafts`.** The *absence* of a
   loader method is load-bearing (F7's prompt says so explicitly). Putting the
   doctor's UI in the same app does not change it: the doctor's reads go through
   a new, role-scoped loader called from the gateway, and no tool the concierge
   can reach gains access. If a `get_clinical_drafts` tool appears in this
   phase, the phase is wrong.

8. **A doctor sees only patients who share with them.** `treating_clinic_id`
   exists in the loader; it is a clinic, not a licence to browse. The panel is
   derived from a consent or membership row, the test runs as a second doctor
   and asserts zero rows, and "search all patients" is not a feature.

9. **Verify on the device.** Every phase so far has found a bug there that all
   the tests passed through — most recently a composer that sat under the
   shell's floating button. A five-segment queue with free-text notes on a
   phone keyboard is exactly the shape that breaks there.

Also true, and worth not rediscovering: a signed insight still cannot be
withdrawn (`insights.withdrawn_at` is written by nobody, and the column, the
loader filter and the repository's `isFilter` are all already there — F10 is the
phase with a human who would want it); `convert_to` is STABLE so a sha256 of
text cannot be a generated column; `rules_for`, `review_status` and
`load_catalog` are lru_cached and every test that repoints a YAML path must
clear them.

Verification:

- Drive `stranded_total` to zero through the UI, from a seeded stranded draft.
- Sign, then attempt a one-character edit; assert undeliverable.
- Sign an Rx with an item removed and a dose changed; assert the delivered body
  is what was signed, not what was proposed.
- Run the panel as a second doctor: zero rows.
- An escalation reaches the doctor and did not wait for them.
- Monthly report: generate, sign, assert the member sees it with the trail —
  `noticed_by`, `reviewed_by`, `reviewed_at`, evidence.

Commands: as in F9-handoff-prompt.md. Seed the clinician demo with
psql "$SUPABASE_DB_URL" -f healthagent/db/dev_clinical_demo.sql.

Working style: TDD throughout. Mutate the gate and watch a safety test fail.
Small commits that say why. Both suites green before each commit. Push to
staging. Verify on `Pixel_8`.

Blocked: the clinical content still needs a signatory (F6's open question, now
F9's admin surface can collect it). An empty queue in a demo is this phase
working, not failing, but say so out loud before anyone demonstrates it.

Deliberately left for later:
- Therapy plan and Rx plan segments render their empty states; F12 and F18 fill
  them.
- The dispute path for a signed insight the member disagrees with. Still only a
  dismiss button, still wrong, still not this phase.
- Multi-doctor handover and claim transfer. The SLA sweep covers the lapse case;
  deliberate handover is a workflow nobody has asked for yet.
