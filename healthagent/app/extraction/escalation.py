"""A critical value cannot wait in a queue.

This fires immediately and deterministically: before the user has confirmed
anything, while the catalog is still clinically unreviewed, and independent of
any review state. The clinician queue is for recommendations, never for
emergencies — the same reason `ESCALATION_LINE` already bypasses the guardrail
rewrite rather than being subject to it.

Two deliberate exemptions, both safety decisions:

**Not gated on clinical review.** Grading is suppressed until a clinician signs
the catalog off. Escalation is not, because a bound we are unsure of is still a
far better reason to escalate than silence is.

**Not routed through `RangeResolver`.** It returns None for a sex-specific
marker when sex is unknown — right for grading, catastrophic here. Haemoglobin's
standard range differs by sex; its critical bounds do not.

**On the wording.** Whoop Advanced Labs and Function Health both have a
clinician telephone the member for a critical result. We cannot do that until
F5, so this says the one true thing we can say — this number is far outside the
expected range, have it looked at — and names no condition, because the ranges
it fired on have not been reviewed.
"""

from dataclasses import dataclass

from app.analytics import catalog
from app.analytics.reference_ranges import is_critical

# Deliberately not a severity scale. There is one level here, and it means
# "today, not at your next appointment".
CRITICAL = "critical"


@dataclass(frozen=True)
class CriticalFinding:
    biomarker_id: str
    context: str
    value_canonical: float
    operator: str
    unit: str
    message: str
    severity: str = CRITICAL


def _message(name: str, printed: str, unit: str) -> str:
    """Factual, non-diagnostic, and it tells the person what to do.

    No condition is named and no severity adjective is used: both would be
    clinical claims drawn from ranges no clinician has reviewed, and if a bound
    is wrong the claim frightens someone over a normal result.
    """
    return (
        f"One value in this report ({name} {printed} {unit}) is far outside the "
        f"range we would expect. Please have it reviewed by a doctor promptly. "
        f"This is an automated check, not a medical opinion, and we are not an "
        f"emergency service — if you feel unwell, seek medical care right away."
    ).strip()


def critical_findings(results) -> tuple[CriticalFinding, ...]:
    """Every result outside the catalog's critical bounds, in the order given.

    Pure. No clock, no database, no model — this must behave identically in the
    worker, in a replay and in a test.
    """
    findings = []
    for result in results:
        if not is_critical(result.biomarker_id, result.value_canonical):
            continue
        marker = catalog.get(result.biomarker_id)
        printed = f"{result.operator if result.operator != '=' else ''}{result.raw_value}"
        findings.append(
            CriticalFinding(
                biomarker_id=result.biomarker_id,
                context=result.context,
                value_canonical=result.value_canonical,
                operator=result.operator,
                unit=result.unit_canonical or marker.canonical_unit,
                message=_message(
                    marker.name, printed, result.unit_canonical or marker.canonical_unit
                ),
            )
        )
    return tuple(findings)
