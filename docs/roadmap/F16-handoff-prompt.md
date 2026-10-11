Read first, in this order:

docs/roadmap/2026-10-11-demo-parity-programme.md — §5 (F16) and the honesty note
in §1.
docs/roadmap/F8-handoff-prompt.md — F16 is F8's second half and inherits its
argument. Bite 3 in that prompt ("correlation is the easiest place in this
product to say something false") and bite 2 (a genetic variant may never
originate an insight) are requirements here, not history.
healthagent/app/analytics/correlations.py — F8's inference layer, and the one
F16 extends: `correlate`, the declared hypotheses, the FDR step-up, the
sample-size floor, the Bartlett/Quenouille effective-n adjustment, and the rule
that an explanation renders only if somebody signed it. Read
`app/analytics/event_analysis.py` beside it.
The prototype's docs/ENGINE.md §"Correlation engine" — the receipts contract:
adjusted versus unadjusted effect, 95 % CI, p, n, covariates.

What F16 is: the engine's depth, and the surface that makes it inspectable.
N-of-1 ABAB studies a member can start and that are allowed to conclude
"no difference"; the cross-modality rule set (the prototype has 34 — ApoB
against a calcium score, MASLD triple-concordance, masked hypertension, OSA and
non-dipping, CGM against HbA1c, the G6PD gate); lab × wearable windows; and
receipts on every insight.

Already built (F0–F15), reuse it:

app/analytics/correlations.py — FDR control, the effective-n adjustment and the
  declared-hypothesis gate. F16 adds rules and a surface on top; if it adds a
  second significance implementation, it is wrong. Note that the autocorrelation
  adjustment is already there: an N-of-1 study over consecutive nights has the
  same problem and must use it
app/analytics/insight_rules.py — the existing deterministic rules and their
  shape. Cross-modality rules are more of these, not a new mechanism
app/analytics/statistics.py — whatever F8 put there. A Welch t-test for an ABAB
  study belongs beside it
app/clinical/drafts.py — a rule that reads as medical advice goes through the
  clinician spine. Several of the 34 do
app/agent/numbers.py — a receipt is the user-facing version of `check_numbers`.
  The same discipline, rendered

Eight things that will bite you:

1. **"No difference" is a result and the UI must say so first.** An N-of-1 study
   that only reports wins is a device for generating false beliefs about one's
   own body. Three honest verdicts, and the null one is not styled as a failure.

2. **A member-designed study is underpowered by construction.** Two weeks of
   magnesium, n of 14 nights, one person. Report the effect with its interval,
   state the detectable effect size at that n, and refuse to conclude when the
   study cannot answer. The prototype runs ABAB with 7-day periods, which is the
   right minimum shape — A-then-B is not a study.

3. **The washout is the part people get wrong.** An ABAB with no washout
   attributes the carry-over to the next period. Decide the washout per
   intervention class and encode it; a supplement with a long half-life cannot be
   studied in 7-day blocks at all, and the honest answer is to say so rather than
   to run it.

4. **Thirty-four rules is thirty-four chances to say something false.** Each one
   needs: the mechanism in a docstring, the citation, the conditions under which
   it fires, and a test with a fixture that fires it and a fixture that nearly
   does. A rule nobody can explain gets deleted, not shipped.

5. **A variant may never originate an insight.** F8's rule, and F16 is where it
   will be tempting to break it, because a genotype makes a beautiful rule input.
   A variant appears only as context beside a measured marker. The question to
   answer before writing the rule is still the one F8's prompt asked: what does
   the concierge say when somebody asks "do I have the Alzheimer's gene".

6. **Receipts are the product, not a debug view.** Adjusted and unadjusted side
   by side, the CI, the p, the n, the covariates, and the citation. This is the
   roadmap's F06 (open methods) finally having something worth opening, and it is
   what makes a correlation defensible to a clinician who disagrees with it.

7. **Lab × wearable windows meet censored values.** F14 excludes them from
   correlations for a reason; this phase is where that exclusion gets tested
   again, because a `<0.01` silently coerced to 0.01 is a data point that will
   drag a slope.

8. **Multiplicity compounds across phases.** F8 controlled FDR over event
   effects. F16 adds studies, 34 rules and lab × wearable windows, each testing
   more hypotheses against the same person. Decide where the family of tests is
   drawn and document it, because "corrected within each feature" is not
   corrected.

Verification:

- An ABAB fixture with a real effect, one with none, one too short to conclude.
  Three verdicts, three screens.
- Carry-over: a fixture where ignoring washout produces a significant result and
  honouring it does not.
- Per rule: a firing fixture, a near-miss fixture, and the citation present.
- A variant-only input produces no insight, by test.
- A censored value excluded from every slope.
- A receipt rendered for every insight type the app can show, asserted by a test
  that enumerates the types rather than a sample.

Commands: as in F9-handoff-prompt.md.

Working style: TDD throughout, small commits that say why, both suites green,
push to staging, verify on `Pixel_8`.

Deliberately left for later:
- Aggregate research across members (needs F19's research consent), preprint
  reading, Telomy Labs.
- Any rule requiring a measurement the Vault does not hold.
