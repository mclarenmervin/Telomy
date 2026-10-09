"""Which lab results a score is computed from.

Separated from `biological_age` on purpose. The model is published arithmetic
that can be checked against a paper; this is judgement about messy real data,
and it is the part that will be quietly wrong if it is not looked at directly.

Four kinds of row must never reach the arithmetic, and every one of them looks
perfectly fine from a SQL prompt:

**Censored results.** `<0.01`, `>500`. The operator says the lab could not
measure past a bound, so the true value is unknown. Such a value may be shown
to the user and may trigger escalation, but it cannot be a term in a model --
`<0.01` is not 0.01, and treating it as such invents a measurement.

**Qualitative results.** `value_canonical` is NULL and `value_text` carries
"Positive" or "Trace". A None reaching a multiplication is a crash if we are
lucky and a zero if we are not.

**Undated results.** `collected_at` is nullable and is null while the
confirmation UI is still asking which of the three dates on the PDF is the
collection date. A biological age needs a date to belong to, and defaulting to
today would put a 2019 panel on this week's chart.

**The wrong one of two legitimate duplicates.** Fasting and post-prandial
glucose are one biomarker and two results -- the catalog maps both labels onto
`glucose_fasting` -- separated only by `context`. PhenoAge was fitted on fasting
glucose. Averaging them, or taking whichever sorts first, is how a
well-controlled person ends up looking diabetic.

### What counts as one panel

A blood draw is one event, but a lab routinely splits it across several reports
and sometimes several dates: the CBC comes back today and the metabolic panel
three days later. Requiring a single collection date would mean almost nobody
ever gets a number, so results within `PANEL_WINDOW_DAYS` of an anchor date
count as one assessment, and the span is recorded.

The anchor is **the most recent date that yields a complete panel**, not simply
the most recent date. Uploading a single CRP today must not hide last month's
full panel; and when it does not hide it, the resulting age belongs to that
panel's collection date rather than to today.
"""

import hashlib
import json
from dataclasses import dataclass, field
from datetime import date, timedelta

from app.analytics.biological_age import PHENOAGE_MARKERS
from app.common.timeparse import parse_ts

#: How far apart results may sit and still describe one assessment. Two months
#: is generous enough for a lab that splits panels across reports and tight
#: enough that a 2024 CBC is never read alongside a 2026 metabolic panel.
PANEL_WINDOW_DAYS = 60

# Contexts a marker will accept, in order of preference. A context not listed is
# refused rather than ranked last: a two-hour post-prandial glucose is not a
# worse fasting glucose, it is a different measurement.
_ACCEPTED_CONTEXTS = {
    "glucose_fasting": ("fasting", "standard"),
}
_DEFAULT_CONTEXTS = ("standard",)

CENSORED = "censored"
QUALITATIVE = "qualitative"
NO_DATE = "no_collection_date"
WRONG_CONTEXT = "wrong_context"
OUT_OF_WINDOW = "outside_panel_window"


@dataclass(frozen=True)
class SelectedValue:
    """One result, chosen over any competing row, with enough to explain why."""

    biomarker_id: str
    value_canonical: float
    unit_canonical: str
    collected_at: date
    context: str
    lab_name: str | None = None


@dataclass(frozen=True)
class Panel:
    """The set of values one score is computed from.

    `notes` explains a marker we had data for but could not use -- "censored",
    "wrong_context" -- which is the difference between telling someone "we need
    a fasting glucose" and telling them "glucose missing" when their report
    plainly shows one.
    """

    as_of: date | None
    selected: dict[str, SelectedValue] = field(default_factory=dict)
    missing: tuple[str, ...] = ()
    notes: dict[str, str] = field(default_factory=dict)
    span_days: int = 0

    @property
    def canonical(self) -> dict[str, float]:
        """What the model consumes: biomarker_id -> canonical value."""
        return {k: v.value_canonical for k, v in self.selected.items()}

    @property
    def complete(self) -> bool:
        return not self.missing

    def fingerprint(self) -> dict:
        """The part of `inputs_hash` that describes the data.

        Sorted and explicit: reordering rows must not look like the user's data
        changed, and a changed value must not look like the same panel.
        """
        return {
            "as_of": self.as_of.isoformat() if self.as_of else None,
            "span_days": self.span_days,
            "values": {
                marker: [
                    value.value_canonical,
                    value.unit_canonical,
                    value.collected_at.isoformat(),
                    value.context,
                ]
                for marker, value in sorted(self.selected.items())
            },
            "missing": sorted(self.missing),
        }

    def fingerprint_hash(self) -> str:
        payload = json.dumps(self.fingerprint(), sort_keys=True, separators=(",", ":"))
        return "sha256:" + hashlib.sha256(payload.encode()).hexdigest()


@dataclass(frozen=True)
class _Candidate:
    marker: str
    collected_at: date
    rank: int  # index into the marker's accepted contexts; lower is preferred
    value: SelectedValue


