Read first, in this order:

docs/roadmap/2026-10-11-demo-parity-programme.md — §5 (F18) and decision 7
(payments are out, so ordering stops at a signed prescription).
healthagent/app/analytics/supplement_rules.py and data/supplements.v1.yaml —
F6's reviewed medical content, signed per rule and bound to a content hash. F18
is its full surface and must keep that mechanism, not grow a second one.
healthagent/app/clinical/supplement_drafts.py — a recommendation a clinician must
sign and cannot not sign.
healthagent/app/agent/guardrails.py — the medication patterns, deliberately
broad. F18 is the phase most likely to need them widened and most likely to be
wrong about it.

What F18 is: Telomy Rx. Four product classes — Telomy Formulas, individual
supplements, prescription medicines and clinic IVs — with interaction checking,
a member-visible exclusion list, a plan that goes to a doctor and comes back
signed with items removed and doses edited, an e-prescription, and adherence
tracking. F6 built the supplement half for one trigger class; F18 is the rest.

Already built (F0–F17), reuse it:

app/analytics/supplement_rules.py — `rules_for`, `review_status`,
  `rule_fingerprint`, all lru_cached (clear them in any test that repoints a
  YAML path). `trigger: below_optimal` is refused at load time **on purpose**
app/clinical/supplement_drafts.py + drafts.py — the draft, the flags from the
  guardrail rather than the producer, and the refusal of a draft the guardrail
  would not flag
F10's work queue, Rx segment — item removal, dose editing, then sign. The order
  of operations is already specified there (bite 4 of F10) and F18 must match it
app/common/context_loader.py — `safety_facts`: medications, conditions,
  allergies, fetched deterministically. Never a similarity search, because a
  vector store must not decide whether to mention a penicillin allergy
F15's equations — a medication changes what a risk number means, and now the app
  prescribes them

Ten things that will bite you:

1. **A major interaction blocks the item and says why.** Not a warning, not a
   footnote. The block is deterministic, it names the other agent and the
   mechanism, and the test asserts the item cannot be ordered by any path.

2. **The interaction source is a licensing question, not a data question.** The
   prototype uses DDInter plus curated monograph rules. A licensed source is on
   the approved plan's own v0.6 list. Until one exists, the rule set is small,
   curated, cited per pair, and the app states that it checks a limited set
   rather than implying completeness — an interaction checker that looks
   exhaustive and is not is worse than none.

3. **"Not offered, and why" is a member-facing screen.** The prototype lists
   melatonin as prescription-only here, NMN as not FSSAI-listed, under-dosed
   stacks and high-dose antioxidants. This is the most trust-building screen in
   the whole programme: it is the product declining to sell something. Build it
   properly and keep the reasons specific.

4. **Prescription medicines are dispensed only against a signed prescription, by
   a licensed pharmacy.** IVs only at a centre, which means F11's booking path.
   Nothing in this phase ships a drug; it ships a document a pharmacy can act on.

5. **The e-prescription is a legal artefact.** It carries the clinician's name,
   registration, date and signature state, and it is generated from the signed
   body — the same hash discipline as every other delivery (`gate_delivery`). A
   prescription PDF that can be regenerated with different contents than what
   was signed is the worst bug available in this phase.

6. **Supplements are not food, and dose units are not interchangeable.** IU
   versus µg for vitamin D, elemental versus salt weight for magnesium and iron.
   F6 already fixed one version of this defect in the guardrails ("a
   concentration is not a dose", commit `d38747b`). Canonical units, one
   conversion function, and a test per nutrient where the two differ.

7. **Adherence creates a new obligation.** Once the app knows a member stopped
   taking something a clinician prescribed, somebody has to decide what happens.
   Recommendation: it informs interpretation (a lipid panel on a statin nobody
   took is not a statin failure) and it never nags. It must not silently become a
   compliance score shown to a doctor without the member knowing.

8. **The guardrail patterns will fire on your own feature.** Legitimate Rx
   content is exactly what the autonomous profile exists to block. The answer is
   the `clinician_queue` profile and the signed-quoting path F7 built — not a
   loosened pattern. Every change to a pattern belongs in
   `tests/test_guardrails.py` with a sentence saying which direction of error it
   chose and why, because both directions are costly: a false positive makes the
   feature mute, a false negative puts unreviewed prescribing on a screen.

9. **The exclusion list and the catalogue both need a signatory.** Same
   unanswered question since F6, now with more content behind it. Unsigned
   entries stay invisible rather than ungraded-but-visible, because an
   unreviewed supplement recommendation is advice.

10. **Verify on the device.** Dose fields, interaction warnings and a signature
    state on a phone screen — and the member's view of a plan that is partly
    approved, which is the state nobody designs for.

Verification:

- A major interaction blocks; a moderate one warns; both cite the pair.
- Order attempted on an unsigned plan: refused server-side.
- The e-prescription regenerated: byte-identical to the signed body, and a
  mutation of the plan after signing fails the hash check.
- IU ↔ µg and elemental ↔ salt conversions, per nutrient, with a case where
  getting it wrong is a tenfold dose error.
- An item removed by the doctor is absent from the prescription and from the
  order path.
- Adherence recorded, then a lipid panel interpreted with and without it.
- The exclusion screen renders a reason for every excluded product, by
  enumeration.

Commands: as in F9-handoff-prompt.md. Fingerprint a rule with
PYTHONPATH=. .venv/bin/python -c "from app.analytics.supplement_rules import rule_fingerprint as f; print(f('vitamin_d_repletion'))"

Working style: TDD throughout. Mutate the signature check and watch an order
succeed on an unsigned plan, then put it back. Small commits that say why. Both
suites green. Push to staging. Verify on `Pixel_8`.

Deliberately left for later:
- Payments, pharmacy fulfilment APIs, inventory, delivery tracking (decision 7).
- `trigger: below_optimal` — recommending for a value inside the reference range
  is optimisation on a weaker evidence base and remains a clinical decision, not
  a config change.
- Compounded or clinic-prepared formulations beyond the catalogue.
