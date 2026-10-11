"""Correlations v2 — which patterns a person is allowed to be shown.

The version this replaces lived in Dart, tested every one of forty-five pairs,
accepted five matching days, applied no multiple-comparison correction, and
labelled whatever came out "Strong pattern · move together". Three of those
four are ways of being confidently wrong, and the fourth is the dual-math
defect: a number the server narrates and the phone computes cannot agree.

So this is the server's implementation, and there is one of it. The REST
endpoint the screen reads and the tool the concierge calls run this function
(the rule in CLAUDE.md: one implementation, two callers). The phone keeps a
visibly labelled offline estimate and never writes one back.

### The two gates, and the order they run in

**Plausibility first, and it is not a filter.** The hypothesis set is
`correlation_mechanisms.testable_pairs()` and nothing else is ever computed.
Testing only pairs we were already prepared to explain is pre-registration:
"we had eight hypotheses and three held" is a different claim from "we looked
at forty-five pairs and three came out significant", and only the first one is
true of this engine. It also makes the correction below honest, because `m` is
the number of things we would ever report.

**Then significance**, in three parts, each refusing a different way of being
wrong:

  * a floor on paired days, because five days of anything correlate with five
    days of anything else often enough to put a label on a screen
  * the Benjamini-Hochberg step-up over the whole run, because even eight
    hypotheses at p < 0.05 produce a spurious one often enough to matter — and
    computed over the *effective* sample size, since consecutive days of
    resting heart rate are not independent observations and the uncorrected
    p-value is anti-conservative by a large factor
  * a floor on the coefficient itself, because a real r of 0.15 over three
    hundred days is true and not worth a sentence

**And the direction last.** A mechanism predicts a sign. A correlation that is
statistically clean and runs the other way is not that mechanism — it is a
confounder wearing its clothes, and narrating it under that explanation would
be the most convincing way this module could be wrong. It is withheld with a
reason rather than dropped, because "these moved together and we cannot
explain it" is honest and "nothing was found" is not.

### What is reported and what is withheld

Everything tested comes back. `reported` is what a user may be shown;
`withheld` carries the same arithmetic plus the reason it did not qualify, so
an operator can tell a quiet month from a broken pipeline, and so a screen can
say "we looked" rather than implying nothing exists.

The mechanism *sentence* is separate from the correlation, and it is withheld
while `correlations.v1.yaml` is unsigned. A correlation is a statement about
measurements, like a lab value, and the app already shows those without a
verdict; an explanation of why two things move together is a clinical claim
and waits for a name and a registration number.
"""

from datetime import date, datetime, time, timezone
from statistics import fmean

from app.analytics import correlation_mechanisms as mechanisms
from app.analytics import sleep as sleep_model
from app.analytics.correlation_mechanisms import NEGATIVE, POSITIVE
from app.analytics.statistics import (
    benjamini_hochberg,
    effective_sample_size,
    lag1_autocorrelation,
    pearson,
    pearson_p_value,
)
from app.common.timeparse import parse_ts

MODEL_VERSION = "correlation-v2"

#: The window the screen offers. Ninety days of daily values is about the most
#: a person has and still small enough that a habit from three months ago is
#: not being compared with today.
WINDOW_DAYS = 90

#: Fewer paired days than this and the pair is not tested at all — so it also
#: does not count towards the correction applied to the pairs that were. Two
#: weeks is the point at which a weekday/weekend cycle has repeated twice.
MIN_PAIRED_DAYS = 14

#: Below this a correlation can be real and still not worth a sentence.
MIN_ABS_R = 0.3

#: The false discovery rate. 0.10 rather than 0.05 because this is an
#: exploratory screen whose findings lead to a conversation rather than to a
#: treatment: roughly one in ten reported patterns being spurious is the right
#: trade against reporting nothing for months.
FDR_Q = 0.10

#: Why a tested pair is not being shown.
TOO_FEW_DAYS = "too_few_days"
NOT_SIGNIFICANT = "not_significant"
WEAK = "weak"
DIRECTION_MISMATCH = "direction_mismatch"


# ── Building the daily series ────────────────────────────────────────────────

def _day(row: dict) -> date | None:
    stamp = parse_ts(row.get("recorded_at"))
    return stamp.date() if stamp else None


def daily_measurement_series(rows, measurement_type: str, *, total: bool) -> dict[date, float]:
    """One value per day from `health_measurements` rows.

    `total` is per metric and is not a preference: steps are a count of
    something that happened and must be summed, while a resting heart rate is
    a state and must be averaged. Summing two readings of a heart rate gives
    120 bpm and averaging two half-days of steps halves them.
    """
    buckets: dict[date, list[float]] = {}
    for row in rows:
        if row.get("measurement_type") != measurement_type:
            continue
        day = _day(row)
        if day is None:
            continue
        try:
            value = float(row["value"])
        except (TypeError, ValueError, KeyError):
            continue
        buckets.setdefault(day, []).append(value)
    return {
        day: (sum(values) if total else fmean(values))
        for day, values in buckets.items()
    }


