"""Which markers have moved enough that a human should look.

The deterministic half of F5's draft producer. Per CLAUDE.md, alert *decisions*
are testable rules and only the *wording* is generative, so the rule lives here
in ordinary Python and nothing in this module writes a sentence. What a draft
says about a trend is `app/clinical/drafts.py`'s business.

### What counts as a trend

Four conditions, and each one is protecting against a specific way of being
useless:

1. **At least three points.** Two results are a before and an after. Direction
   needs a third, or every pair of consecutive panels becomes a clinician's
   problem.
2. **Spanning at least two months.** A repeat panel to confirm an odd result is
   not eight months of movement; without this, one anxious week of retesting
   reads as a trend.
3. **A relative change past a threshold.** Assay imprecision on HbA1c is a
   couple of percent, so a 3% rise is the machine and not the person.
4. **The latest value is the series extreme in the direction of travel.** "It
   has risen and is now the highest it has been" is a sentence worth a human's
   time. "It rose and is coming back down" is not, and flagging it would mean
   flagging ordinary variation.

Condition 4 is doing the work that a monotonicity requirement would do far too
strictly: real lab series are noisy, and insisting every consecutive step move
the same way would reject almost every genuine trend.

### What this module deliberately does not know

Whether a direction is *good*. Haemoglobin falling and ferritin rising are both
trends; which of them is bad, and by how much, is a clinical judgement made by
the person who signs the draft. The module reports direction and magnitude and
stops there — which is also why it needs no reference ranges and works
unchanged while `biomarkers.v1.yaml` is clinically unreviewed.

It also does not know about critical values. A potassium of 7 escalates through
`lab_escalations` immediately and deterministically, and must never wait behind
a review queue; the draft layer is where that exclusion is applied, because that
is where the queue is.
"""

from dataclasses import dataclass
from datetime import date, timedelta

from app.analytics.biomarker_selection import SelectedValue, usable_values
from app.common.timeparse import parse_ts
from app.extraction.ingest import HISTORY_DAYS

MODEL_VERSION = "marker-trend-v1"

#: Fewer than this and there is no direction, only a change.
MIN_POINTS = 3

#: Three draws inside a fortnight is a retest, not a trajectory.
MIN_SPAN_DAYS = 60

#: Below this it is assay imprecision. v1, and intended to be tuned with domain
#: input -- most analytes have a between-run CV of 1-5%, so 10% is a couple of
#: times the noise floor rather than a number chosen to look round.
MIN_RELATIVE_CHANGE = 0.10

#: How far back a series may reach. Matches the biological-age lookback: two
#: years is enough for someone who tests annually, and keeps a 2019 panel from
#: anchoring a trend reported today.
TREND_WINDOW_DAYS = 730

RISING = "rising"
FALLING = "falling"


@dataclass(frozen=True)
class MarkerTrend:
    """One marker moving in one direction, with the series that says so.

    `points` is carried in full rather than summarised because this becomes the
    draft's `evidence`, and a clinician asked to put their registration number
    against a sentence needs to see the series without the console querying
    anything else.
    """

    biomarker_id: str
    context: str
    direction: str
    points: tuple[SelectedValue, ...]
    relative_change: float
    unit: str

    @property
    def first(self) -> SelectedValue:
        return self.points[0]

    @property
    def latest(self) -> SelectedValue:
        return self.points[-1]

    @property
    def as_of(self) -> date:
        """The latest draw, never today.

        A trend says something about a blood draw. Dating it to the day the
        sweep ran would put a June panel on October's chart and re-draft the
        same trend every night -- the same reasoning as `score_snapshots`
        dating a biological age to its panel.
        """
        return self.latest.collected_at

    @property
    def span_days(self) -> int:
        return (self.latest.collected_at - self.first.collected_at).days


def _one_per_day(values: list[SelectedValue]) -> list[SelectedValue]:
    """The last result for each collection date.

    A lab reissuing a corrected report gives two rows with one collection date.
    Counting both inflates the point count, so MIN_POINTS could be satisfied by
    two real draws and a correction.
    """
    by_day: dict[date, SelectedValue] = {}
    for value in values:
        by_day[value.collected_at] = value
    return [by_day[day] for day in sorted(by_day)]


def _direction(points: list[SelectedValue]) -> str | None:
    """Which way it is going, or None if it is not going anywhere.

    The latest value must be the extreme of the series in its own direction.
    Without that, a marker that rose for a year and has been falling for three
    months reports as rising and arrives in the queue as news.
    """
    values = [p.value_canonical for p in points]
    first, latest = values[0], values[-1]

    if latest > first and latest >= max(values):
        return RISING
    if latest < first and latest <= min(values):
        return FALLING
    return None


def find_trends(rows, as_of: date) -> list[MarkerTrend]:
    """Every marker trending as of a date, in a stable order.

    `rows` are `biomarker_results` records as `ContextLoader.biomarker_results`
    returns them -- already filtered to `confirmed` and `corrected`, because a
    value a machine read and nobody checked must not put something in front of
    a clinician either.

    `as_of` is an upper bound, not a label: asking what was trending in June
    must not reach for a panel drawn in September. The same rule
    `scores._results_up_to` applies to biological age.
    """
    earliest = as_of - timedelta(days=TREND_WINDOW_DAYS)

    series: dict[tuple[str, str], list[SelectedValue]] = {}
    for value in usable_values(rows):
        if not earliest <= value.collected_at <= as_of:
            continue
        # Keyed by context as well as marker. The catalog maps "Glucose,
        # Fasting" and "Glucose, Post Prandial" onto one biomarker_id and only
        # `context` separates them; read as one series they produce a sawtooth
        # that looks like a dramatic trend in whichever direction the last draw
        # happened to be.
        series.setdefault((value.biomarker_id, value.context), []).append(value)

    trends: list[MarkerTrend] = []
    for (marker, context), values in series.items():
        points = _one_per_day(values)
        if len(points) < MIN_POINTS:
            continue

        latest = points[-1]
        # The plan's backfill rule: a document older than N days is history, and
        # history populates trends but generates no drafts. Decided on the
        # latest point, by the same test `extraction.ingest` uses to set
        # `is_history` -- older points being historical is exactly what history
        # is for, and excluding them would mean a trend only ever becomes
        # visible after someone has tested three more times.
        if latest.collected_at < as_of - timedelta(days=HISTORY_DAYS):
            continue

        if (latest.collected_at - points[0].collected_at).days < MIN_SPAN_DAYS:
            continue

        first_value = points[0].value_canonical
        if not first_value:
            # A relative change from zero is undefined rather than infinite.
            continue

        change = (latest.value_canonical - first_value) / first_value
        if abs(change) < MIN_RELATIVE_CHANGE:
            continue

        direction = _direction(points)
        if direction is None:
            continue

        trends.append(
            MarkerTrend(
                biomarker_id=marker,
                context=context,
                direction=direction,
                points=tuple(points),
                relative_change=change,
                unit=latest.unit_canonical,
            )
        )

    # Stable, so a draft producer enumerating these creates drafts in the same
    # order on every run. Dictionary order would make a queue impossible to
    # reason about and this module impossible to test.
    return sorted(trends, key=lambda t: (t.biomarker_id, t.context))
