"""Sleep summary, ported from the Flutter app at identical behaviour.

Only what readiness needs — total asleep hours and bedtime — plus the pieces
required to compute them faithfully. The port is deliberately literal: changing
the model and moving it to the server at the same time would make any
divergence impossible to attribute.

Source: mobile/lib/features/sleep/data/sleep_analysis.dart
"""

from dataclasses import dataclass
from datetime import datetime, timedelta

from app.analytics.dartcompat import in_minutes

SLEEP_TYPES = frozenset({
    "sleep", "sleepInBed", "sleepLight", "sleepDeep", "sleepRem", "sleepAwake",
})
ASLEEP_TYPES = frozenset({"sleep", "sleepLight", "sleepDeep", "sleepRem"})


@dataclass(frozen=True)
class Reading:
    measurement_type: str
    value: float
    recorded_at: datetime
    ended_at: datetime | None = None

    @property
    def end(self) -> datetime:
        """An interval's end, or one inferred from a duration in hours."""
        if self.ended_at is not None:
            return self.ended_at
        from app.analytics.dartcompat import dart_round

        return self.recorded_at + timedelta(minutes=dart_round(self.value * 60))


@dataclass(frozen=True)
class SleepSummary:
    total_hours: float
    bedtime: datetime | None


def _union_hours(records: list[Reading]) -> float:
    """Merged span length. Overlapping records from two devices must not be
    counted twice."""
    if not records:
        return 0.0
    spans = sorted(
        ((r.recorded_at, r.end) for r in records if r.end > r.recorded_at),
        key=lambda s: s[0],
    )
    if not spans:
        return sum(r.value for r in records)

    start, end = spans[0]
    minutes = 0
    for span_start, span_end in spans[1:]:
        if span_start <= end:
            if span_end > end:
                end = span_end
        else:
            minutes += in_minutes(end - start)
            start, end = span_start, span_end
    minutes += in_minutes(end - start)
    return minutes / 60


def summarize(readings: list[Reading], day: datetime) -> SleepSummary:
    """A night is attributed to the day its records END on, which is what makes
    sleep spanning midnight land on the morning it finished."""
    day = day.replace(hour=0, minute=0, second=0, microsecond=0)
    nxt = day + timedelta(days=1)

    records = [r for r in readings
               if r.measurement_type in SLEEP_TYPES and day <= r.end < nxt]
    if not records:
        return SleepSummary(total_hours=0.0, bedtime=None)

    asleep = [r for r in records if r.measurement_type in ASLEEP_TYPES]
    return SleepSummary(
        total_hours=_union_hours(asleep),
        bedtime=min(r.recorded_at for r in records),
    )
