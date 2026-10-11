Read first, in this order:

docs/roadmap/2026-10-11-demo-parity-programme.md — §5 (F14).
~/.claude/plans/i-got-new-request-dynamic-emerson.md — the "Edge cases that will
bite" section. F14 is the phase those paragraphs were written for; censored
values, dates, historical backfill and files are all its scope.
healthagent/app/analytics/data/biomarkers.v1.yaml and
app/analytics/reference_ranges.py — the catalogue and the resolver. F14 widens
the catalogue and must not fork the resolver.
app/extraction_worker/ — the ingest path F3 built. F14 feeds it more shapes.

What F14 is: the Vault at full width. More report types and more coded markers
with sex-specific zones; the imaging record (metadata, the radiologist's report,
the file — not a DICOM viewer); the tests-and-scans catalogue with why, how
often, how to prepare and an indicative Indian price; a personalised "what to
test next" from the gaps in the person's own Vault; and Vault completeness as a
number with a concrete list of what raises it.

Already built (F0–F13), reuse it:

app/analytics/reference_ranges.py — resolution order `user` → `clinic` →
  `global`, in exactly one function, with every artefact stamping
  `ranges_version`. A new panel is new data in the same resolver
app/extraction_worker/ — PDF → values, where the LLM maps label → biomarker_id
  and unit → canonical unit and **never produces the value**. The verbatim check
  is what makes that enforceable
db/007_lab_ingest.sql + 011_lab_upload_insert_policies.sql — the upload path and
  the policy hole F3 shipped without. Read both before adding a bucket
app/analytics/biomarker_selection.py + marker_trends.py + severity.py — what a
  marker means and how it trends. Completeness is computed from the same
  catalogue these use, or the number will disagree with the screens
app/common/context_loader.py — `documents()` and `biomarker_results()`

Nine things that will bite you:

1. **Censored values are routine, not an edge case.** `<0.01`, `>500`. An
   `operator` column (`=`, `<`, `>`) beside the value; displayable, can trigger
   escalation, **excluded from biological age and from correlations** because
   the true value is unknown. A `float()` parse will meet one on the first real
   panel.

2. **Qualitative results are not numbers.** `Positive`, `Trace`, `Not detected`.
   A `value_text` column and a `result_type` discriminator. Never coerce.

3. **The same marker appears twice in one report** — fasting and post-prandial
   glucose. Keyed by `(biomarker_id, collected_at, context)`, not by marker.

4. **Collection date is the only date that may drive a trend.** Report date and
   upload date are not it, PDFs show all three, and most label none clearly. If
   collection date cannot be extracted with confidence, the confirmation UI
   **asks**. Guessing puts a 2023 panel on today's chart, and nobody will catch
   it for months.

5. **A five-year backfill in one sitting must fire nothing.** No retroactive
   alerts, no clinician drafts, no recompute storm. Documents older than N days
   are ingested as history: they populate trends and generate nothing. Decide N
   in this phase and write it down.

6. **Thirty markers with real citations beat a hundred with plausible numbers.**
   The approved plan's rule, and F14 is where the pressure to widen fast is
   highest, because a report type the app cannot parse looks like a missing
   feature. `citation` is NOT NULL and the load-time ordering assertion
   (`critical_low < standard_low ≤ optimal_low < optimal_high ≤ standard_high <
   critical_high`) holds per row. A widened catalogue that nobody has signed is
   not a widened catalogue — it is unreviewed medical content with a schema.

7. **Imaging is a record, not a viewer.** Metadata, the report text, the file in
   a private bucket, and a marker-like row only where the report states a coded
   value (a calcium score, an ejection fraction). DICOM stays deferred and the
   Free-tier storage quota is a second reason.

8. **Completeness is a promise about what to do next.** A bare percentage is
   decoration. The prototype pairs it with the specific next test and what it
   would unlock; without that it is the "coverage" text the audit already
   flagged, in a larger font.

9. **The tests catalogue makes clinical recommendations.** USPSTF, ADA, ESC/EAS,
   KDIGO triggers in the prototype. Ours are deterministic rules over the Vault,
   they say which guideline they came from, and anything that reads as "you
   should get this test" goes through F10's signature or is phrased as a gap in
   the data rather than as advice.

Verification:

- A censored value: stored, displayed, escalation-capable, absent from
  biological age and from every correlation. Assert the exclusion, not the parse.
- A qualitative value never coerced to a number.
- Same marker twice, both kept, both distinguishable.
- A PDF whose collection date is ambiguous: the UI asks.
- A five-year backfill: zero alerts, zero drafts, and a bounded number of
  recompute jobs.
- Password-protected and text-layer-less PDFs: a password prompt and an OCR path
  that **forces** confirmation.
- Duplicate upload by content hash: refused.
- Completeness recomputed from the same catalogue a score uses; assert they
  cannot disagree.

Commands: as in F9-handoff-prompt.md. A report through the live pipeline:
PYTHONPATH=. .venv/bin/python scripts/upload_lab_report.py --user-id <uuid> --cleanup

Working style: TDD throughout, small commits that say why, both suites green
before each commit, push to staging, verify on `Pixel_8`.

Blocked: a widened catalogue needs a clinician's signature per marker (F9's
admin surface collects it). Ship the parser and the schema; leave unsigned
markers `ungraded` and invisible to scores, exactly as F6 left the first nine.

Deliberately left for later:
- DICOM viewing. Unchanged.
- Partner lab APIs and direct test booking. The catalogue is informational until
  payments exist (decision 7).
