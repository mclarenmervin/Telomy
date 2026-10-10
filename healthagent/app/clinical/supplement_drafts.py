"""Turning a deficiency into something a clinician must sign.

`analytics/supplements.py` decides whether a human should be asked. This
decides what they are shown, and it is the first producer in the system whose
output **cannot** reach a user unreviewed. That asymmetry is the whole point of
the phase, so it is worth being precise about where it comes from.

### A trend states arithmetic; a recommendation does not

F5's trend draft says "HbA1c has risen 11.1% across 3 results". That is a fact
about two numbers, it carries no routing flags, and it is therefore eligible
for the SLA escape hatch: if the queue stalls, a statement of arithmetic can
still reach the user with the honest label that nobody reviewed it.

A supplement draft says what to do. It can never take that path, and the
mechanism is the flag: `013_clinical_review.sql` refuses to deliver a flagged
draft without a signature, in the database, so the clinician console and our
own service role are both bound by it.

### The flag comes from the guardrail, never from here

A producer that set `routing_flags=['supplement']` by hand would be a second
opinion about what counts as medication content, and the second opinion
eventually disagrees with the first -- at which point a draft reaches a user
unflagged carrying text the autonomous profile would have replaced. So the body
is built, run through `apply_guardrails` in the clinician profile, and whatever
comes back is what the draft carries.

Which leaves one case that must not be allowed to pass quietly: a body the
guardrail did *not* flag. That draft would be SLA-deliverable, which for a
recommendation is exactly the outcome the gate exists to prevent. It is refused
rather than written, loudly, because the honest failure is that a clinician is
not asked and nobody is told anything -- not that a recommendation goes out
unread.

### The medical wording is reviewed content

The recommendation sentence is printed verbatim from `supplements.v1.yaml`,
where it is bound to a clinician's signature by a content hash. This module
fills in the number, the unit, the date and the range. It does not paraphrase
the sentence, and editing that sentence in the file withdraws the sign-off and
stops the draft being produced at all.
"""

from datetime import date
from typing import Callable

from app.agent.guardrails import CLINICIAN_QUEUE, apply_guardrails
from app.analytics import catalog
from app.analytics.reference_ranges import ResolvedRange
from app.analytics.supplement_rules import review_status as rule_review_status
from app.analytics.supplements import SupplementFinding, find_deficiencies
from app.clinical.drafts import DraftCandidate, printed_date, quantity
from app.common.logging_config import get_logger, log_context

logger = get_logger(__name__)

#: A deficiency and what to do about it is a supplement draft. The kind the
#: database's delivery gate treats as needing a signature -- not because of the
#: kind, which the gate never reads, but because of the flag the guardrail puts
#: on it.
DRAFT_KIND = "supplement"

#: What this was noticed from, beside F5's `biomarker_trend`.
SOURCE_KIND = "biomarker_deficiency"


def _marker_name(biomarker_id: str) -> str:
    marker = catalog.get(biomarker_id)
    return marker.name if marker else biomarker_id


def _body(finding: SupplementFinding) -> str:
    """The draft as a clinician reads it, and as the user reads it once signed.

    Deliberately impersonal. After a signature this same text is what arrives
    on the person's phone, so "the user also takes" would read oddly to the
    person it is about -- and rewriting it at delivery would break the hash the
    signature is over.
    """
    value = finding.value
    name = _marker_name(finding.biomarker_id)
    standard = finding.standard

    sentences = [
        f"{name} was {quantity(value.value_canonical, value.unit_canonical)} on "
        f"{printed_date(value.collected_at)}, below the standard range of "
        f"{standard.low:g}–{standard.high:g} {value.unit_canonical}.",
        finding.rule.recommendation,
    ]

    # Named rather than merely flagged. A clinician must not have to notice the
    # interaction themselves, and for several of these the interaction changes
    # the answer rather than qualifying it.
    for interaction in finding.interactions:
        sentences.append(f"Also recorded: {interaction.recorded_as}. {interaction.note}")

    return " ".join(sentences)