def daily_entry_series(rows, field: str) -> dict[date, float]:
    """One total per day from a journal table's free-text `fields` blob.

    **An unreadable field is absent, not zero.** The phone's reader is
    `double.tryParse(fields[key] ?? '') ?? 0`, so a meal logged without its
    calories filled in counted as a zero-calorie day. Over ninety days of
    partly-filled meal logs that drags the series toward the floor on exactly
    the days the user was busy, which manufactures a correlation out of
    missing data. A day with nothing readable on it simply is not a day.
    """
    buckets: dict[date, float] = {}
    for row in rows:
        day = _day(row)
        if day is None:
            continue
        raw = (row.get("fields") or {}).get(field)
        try:
            value = float(str(raw).strip())
        except (TypeError, ValueError):
            continue
        buckets[day] = buckets.get(day, 0.0) + value
    return buckets


def daily_sleep_series(rows) -> dict[date, float]:
    """Hours asleep per night, through the one sleep implementation.

    Deliberately not `daily_measurement_series(rows, "sleep")`. A night is
    not a measurement type: it is `sleep`, `sleepLight`, `sleepDeep` and
    `sleepRem` records that frequently overlap, and `analytics/sleep.py`
    already knows that. Summing a `measurement_type` of "sleep" would be a
    second implementation and wrong three ways at once -- it misses a device
    that writes only stages, it double-counts two devices recording the same
    night, and a night that crossed midnight lands on the day it started
    rather than the day it ended.

    A night with no records is absent rather than zero. Nobody slept zero
    hours; the ring was on the charger.
    """
    readings = []
    for row in rows:
        if row.get("measurement_type") not in sleep_model.SLEEP_TYPES:
            continue
        stamp = parse_ts(row.get("recorded_at"))
        if stamp is None:
            continue
        try:
            value = float(row["value"])
        except (TypeError, ValueError, KeyError):
            continue
        readings.append(sleep_model.Reading(row["measurement_type"], value, stamp))

    if not readings:
        return {}

    # Every day a record could be attributed to, which is the day it ends on.
    nights = sorted({reading.end.date() for reading in readings})
    out: dict[date, float] = {}
    for night in nights:
        summary = sleep_model.summarize(
            readings, datetime.combine(night, time.min, tzinfo=timezone.utc)
        )
        if summary.total_hours > 0:
            out[night] = summary.total_hours
    return out



# ── The engine ───────────────────────────────────────────────────────────────

def _paired(first: dict[date, float], second: dict[date, float]):
    shared = sorted(set(first) & set(second))
    return shared, [first[d] for d in shared], [second[d] for d in shared]


def _matches_direction(expect: str, coefficient: float) -> bool:
    return (expect == POSITIVE and coefficient > 0) or (
        expect == NEGATIVE and coefficient < 0
    )


def correlate(series: dict[str, dict[date, float]], *, path=None) -> dict:
    """Every declared hypothesis, tested against this person's days.

    `series` maps a series id from `correlation_mechanisms.SERIES` to one value
    per day. Series the person has no data for are simply absent, and their
    pairs are never tested — which is correct and also keeps `m` honest: we
    did not test a hypothesis we had no data for, so it must not make the
    correction harsher for the ones we did.
    """
    candidates = []
    withheld = []

    for pair in mechanisms.testable_pairs(path):
        first, second = series.get(pair.first), series.get(pair.second)
        if not first or not second:
            continue

        shared, xs, ys = _paired(first, second)
        if len(shared) < MIN_PAIRED_DAYS:
            # Not entered into the hypothesis set: a pair we could not test
            # must not make the correction harsher for the ones we could.
            withheld.append(_row(pair, None, len(shared), None, None, TOO_FEW_DAYS))
            continue

        coefficient = pearson(xs, ys)
        if coefficient is None:
            withheld.append(_row(pair, None, len(shared), None, None, TOO_FEW_DAYS))
            continue

        effective = effective_sample_size(
            len(shared), lag1_autocorrelation(xs), lag1_autocorrelation(ys)
        )
        p_value = pearson_p_value(coefficient, effective)
        candidates.append((pair, coefficient, len(shared), effective, p_value))

    survived = benjamini_hochberg([c[4] for c in candidates], FDR_Q)

    reported = []
    for (pair, coefficient, paired, effective, p_value), passed in zip(candidates, survived):
        if not passed:
            reason = NOT_SIGNIFICANT
        elif abs(coefficient) < MIN_ABS_R:
            reason = WEAK
        elif not _matches_direction(pair.expect, coefficient):
            reason = DIRECTION_MISMATCH
        else:
            reason = None
        row = _row(pair, coefficient, paired, effective, p_value, reason, path=path)
        (withheld if reason else reported).append(row)

    reported.sort(key=lambda r: abs(r["coefficient"]), reverse=True)
    withheld.sort(key=lambda r: r["pair_id"])

    return {
        "model_version": MODEL_VERSION,
        "pairs_version": mechanisms.pairs_version(path),
        "window_days": WINDOW_DAYS,
        "fdr_q": FDR_Q,
        "min_paired_days": MIN_PAIRED_DAYS,
        "min_abs_r": MIN_ABS_R,
        # The hypothesis set actually tested, which is what the correction was
        # computed over. Reporting it is what lets a reader judge the rest.
        "tested": len(candidates),
        "reported": reported,
        "withheld": withheld,
    }


