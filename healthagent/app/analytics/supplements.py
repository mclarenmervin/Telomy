"""Which measured deficiencies justify a supplement recommendation.

The deterministic half of F6, and the same split F5 used for trends:
`marker_trends` decides whether a human should look at a trajectory, this
decides whether a human should be asked about a deficiency, and the wording
lives in `clinical/supplement_drafts.py`. Per CLAUDE.md the decision is a
testable rule in ordinary Python -- no LLM is anywhere near it, and the one
sentence this module carries is the reviewed one from `supplements.v1.yaml`
rather than a sentence it wrote.

### Why the grade, rather than a second comparison

The trigger is `grade_for_display(value) == abnormal` together with the value
being below the standard range, and the first half is doing more work than it
looks like.

`grade_for_display` is the one place that asks whether a clinician has signed
off the range we are about to grade against; it answers `ungraded` while
`biomarkers.v1.yaml` is unreviewed, for a sex-specific marker whose subject's
sex we do not hold, and for a marker the catalog does not know. Comparing
against `resolved.standard.low` here instead would have been a second copy of
that gate, and the copy that forgets the review check is the one that puts an
unreviewed recommendation in front of a clinician's signature.

It also gives the critical exclusion for free. A critical value grades
`critical`, not `abnormal`, so it cannot produce a finding -- which is the rule
`drafts.draft_for_trend` applies by hand and for the same reason: a potassium
of 7 does not get a supplement suggestion, it gets the escalation that has
already fired, and a review queue must never stand in front of that.

### What this module will not do

Decide anything from a rule nobody signed. Both signatures are required -- the
rule, because what to do about a deficiency is a clinical claim; and the
marker, because the draft states the reference range the value fell below and
that is a separate claim by a separate signature. With the shipped files, which
are both unsigned, this function returns nothing at all. That is the phase
working as specified rather than a phase that does not work.
"""

from dataclasses import dataclass
from datetime import date, timedelta
from typing import Callable

from app.analytics.biomarker_selection import SelectedValue, usable_values
from app.analytics.catalog import Range
from app.analytics.reference_ranges import (
    ABNORMAL,
    ResolvedRange,
    grade_for_display,
)
from app.analytics.supplement_rules import Interaction, SupplementRule, rules_for
from app.analytics.supplement_rules import review_status as rule_review_status
from app.extraction.ingest import HISTORY_DAYS

MODEL_VERSION = "supplement-rule-v1"

#: The only context a deficiency is read from. The contexts that exist are
#: `standard`, `fasting` and `post_prandial`, and the last two belong to glucose
#: -- no rule here is about a marker that has them. A context this does not
#: recognise is skipped rather than ranked last, exactly as
#: `biomarker_selection` refuses a post-prandial glucose for a fasting model: a
#: differently-collected sample is a different measurement, not a worse one.
_ACCEPTED_CONTEXT = "standard"


@dataclass(frozen=True)
class MatchedInteraction:
    """An interaction the user's own medications triggered.

    `recorded_as` is what the person typed, carried through so the draft can
    quote it rather than the match term: a clinician reading "metformin" learns
    less than one reading "Tab. Metformin 500mg, twice daily".
    """

    medication: str
    recorded_as: str
    note: str


@dataclass(frozen=True)
class SupplementFinding:
    """One deficiency, the rule about it, and what complicates it.

    `value` and `standard` are carried in full because they become the draft's
    evidence, and a clinician asked to put their registration number against a
    recommendation needs the number, the date and the range it fell below
    without the console querying anything else.
    """

    rule: SupplementRule
    value: SelectedValue
    standard: Range
    ranges_version: str
    interactions: tuple[MatchedInteraction, ...] = ()
    model_version: str = MODEL_VERSION

    @property
    def biomarker_id(self) -> str:
        return self.value.biomarker_id

    @property
    def as_of(self) -> date:
        """The draw this is about, never today.

        Same reasoning as `MarkerTrend.as_of` and `score_snapshots`: a finding
        is a statement about a blood sample, and dating it to the day the sweep
        ran would re-draft it every night.
        """
        return self.value.collected_at