def _usable(
    row: dict, markers, any_context: bool = False
) -> tuple[_Candidate | None, tuple[str, str] | None]:
    """A candidate, or (marker, reason) for a row we will not use.

    Order matters. A row can fail several ways at once and the reason reported
    is the one the user can act on: "we need a fasting glucose" is actionable,
    "censored" is not something they can change.

    `any_context` separates a *score* concern from a universal one. Refusing a
    post-prandial glucose is right for a score: PhenoAge was fitted on fasting
    glucose, and the two are different measurements rather than a good and a bad
    version of one. It is wrong for a series, where a post-prandial glucose
    climbing over a year is a finding in its own right -- the caller groups by
    context, so each is its own series and none of them competes with another.

    The other three exclusions -- censored, qualitative, undated -- are
    universal and apply either way.
    """
    marker = row.get("biomarker_id")
    if marker not in markers:
        return None, None

    contexts = _ACCEPTED_CONTEXTS.get(marker, _DEFAULT_CONTEXTS)
    context = row.get("context") or "standard"
    if not any_context and context not in contexts:
        return None, (marker, WRONG_CONTEXT)

    if (row.get("result_type") or "quantitative") != "quantitative":
        return None, (marker, QUALITATIVE)

    if (row.get("operator") or "=") != "=":
        return None, (marker, CENSORED)

    raw = row.get("value_canonical")
    if raw is None:
        return None, (marker, QUALITATIVE)

    collected = parse_ts(row.get("collected_at"))
    if collected is None:
        return None, (marker, NO_DATE)

    return _Candidate(
        marker=marker,
        collected_at=collected.date(),
        rank=contexts.index(context) if context in contexts else 0,
        value=SelectedValue(
            biomarker_id=marker,
            value_canonical=float(raw),
            unit_canonical=str(row.get("unit_canonical") or ""),
            collected_at=collected.date(),
            context=context,
            lab_name=row.get("lab_name"),
        ),
    ), None


def usable_values(rows, markers=None) -> list[SelectedValue]:
    """Every row that may be used as a measurement, in collection order.

    The same four exclusions `_usable` applies for a score -- censored,
    qualitative, undated, wrong context -- exposed for callers that need a
    *series* rather than one value per marker. `marker_trends` is the first.

    A second copy of those rules would eventually disagree with this one, and
    the disagreement would be invisible: both would return plausible numbers.

    `markers=None` means every marker the catalog knows, rather than the fitted
    PhenoAge set. A trend is not restricted to markers some published model
    happened to use.
    """
    out = []
    for row in rows or []:
        marker = row.get("biomarker_id")
        if not marker:
            continue
        candidate, _ = _usable(
            row, markers if markers is not None else (marker,), any_context=True
        )
        if candidate is not None:
            out.append(candidate.value)
    # Collection date first, then the marker, so a caller enumerating these
    # gets the same order whatever order the database returned.
    return sorted(out, key=lambda v: (v.collected_at, v.biomarker_id, v.context))


def _best_within(candidates, anchor: date, markers) -> dict[str, SelectedValue]:
    """One value per marker, inside the window ending at `anchor`.

    Nearest the anchor wins, then the preferred context. Never an average: two
    draws a week apart are two measurements, not one with error bars.
    """
    earliest = anchor - timedelta(days=PANEL_WINDOW_DAYS)
    chosen: dict[str, _Candidate] = {}
    for candidate in candidates:
        if not earliest <= candidate.collected_at <= anchor:
            continue
        current = chosen.get(candidate.marker)
        if current is None or (
            # Later date first, then the better context. Both keys are total and
            # the table's unique index makes (date, context) unique per marker,
            # so the choice is deterministic.
            (candidate.collected_at, -candidate.rank)
            > (current.collected_at, -current.rank)
        ):
            chosen[candidate.marker] = candidate
    return {marker: c.value for marker, c in chosen.items()}


def select_panel(rows, markers=PHENOAGE_MARKERS) -> Panel:
    """The most recent complete panel in `rows`, or the most recent attempt.

    `rows` are `biomarker_results` records as `ContextLoader.biomarker_results`
    returns them -- already filtered to `confirmed` and `corrected`, because a
    value nobody has checked must not reach a score.
    """
    markers = tuple(markers)
    candidates: list[_Candidate] = []
    notes: dict[str, str] = {}

    for raw in rows or []:
        candidate, rejection = _usable(raw, markers)
        if candidate is not None:
            candidates.append(candidate)
        elif rejection is not None:
            marker, reason = rejection
            # First reason wins, and rows arrive newest first, so the note
            # describes the most recent thing that went wrong.
            notes.setdefault(marker, reason)

    if not candidates:
        return Panel(
            as_of=None,
            missing=tuple(markers),
            notes={m: notes[m] for m in markers if m in notes},
        )

    # Try each distinct collection date as an anchor, newest first, and take the
    # first that yields a complete panel.
    #
    # Falling back to the newest anchor rather than to whichever anchor yields
    # the most markers is deliberate. The fallback exists to tell the user what
    # their latest draw is missing, which is something they can act on; an older
    # anchor that happens to cover more markers would date the snapshot in the
    # past and advise repeating tests they have already had.
    anchors = sorted({c.collected_at for c in candidates}, reverse=True)
    best_anchor = anchors[0]
    best = _best_within(candidates, best_anchor, markers)
    for anchor in anchors:
        selected = _best_within(candidates, anchor, markers)
        if len(selected) == len(markers):
            best, best_anchor = selected, anchor
            break

    missing = tuple(m for m in markers if m not in best)
    dates = [v.collected_at for v in best.values()]
    return Panel(
        as_of=best_anchor,
        selected=best,
        missing=missing,
        notes={m: notes[m] for m in missing if m in notes},
        span_days=(max(dates) - min(dates)).days if dates else 0,
    )