def _row(pair, coefficient, paired_days, effective, p_value, withheld_reason, path=None) -> dict:
    """One pair's result, with its explanation attached only if somebody signed
    it.

    `mechanism` is None while the catalog is unreviewed, and that is the whole
    difference an unsigned file makes here: the association still goes out, the
    reason it exists does not.
    """
    review = mechanisms.review_status(pair.id, path) if withheld_reason is None else None
    reviewed = bool(review and review.reviewed)
    return {
        "pair_id": pair.id,
        "first": pair.first,
        "second": pair.second,
        "coefficient": coefficient,
        "paired_days": paired_days,
        "effective_days": round(effective, 1) if effective is not None else None,
        "p_value": p_value,
        "expected_direction": pair.expect,
        "mechanism": pair.mechanism if reviewed else None,
        "citation": pair.citation if reviewed else None,
        "mechanism_reviewed": reviewed,
        "reviewer": review.reviewer if reviewed else None,
        "withheld": withheld_reason,
    }


# ── The seam: one implementation, two callers ────────────────────────────────
#
# The REST endpoint the screen reads and the tool the concierge calls both
# land here. If they ever became two implementations, a card would say one
# thing and a conversation another about the same two series, which is the
# defect this whole layer exists to close.

#: Which daily series comes from where. The `total` flag is per metric and not
#: a preference: steps are a count of something that happened, a resting heart
#: rate is a state. Summing two heart rates gives 120 bpm.
MEASUREMENT_SERIES = {
    "steps": ("steps", True),
    "active_minutes": ("activity", True),
    "resting_heart_rate": ("restingHeartRate", False),
    "hrv": ("hrv", False),
    "stress": ("stress", False),
}

#: Sleep is absent above on purpose: it has its own builder, because a night
#: is a union of overlapping stage records and not a measurement type.
SLEEP_SERIES = "sleep_duration"

#: The most journal rows one table may contribute to a window. A person
#: logging five meals a day for ninety days reaches 450.
ENTRY_ROW_CAP = 1000

#: series id -> (log table, field inside the free-text `fields` blob)
ENTRY_SERIES = {
    "food_energy": ("meals", "calories"),
    "protein": ("meals", "protein"),
    "hydration": ("hydration_logs", "amount"),
    "workout_minutes": ("workouts", "duration"),
}


def build_series(loader, user_id: str, days: int = WINDOW_DAYS) -> dict[str, dict[date, float]]:
    """Every daily series this person has, read through the one scoped loader.

    A series with no data is left out rather than included empty, so its pairs
    are never tested — which also keeps the correction honest, since a
    hypothesis we had no data for must not make the threshold harsher for the
    ones we did.
    """
    wanted = [name for name, _ in MEASUREMENT_SERIES.values()]
    wanted += sorted(sleep_model.SLEEP_TYPES)
    measurements = loader.daily_measurements(user_id, wanted, days=days)["items"]

    series: dict[str, dict[date, float]] = {}
    nights = daily_sleep_series(measurements)
    if nights:
        series[SLEEP_SERIES] = nights
    for series_id, (measurement_type, total) in MEASUREMENT_SERIES.items():
        built = daily_measurement_series(measurements, measurement_type, total=total)
        if built:
            series[series_id] = built

    # One read per log table rather than one per series: meals carry both the
    # energy and the protein.
    by_table: dict[str, list] = {}
    for table, _ in ENTRY_SERIES.values():
        if table not in by_table:
            # Bounded, and deliberately not "everything": PostgREST caps a
            # response anyway, and a silently truncated series would correlate
            # the first N rows and look entirely plausible. Ninety days of
            # meals, workouts or water logs is comfortably inside this.
            by_table[table] = loader.logs(
                user_id, table, days=days, limit=ENTRY_ROW_CAP
            )["items"]

    for series_id, (table, field) in ENTRY_SERIES.items():
        built = daily_entry_series(by_table[table], field)
        if built:
            series[series_id] = built

    return series


def for_user(loader, user_id: str, days: int = WINDOW_DAYS) -> dict:
    """This person's correlations, as both the endpoint and the tool see them."""
    result = correlate(build_series(loader, user_id, days=days))
    result["window_days"] = days
    return result