def _medication_text(row: dict) -> str:
    """Everything a person might have put the drug name in.

    `medications` rows are free text: the title is usually the drug but is
    sometimes the condition, with the drug in the notes.
    """
    parts = [row.get("title"), row.get("notes")]
    fields = row.get("fields")
    if isinstance(fields, dict):
        parts.extend(str(v) for v in fields.values())
    return " ".join(str(p) for p in parts if p)


def _interactions_for(
    rule: SupplementRule, medications
) -> tuple[MatchedInteraction, ...]:
    """Every interaction this user's medications trigger, in file order.

    Never a reason to drop the finding. A match is the thing that makes this a
    human's decision rather than an arithmetic one, and suppressing the finding
    would mean the person most likely to need the conversation is the one who
    never gets it.
    """
    matched: list[MatchedInteraction] = []
    for row in medications or []:
        if not isinstance(row, dict):
            continue
        text = _medication_text(row)
        if not text:
            continue
        for interaction in rule.interactions:
            term = interaction.matched_in(text)
            if term is None:
                continue
            matched.append(
                MatchedInteraction(
                    medication=term,
                    recorded_as=str(row.get("title") or "").strip() or text,
                    note=interaction.note,
                )
            )
    return tuple(matched)


def _latest_per_marker(rows, as_of: date) -> dict[str, SelectedValue]:
    """The newest usable result for each marker, as of a date.

    `usable_values` applies the four exclusions a measurement has to survive --
    censored, qualitative, undated, wrong context -- so they are not repeated
    here. A second copy of those rules would eventually disagree with this one,
    and both would return plausible numbers.
    """
    latest: dict[str, SelectedValue] = {}
    for value in usable_values(rows):
        if value.context != _ACCEPTED_CONTEXT:
            continue
        if value.collected_at > as_of:
            # `as_of` is an upper bound, not a label: asking what was deficient
            # in June must not reach for a panel drawn in September.
            continue
        current = latest.get(value.biomarker_id)
        if current is None or value.collected_at >= current.collected_at:
            latest[value.biomarker_id] = value
    return latest


def find_deficiencies(
    rows,
    *,
    as_of: date,
    resolve: Callable[[str], ResolvedRange | None],
    medications=None,
) -> list[SupplementFinding]:
    """Every deficiency this user's confirmed results currently justify asking about.

    `rows` are `biomarker_results` records as `ContextLoader.biomarker_results`
    returns them -- already filtered to `confirmed` and `corrected`, because a
    value a machine read and nobody checked must not put something in front of
    a clinician either.

    `resolve` returns the range to grade a marker against for *this* user, which
    keeps the user out of this module entirely: the caller closes over the
    user's id, their overrides and their sex, and what comes back here is a
    range or nothing.
    """
    findings: list[SupplementFinding] = []
    history_before = as_of - timedelta(days=HISTORY_DAYS)

    for biomarker_id, value in _latest_per_marker(rows, as_of).items():
        rules = rules_for(biomarker_id)
        if not rules:
            continue

        # The plan's backfill rule, decided on the latest value by the same test
        # `extraction.ingest` uses to set `is_history`: a new user uploading five
        # years of old reports in one sitting must not produce five years of
        # recommendations. A deficiency measured two years ago is also simply
        # not news -- it has either been treated or it has not.
        if value.collected_at < history_before:
            continue

        resolved = resolve(biomarker_id)
        # `abnormal` and nothing else. `ungraded` is the review gate and the
        # unknown-sex refusal; `critical` belongs to the escalation path;
        # `normal` and `optimal` are not deficiencies. See the module docstring.
        if grade_for_display(value.value_canonical, resolved) != ABNORMAL:
            continue
        if value.value_canonical >= resolved.standard.low:
            # Abnormal in the other direction. A vitamin D of 120 is not a
            # reason to take more of it.
            continue

        for rule in rules:
            if not rule_review_status(rule.id).reviewed:
                continue
            findings.append(
                SupplementFinding(
                    rule=rule,
                    value=value,
                    standard=resolved.standard,
                    ranges_version=resolved.version,
                    interactions=_interactions_for(rule, medications),
                )
            )

    # Stable, so a producer enumerating these creates drafts in the same order
    # on every run. Dictionary order would make a queue impossible to reason
    # about and this module impossible to test.
    return sorted(findings, key=lambda f: (f.rule.id, f.biomarker_id))