def _evidence(finding: SupplementFinding) -> list[dict]:
    """What the claim rests on, in the shape the phone already parses.

    The measurement entry uses F5's keys exactly, because the app reads one
    shape and an entry it cannot read renders as a blank row -- the class of bug
    F4 and F5 each shipped to a real screen. `kind` is new and additive: an
    entry without one is a measurement, which is what every existing trend
    draft's evidence is.

    Dates are isoformat strings rather than date objects: this lands in a jsonb
    column on an unattended sweep, where a type error is a draft nobody gets and
    nobody notices.
    """
    value = finding.value
    rule = finding.rule
    review = rule_review_status(rule.id)

    entries: list[dict] = [
        {
            "kind": "measurement",
            "biomarker_id": value.biomarker_id,
            "value_canonical": value.value_canonical,
            "unit_canonical": value.unit_canonical,
            "collected_at": value.collected_at.isoformat(),
            "context": value.context,
            "lab_name": value.lab_name,
        },
        {
            "kind": "reference_range",
            "biomarker_id": value.biomarker_id,
            "standard_low": finding.standard.low,
            "standard_high": finding.standard.high,
            "unit_canonical": value.unit_canonical,
            # Stamped, so a range edited tomorrow cannot retroactively change
            # what this draft claimed -- the discipline `score_snapshots` uses.
            "ranges_version": finding.ranges_version,
            "citation": (catalog.get(value.biomarker_id).citation
                         if catalog.get(value.biomarker_id) else ""),
        },
        {
            # Two signatures stand behind a delivered supplement insight: the
            # clinician who signs this draft, and the one who signed the rule it
            # applied. The second is invisible unless the draft carries it.
            "kind": "rule",
            "rule_id": rule.id,
            "supplement": rule.supplement,
            "trigger": rule.trigger,
            "citation": rule.citation,
            "reviewer": review.reviewer or "",
            "reviewed_at": review.reviewed_at or "",
        },
    ]
    entries.extend(
        {
            "kind": "interaction",
            "medication": interaction.medication,
            "recorded_as": interaction.recorded_as,
            "note": interaction.note,
        }
        for interaction in finding.interactions
    )
    return entries


def draft_for_finding(
    finding: SupplementFinding, user_id: str
) -> DraftCandidate | None:
    """One deficiency as a draft, or None if it must not become one.

    None means the guardrail did not flag the body. See the module docstring:
    an unflagged supplement draft would be deliverable without a signature, so
    refusing to create it is the safe failure.
    """
    rule = finding.rule
    name = _marker_name(finding.biomarker_id)

    title = f"{name} is below the standard range"
    body, flags = apply_guardrails(
        _body(finding), {"metrics": {}}, profile=CLINICIAN_QUEUE
    )

    if not flags:
        logger.error(
            f"refusing to draft an unflagged supplement recommendation "
            f"{log_context(user_id=user_id)} rule={rule.id} "
            f"marker={finding.biomarker_id}: the guardrail did not flag it, so "
            "the SLA sweep could deliver it to the user unreviewed"
        )
        return None

    return DraftCandidate(
        user_id=user_id,
        kind=DRAFT_KIND,
        title=title,
        body=body,
        # The rule, the marker and the draw it was measured on -- what was
        # noticed, not when we noticed it. A fresh panel that is still deficient
        # is a new finding and deserves a clinician's view of the new number.
        dedupe_key=(
            f"supplement:{rule.id}:{finding.biomarker_id}:{finding.as_of.isoformat()}"
        ),
        evidence=_evidence(finding),
        routing_flags=flags,
        model_version=finding.model_version,
        source_kind=SOURCE_KIND,
    )


def supplement_drafts(
    rows,
    *,
    user_id: str,
    as_of: date,
    resolve: Callable[[str], ResolvedRange | None],
    medications=None,
) -> list[DraftCandidate]:
    """Every supplement draft this user's confirmed results currently justify.

    Empty while `supplements.v1.yaml` is unsigned, which is the shipped state.
    """
    candidates = []
    for finding in find_deficiencies(
        rows, as_of=as_of, resolve=resolve, medications=medications
    ):
        candidate = draft_for_finding(finding, user_id=user_id)
        if candidate is not None:
            candidates.append(candidate)
    return candidates
