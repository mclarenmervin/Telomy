Read first, in this order:

docs/roadmap/2026-10-11-demo-parity-programme.md — §5 (F15).
healthagent/CLAUDE.md — P2. Every number in this phase is arithmetic, and none
of it is the model's.
healthagent/app/analytics/biological_age.py — how a published model was ported
once already: minimum marker count, per-marker contribution cap, bounded output,
and the stability test that perturbs one marker by 5 % and asserts the age moves
less than a year. F15 repeats that discipline five times.
The prototype's docs/ENGINE.md §"Risk prediction" and §"Digital twin" — the
model list with its sources, including which R package the PREVENT coefficients
came from.

What F15 is: two things that look alike and are not. First, **validated risk
equations** — PREVENT 2024, the Pooled Cohort Equations, the ADA score, FIB-4,
KFRE — each reproducing its published worked example, each with a what-if.
Second, the **digital twin**: 21 state variables relaxing toward
lifestyle-dependent steady states, a 24-hour twin for caffeine, nicotine and
alcohol, and a mirror that scores its own fidelity. The first is published
science applied to one person. The second is a projection we built. They must
not be presented as the same kind of thing.

Already built (F0–F14), reuse it:

app/analytics/biological_age.py — the port template: bounds, caps, minimum
  inputs, refusal, stability test
app/analytics/reference_ranges.py + units.py — unit normalisation before any
  equation sees a value. mg/dL versus mmol/L in a risk equation is a silently
  wrong answer, not an error
app/analytics/score_snapshot.py + db/006_score_snapshots.sql — every computed
  artefact stamps its inputs and versions and is reproducible from them. A risk
  score is a score
app/common/context_loader.py — `safety_facts` for medications, which change what
  an equation means (bite 4)
F14's catalogue — the markers these equations need, and the refusal path when
  one is missing

Eight things that will bite you:

1. **Each equation reproduces its published example, as a test, to the paper's
   own precision.** Not approximately. The prototype claims PREVENT "matches the
   published example exactly" and that is the correct bar; it is also the only
   defence against a transcription error in a coefficient table, which is
   invisible, permanent and affects every user.

2. **A missing input is a refusal, not a default.** Sex unknown → no result, as
   the existing calculators already do correctly ("Sex required"). Age outside
   the model's validated band → no result. The equations have validity ranges and
   using one outside its range produces a confident number that means nothing.

3. **The South-Asian caveat is shown, not stored in a comment.** PCE is known to
   under-estimate risk for South Asian people and that is most of our users. The
   prototype renders the caveat on screen beside the number. So do we, and the
   test asserts the caveat travels with the value through the API.

4. **Medications change the interpretation and the equations do not know.** A
   statin explains low LDL; a beta-blocker explains a low heart rate; an
   antihypertensive is an input to PREVENT and a confounder everywhere else. The
   approved plan flags this as making the platform "confidently wrong rather than
   merely incomplete". `safety_facts` already has the data.

5. **The twin is a projection and says so on every screen.** It is a decision
   aid under the claims firewall, not a measurement and not a prognosis. Its
   mirror score — how well it has predicted this person so far — belongs on the
   same screen as its output, not behind a tap. A twin whose fidelity is poor and
   unlabelled is worse than no twin.

6. **A what-if is not a promise.** "Lose 5 kg and your risk falls to X" is a
   counterfactual from an observational model. Phrase it as the model's
   expectation, show the uncertainty, and never render it as a plan — a plan
   needs F10's signature.

7. **The twin's calibration comes from the person's own history, which most
   people do not have yet.** Uncalibrated, it is a population average with a
   personal label, which is the most misleading possible state. Decide the
   minimum history before a twin is shown at all, and show nothing before it.

8. **Recompute storms.** A coefficient fix or a range version change recomputes
   every user's risk. Queued and rate-limited, never inline — the same rule the
   approved plan set for ranges.

Verification:

- The published worked example for each of the five models, as five tests.
- Refusals: missing sex, missing marker, age outside band, pregnancy.
- Unit conversion round-trips, including mg/dL ↔ mmol/L on a value that changes
  the risk category.
- The caveat survives the API boundary.
- Twin: minimum-history refusal; mirror score rendered with the output; a
  perturbation test on the 24-hour twin so a cup of coffee cannot move a 10-year
  projection.
- Reproducibility: recompute a stored snapshot from its own inputs and versions,
  byte-identical.

Commands: as in F9-handoff-prompt.md.

Working style: TDD throughout — for this phase, the published example *is* the
failing test and it comes first. Small commits that say why. Both suites green.
Push to staging. Verify on `Pixel_8`.

Deliberately left for later:
- SCORE2 and FRAX (in the prototype's own roadmap, not its code), PREVENT's
  UACR and HbA1c add-ons.
- Any twin variable that would need a measurement we do not collect. Twenty-one
  is the prototype's count, not a target.
