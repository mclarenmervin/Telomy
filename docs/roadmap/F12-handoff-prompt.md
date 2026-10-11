Read first, in this order:

docs/roadmap/2026-10-11-demo-parity-programme.md — §5 (F12) and the honesty note
in §1. This phase is where that note stops being a caveat and becomes a screen.
healthagent/CLAUDE.md — the Five Principles. P2 decides where every number in
this phase is computed.
healthagent/app/analytics/correlations.py — F8's inference layer: the
sample-size floor, Benjamini–Hochberg, the Bartlett/Quenouille adjustment for
autocorrelation, and the rule that a pair is tested only if somebody declared
the hypothesis. A therapy verdict is an event effect with a name, so it goes
through this file. Read `app/analytics/event_analysis.py` beside it.

What F12 is: therapy as a first-class object instead of a journal entry. The
catalogue (~25 modalities: cryo, HBOT and mild HBOT, sauna, IR sauna, cold
plunge, contrast, red light, PEMF, H₂ inhalation, IHHT, EWOT, compression,
vibroacoustic, float, IV and the rest) with what each one does, who it is not
for, and what it costs; the deterministic safety screen read from the Vault; the
session as a record with a start, a finish and a subjective check-in; the
verdict vocabulary; and the plan builder that ends at F10's signature. What
happens *inside* a session — telemetry, physiology, in-session safety tiers — is
F13. F12 is the spine; F13 puts sensors on it.

Already built (F0–F11), reuse it:

app/analytics/correlations.py — F8's significance and plausibility layer:
  `correlate`, the declared-hypothesis table, the FDR step-up, the effective-n
  clamp. A therapy verdict uses them; it does not reimplement them. A modality
  becomes a declared hypothesis, not a free pair
app/analytics/event_analysis.py — before/during/after deltas around an event.
  A session is an event with a modality and a dose
app/clinical/ + F10's work queue — the plan's signature path. A therapy plan is
  a draft that a clinician signs, and the therapy-plan segment of the queue is
  already built and empty, waiting for this phase
app/analytics/safety.py — the deterministic safety layer. Contraindication
  screening belongs here, beside it, as rules, never as model output
app/common/context_loader.py — `safety_facts` already fetches medications,
  conditions and allergies deterministically. That is the input to the screen
events — P1. A therapy session writes the same row shape a button press does

Nine things that will bite you:

1. **The verdict vocabulary is the feature.** *Helped* (FDR-significant **and**
   split-half replicated), *Promising* (p < 0.01, CI excludes zero, replicated,
   not yet past FDR), *Possible negative*, *No reliable signal*, *Too early*
   (< 5 sessions), *In-session only* (no wearable). Six answers, four of which
   are "we do not know yet". Build all six before building one, or the first one
   becomes the only one and every therapy will read as working.

2. **"No reliable signal" must be the best screen in the phase.** The honesty
   note in the programme doc says why: the effects the prototype finds were
   planted in its seed, and real wearable variance is ten times wider. The
   likeliest truth for most members and most modalities is that we cannot tell
   yet. If that renders as an empty state, the therapy tab reads as broken, the
   business reads it as a bug, and someone will ask for the threshold to be
   loosened. The prototype gives it its own section with its own heading; do
   better than that.

3. **A verdict downgrades, and the test proves it.** Remove replication from a
   fixture that earned *Helped* and assert it becomes *Promising*. Remove
   significance and assert *No reliable signal*. A verdict that only ever moves
   up is a marketing claim.

4. **The safety screen is a hard refusal, not a warning.** Pregnancy, pacemaker,
   uncontrolled BP, recent cardiac event, Raynaud's, untreated pneumothorax for
   HBOT, DVT for compression, photosensitising drugs for PBM, G6PD for IV
   vitamin C, alcohol today for sauna, coronary plaque for cryo. A
   contraindicated therapy cannot be started and cannot be booked, by any path —
   including a plan a doctor signed, because the screen may change after the
   signature. Test the booking path and the start path separately.

5. **Pregnancy is still detected by screening free text**, which both misses and
   over-refuses (F7's parting note). F12 raises the cost of that: it now gates
   therapies, not only supplements. The correct fix is a structured profile
   field, it improves biological age and Rx at the same time, and this is the
   phase where it stops being optional. Do it here.

6. **Dose is prescribed and delivered, and they differ.** A plan says three
   cryo sessions a week at 3 minutes; what happened was two at 2 minutes 40. The
   data model carries both from the start, because retrofitting delivered dose
   after F13 starts streaming telemetry means rewriting the session table under
   live data.

7. **The subjective check-in is data, and it is the only data for some
   modalities.** *In-session only* exists because a member without a wearable
   still deserves an answer. One or two questions, immediately after, stored
   with the session. Do not let it become a form.

8. **Price is indicative (decision 7).** The catalogue carries a price because
   the prototype's does and because a centre needs one, and every rendering of
   it says indicative until payments exist.

9. **Verify on the device.** A catalogue, a safety refusal and a plan builder
   are three of the most interactive screens in the product, and the refusal is
   the one that must be impossible to tap past.

Verification:

- Each of the six verdicts from a fixture, including the two downgrades in
  bite 3.
- A contraindicated therapy refused at start and at booking, and refused again
  when the contraindication appears *after* a plan was signed.
- A plan with one safe and one unsafe item: the unsafe one is left out with its
  reason visible to the member ("left out for safety" is a section in the
  prototype; keep it).
- Delivered versus prescribed dose on a session where they differ.
- A member with no wearable gets *in-session only*, not an error.

Commands: as in F9-handoff-prompt.md.

Working style: TDD throughout. For the safety rules specifically: write the
refusal test, remove the rule, watch a real person become eligible for HBOT with
an untreated pneumothorax, then put it back. Small commits that say why. Both
suites green. Push to staging. Verify on `Pixel_8`.

Deliberately left for later:
- In-session physiology, telemetry, live floor, in-session safety tiers: F13.
- HSAI: specified in F13, not shipped (decision 6).
- Response phenotypes and the per-service outcome evidence F11 is waiting for:
  both need session volume. Say what they need.
