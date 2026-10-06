"""Which range applies to this person, and how a value grades against it.

Two properties matter more than the arithmetic.

**Resolution order is decided in exactly one place:** user override, then clinic
override, then the global catalog. Spreading that decision across call sites is
how two screens end up disagreeing about whether the same result is normal.

**A result already shown to someone cannot change meaning later.** Ranges are
versioned and immutable; a clinician override appends a new set rather than
editing a row, and every computed artefact stamps the version it used. A range
changed tomorrow produces a new snapshot — it cannot retroactively rewrite a
number the user has already read.

Critical bounds come from the catalog and are **never overridable**. A clinic
may take a view on what counts as normal for its patients; it may not switch off
the threshold at which we tell someone to seek care.
"""

from dataclasses import dataclass
from typing import Callable

from app.analytics import catalog
from app.analytics.catalog import Range

# Grades, worst last so `max` over an order index rolls up correctly.
UNGRADED = "ungraded"
OPTIMAL = "optimal"
NORMAL = "normal"
ABNORMAL = "abnormal"
CRITICAL = "critical"

_SEVERITY = {UNGRADED: 0, OPTIMAL: 1, NORMAL: 2, ABNORMAL: 3, CRITICAL: 4}

_SCOPE_PRECEDENCE = {"user": 0, "clinic": 1, "global": 2}


@dataclass(frozen=True)
class ResolvedRange:
    """The range actually used, carrying enough to reproduce the decision."""

    biomarker_id: str
    standard: Range
    optimal: Range
    critical: Range
    canonical_unit: str
    version: str
    scope: str  # user | clinic | global
    citation: str


def _row_to_range(row: dict, marker: catalog.Biomarker) -> ResolvedRange:
    return ResolvedRange(
        biomarker_id=marker.id,
        standard=Range(float(row["standard_low"]), float(row["standard_high"])),
        optimal=Range(float(row["optimal_low"]), float(row["optimal_high"])),
        critical=marker.critical,  # never overridable
        canonical_unit=marker.canonical_unit,
        version=str(row["version"]),
        scope=str(row["scope"]),
        citation=str(row.get("citation") or marker.citation),
    )


class RangeResolver:
    """Resolves ranges for one user, caching their overrides for the call.

    The override lookup is per user, not per marker: grading a 40-marker panel
    must not be 40 round trips.
    """

    def __init__(self, load_overrides: Callable[[str], list[dict]] | None = None):
        self._load_overrides = load_overrides
        self._cache: dict[str, list[dict]] = {}

    def _overrides_for(self, user_id: str) -> list[dict]:
        if self._load_overrides is None:
            return []
        if user_id not in self._cache:
            self._cache[user_id] = list(self._load_overrides(user_id) or [])
        return self._cache[user_id]

    def resolve(
        self, biomarker_id: str, user_id: str, sex: str | None = None
    ) -> ResolvedRange | None:
        """The range to grade against, or None when we cannot say.

        None is returned for an unknown marker, and for a sex-specific marker
        whose subject's sex we do not know — picking a default would silently
        grade a woman against a man's range.
        """
        marker = catalog.get(biomarker_id)
        if marker is None:
            return None

        candidates = [
            row
            for row in self._overrides_for(user_id)
            if row.get("biomarker_id") == biomarker_id
            and row.get("scope") in _SCOPE_PRECEDENCE
        ]
        if candidates:
            best = min(candidates, key=lambda r: _SCOPE_PRECEDENCE[r["scope"]])
            return _row_to_range(best, marker)

        bands = marker.ranges_for(sex)
        if bands is None:
            return None
        standard, optimal = bands
        return ResolvedRange(
            biomarker_id=marker.id,
            standard=standard,
            optimal=optimal,
            critical=marker.critical,
            canonical_unit=marker.canonical_unit,
            version=catalog.catalog_version(),
            scope="global",
            citation=marker.citation,
        )


def grade(value: float | None, resolved: ResolvedRange | None) -> str:
    """Where a canonical value sits. `ungraded` when we cannot say — which must
    never be rendered as a clean result."""
    if value is None or resolved is None:
        return UNGRADED
    if not resolved.critical.contains(value):
        return CRITICAL
    if resolved.optimal.contains(value):
        return OPTIMAL
    if resolved.standard.contains(value):
        return NORMAL
    return ABNORMAL


def worst(grades) -> str:
    """Roll several grades up to the one that should drive the headline."""
    return max(grades, key=lambda g: _SEVERITY.get(g, 0), default=UNGRADED)


def grade_for_display(value: float | None, resolved: ResolvedRange | None) -> str:
    """The grade a **user** may be shown. Use this, not `grade`, for anything
    user-facing.

    `grade` is the arithmetic. This is the arithmetic plus the one question the
    arithmetic cannot answer: has a clinician agreed these ranges are right?
    While `biomarkers.v1.yaml` is an unreviewed v1 draft, every result comes back
    `ungraded` — we show the number as printed and make no claim about it.

    Note that this suppresses *abnormal* verdicts as well as reassuring ones. The
    gate is not "withhold bad news"; it is "make no clinical claim", and calling
    something abnormal is as much a claim as calling it optimal.
    """
    if not catalog.review_status().reviewed:
        return UNGRADED
    return grade(value, resolved)


def is_critical(biomarker_id: str, value: float | None) -> bool:
    """Is this value outside the bounds at which we tell someone to seek care?

    Deliberately **not** gated on clinician review, and deliberately **not**
    routed through `RangeResolver`. Both of those are safety decisions:

    **Not gated**, because a critical value cannot wait for a review meeting.
    The clinician queue is for recommendations, never for emergencies.

    **Not resolved**, because `resolve()` returns None for a sex-specific marker
    when the subject's sex is unknown — which is correct for grading and
    catastrophic here. Haemoglobin's standard range differs by sex; its critical
    bounds do not. Going through the resolver would mean a haemoglobin of 4.1
    escalates nothing for every user whose sex we do not hold.

    Critical bounds come from the catalog and are never overridable, so there is
    nothing per-user to resolve in the first place.
    """
    if value is None:
        return False
    marker = catalog.get(biomarker_id)
    if marker is None:
        # No bounds, so no basis. Escalating on a label we failed to map would
        # fire on every unmapped row in every report.
        return False
    return not marker.critical.contains(value)
