"""Correlations v2: which patterns a person is allowed to be shown.

The version this replaces tested forty-five pairs with no correction, accepted
five matching days, and labelled the result "Strong pattern". Every test here
is a way that was wrong.
"""

from datetime import date, timedelta

import pytest

from app.analytics import correlations
from app.analytics.correlations import (
    DIRECTION_MISMATCH,
    MIN_ABS_R,
    MIN_PAIRED_DAYS,
    NOT_SIGNIFICANT,
    TOO_FEW_DAYS,
    WEAK,
    correlate,
    daily_measurement_series,
    daily_entry_series,
)

START = date(2026, 7, 1)


def days(n: int) -> list[date]:
    return [START + timedelta(days=i) for i in range(n)]


def series(values: list[float], offset: int = 0) -> dict[date, float]:
    return {START + timedelta(days=i + offset): v for i, v in enumerate(values)}


def wobble(n: int, scale: float = 1.0, phase: float = 0.0) -> list[float]:
    """A series with enough independent movement to carry evidence.

    Deliberately not a straight line: a monotone ramp is perfectly
    autocorrelated, and the effective-sample-size adjustment would -- correctly
    -- throw almost all of it away.
    """
    pattern = [0, 3, 1, 4, 2, 5, 1, 3, 0, 4, 2, 5, 3, 1]
    return [scale * (pattern[(i + int(phase)) % len(pattern)]) for i in range(n)]


# ── Building the daily series ────────────────────────────────────────────────

def test_a_measurement_series_averages_within_a_day():
    rows = [
        {"measurement_type": "hrv", "value": 40, "recorded_at": "2026-07-01T06:00:00+00:00"},
        {"measurement_type": "hrv", "value": 60, "recorded_at": "2026-07-01T22:00:00+00:00"},
    ]
    assert daily_measurement_series(rows, "hrv", total=False) == {date(2026, 7, 1): 50.0}


def test_a_measurement_series_totals_where_totalling_is_right():
    """Steps are a count of a thing that happened; averaging two half-days
    would halve them."""
    rows = [
        {"measurement_type": "steps", "value": 4000, "recorded_at": "2026-07-01T09:00:00+00:00"},
        {"measurement_type": "steps", "value": 2000, "recorded_at": "2026-07-01T18:00:00+00:00"},
    ]
    assert daily_measurement_series(rows, "steps", total=True) == {date(2026, 7, 1): 6000.0}


def test_an_unparseable_entry_field_is_absent_rather_than_zero():
    """The phone's reader returns 0 for an empty field, so a meal logged with
    no calories recorded counted as a zero-calorie day and dragged the series
    toward the floor -- manufacturing a correlation out of missing data."""
    rows = [
        {"fields": {"calories": ""}, "recorded_at": "2026-07-01T09:00:00+00:00"},
        {"fields": {"calories": "600"}, "recorded_at": "2026-07-02T09:00:00+00:00"},
    ]
    assert daily_entry_series(rows, "calories") == {date(2026, 7, 2): 600.0}


def test_entries_on_one_day_are_summed():
    rows = [
        {"fields": {"amount": "500"}, "recorded_at": "2026-07-01T09:00:00+00:00"},
        {"fields": {"amount": "250"}, "recorded_at": "2026-07-01T15:00:00+00:00"},
    ]
    assert daily_entry_series(rows, "amount") == {date(2026, 7, 1): 750.0}


def test_a_day_whose_fields_are_all_unreadable_is_absent():
    rows = [{"fields": {"calories": "a lot"}, "recorded_at": "2026-07-01T09:00:00+00:00"}]
    assert daily_entry_series(rows, "calories") == {}


# ── Only declared pairs are tested ───────────────────────────────────────────

def test_an_undeclared_pair_is_never_tested_however_strong_it_is():
    """A clean correlation with no named mechanism is noise with a p-value."""
    straight = wobble(60)
    result = correlate({
        "protein": series(straight),
        "steps": series(straight),
    })
    assert result["tested"] == 0
    assert result["reported"] == []


def test_a_tautological_pair_is_never_tested():
    """Steps and active minutes are the same accelerometer stream. Reporting
    the correlation would describe the device, not the person."""
    straight = wobble(60)
    result = correlate({
        "steps": series(straight),
        "active_minutes": series(straight),
    })
    assert result["tested"] == 0


def test_stress_against_hrv_is_never_tested():
    """The ring computes the stress score FROM heart rate variability. This is
    the pair a plain allowlist would have let through."""
    rising = wobble(60)
    result = correlate({
        "hrv": series(rising),
        "stress": series([-v for v in rising]),
    })
    assert result["tested"] == 0
    assert result["reported"] == []


# ── Significance ─────────────────────────────────────────────────────────────

def test_five_matching_days_are_not_enough():
    """The number the old screen accepted."""
    result = correlate({
        "hrv": series([10, 20, 30, 40, 50]),
        "sleep_duration": series([1, 2, 3, 4, 5]),
    })
    assert result["reported"] == []
    assert result["withheld"][0]["withheld"] == TOO_FEW_DAYS


def test_a_pair_short_of_the_floor_is_not_counted_as_a_test():
    """It never entered the hypothesis set, so it must not inflate the
    correction applied to the pairs that did."""
    short = correlate({
        "hrv": series(wobble(MIN_PAIRED_DAYS - 1)),
        "sleep_duration": series(wobble(MIN_PAIRED_DAYS - 1)),
    })
    assert short["tested"] == 0


def test_a_real_relationship_over_enough_days_is_reported():
    movement = wobble(60)
    result = correlate({
        "hrv": series(movement),
        "sleep_duration": series([v * 1.2 + 4 for v in movement]),
    })
    assert [r["pair_id"] for r in result["reported"]] == ["hrv__sleep_duration"]
    assert result["reported"][0]["coefficient"] == pytest.approx(1.0)


def test_a_weak_but_significant_correlation_is_withheld():
    """Significance is about whether it is there; the effect-size floor is
    about whether it is worth a sentence."""
    import random

    rng = random.Random(7)
    xs, ys = [], []
    for _ in range(400):
        x = rng.gauss(0, 1)
        xs.append(x)
        ys.append(0.2 * x + rng.gauss(0, 1))
    result = correlate({"hrv": series(xs), "sleep_duration": series(ys)})
    assert result["reported"] == []
    assert result["withheld"][0]["withheld"] in (WEAK, NOT_SIGNIFICANT)


def test_pure_noise_is_not_reported():
    import random

    rng = random.Random(11)
    n = 60
    result = correlate({
        "hrv": series([rng.gauss(0, 1) for _ in range(n)]),
        "sleep_duration": series([rng.gauss(0, 1) for _ in range(n)]),
        "resting_heart_rate": series([rng.gauss(0, 1) for _ in range(n)]),
        "hydration": series([rng.gauss(0, 1) for _ in range(n)]),
        "steps": series([rng.gauss(0, 1) for _ in range(n)]),
    })
    assert result["reported"] == []


# ── Plausibility: the direction ──────────────────────────────────────────────

def test_a_correlation_running_against_its_mechanism_is_refused():
    """The other half of the gate. HRV and resting heart rate are predicted to
    move oppositely; a clean positive correlation is a confounder, and
    reporting it under that mechanism would be the most convincing way to be
    wrong."""
    movement = wobble(60)
    result = correlate({
        "hrv": series(movement),
        "resting_heart_rate": series([v * 2 + 50 for v in movement]),
    })
    assert result["reported"] == []
    assert result["withheld"][0]["withheld"] == DIRECTION_MISMATCH


def test_the_same_pair_in_the_predicted_direction_is_reported():
    movement = wobble(60)
    result = correlate({
        "hrv": series(movement),
        "resting_heart_rate": series([-v * 2 + 50 for v in movement]),
    })
    assert [r["pair_id"] for r in result["reported"]] == ["hrv__resting_heart_rate"]


# ── What a reported correlation carries ──────────────────────────────────────

def test_an_unreviewed_mechanism_is_withheld_but_the_association_is_not():
    """The catalog ships unreviewed. A correlation is a statement about
    measurements, like a lab value, so it may be reported; the sentence
    explaining why is a clinical claim and waits for a signature."""
    movement = wobble(60)
    result = correlate({
        "hrv": series(movement),
        "sleep_duration": series([v * 1.2 for v in movement]),
    })
    reported = result["reported"][0]
    assert reported["mechanism"] is None
    assert reported["mechanism_reviewed"] is False


def test_a_reported_correlation_carries_its_own_sample_size():
    movement = wobble(60)
    result = correlate({
        "hrv": series(movement),
        "sleep_duration": series([v * 1.2 for v in movement]),
    })
    reported = result["reported"][0]
    assert reported["paired_days"] == 60
    # Fewer than the days observed, because consecutive days are not
    # independent observations.
    assert reported["effective_days"] <= reported["paired_days"]


def test_only_days_both_series_have_are_paired():
    result = correlate({
        "hrv": series(wobble(60)),
        "sleep_duration": series(wobble(30), offset=30),
    })
    tested = (result["reported"] + result["withheld"])[0]
    assert tested["paired_days"] == 30


def test_the_result_names_the_model_and_the_catalog_version():
    """A number the user saw must be traceable to what produced it."""
    result = correlate({})
    assert result["model_version"] == correlations.MODEL_VERSION
    assert result["pairs_version"]


def test_no_series_at_all_is_an_empty_result_rather_than_a_failure():
    result = correlate({})
    assert result["reported"] == []
    assert result["tested"] == 0


# ── The two corrections, each shown refusing something ───────────────────────

def exact_correlation(n: int, r: float, seed: int = 3):
    """Two white-noise series whose Pearson correlation is exactly `r`.

    Constructed rather than sampled, so the test pins a decision boundary
    instead of a lucky seed. The second series is orthogonalised against the
    first and then recombined at the requested angle.
    """
    import math
    import random
    from statistics import fmean

    rng = random.Random(seed)
    xs = [rng.gauss(0, 1) for _ in range(n)]
    zs = [rng.gauss(0, 1) for _ in range(n)]
    x_mean, z_mean = fmean(xs), fmean(zs)
    xs = [v - x_mean for v in xs]
    zs = [v - z_mean for v in zs]

    dot = sum(a * b for a, b in zip(xs, zs))
    xx = sum(a * a for a in xs)
    zs = [b - dot / xx * a for a, b in zip(xs, zs)]

    x_norm = math.sqrt(xx)
    z_norm = math.sqrt(sum(b * b for b in zs))
    xs = [a / x_norm for a in xs]
    zs = [b / z_norm for b in zs]
    return xs, [r * a + math.sqrt(1 - r * r) * b for a, b in zip(xs, zs)]


def random_walk(rng, n: int, start: float = 50.0, step: float = 1.0) -> list[float]:
    value, out = start, []
    for _ in range(n):
        value += rng.gauss(0, step)
        out.append(value)
    return out


def test_two_random_walks_are_not_a_pattern():
    """The case the autocorrelation adjustment exists for, and the one the
    old screen was most exposed to.

    Two independent random walks produce large, clean-looking correlations:
    over 200 trials of 60 days, 141 of them clear p < 0.05 with |r| >= 0.3 when
    the day count is used as the sample size, and 7 do once the lag-1
    adjustment is applied. Resting heart rate and HRV are both much closer to
    a random walk than to independent daily draws.

    Seed 1 gives r = -0.85 at p = 9.6e-18 on 60 raw days — a "Strong pattern"
    by any label the old screen could print — and p = 0.24 on the 3.5
    independent observations those 60 days actually carry. It also runs in the
    direction the mechanism predicts, so nothing else in the engine would stop
    it.
    """
    import random

    rng = random.Random(1)
    first, second = random_walk(rng, 60), random_walk(rng, 60)
    result = correlate({
        "hrv": series(first),
        "resting_heart_rate": series(second),
    })

    assert result["reported"] == []
    withheld = result["withheld"][0]
    assert withheld["withheld"] == NOT_SIGNIFICANT
    assert abs(withheld["coefficient"]) > 0.8
    assert withheld["effective_days"] < 10


def test_one_marginal_pair_among_many_does_not_survive_the_correction(tmp_path):
    """A p of 0.03 is significant on its own and is exactly what you expect
    to see once when twenty hypotheses are tested at once.

    Twenty declared pairs, nineteen of them uncorrelated noise and one
    constructed at r = 0.343 — which is p = 0.030 over 40 independent days,
    above the effect-size floor, and in the predicted direction. Everything
    except the correction says report it.
    """
    import itertools

    import yaml

    from app.analytics import correlation_mechanisms as mech

    names = sorted(mech.SERIES)
    chosen = list(itertools.combinations(names, 2))[:20]
    catalog = {
        "version": "correlations.test",
        "pairs": [
            {
                "id": f"{a}__{b}",
                "first": a,
                "second": b,
                "verdict": "mechanism",
                "expect": "positive",
                "mechanism": "A mechanism.",
                "citation": "A citation.",
            }
            for a, b in chosen
        ],
        "clinical_review": {"pairs": []},
    }
    path = tmp_path / "correlations.test.yaml"
    path.write_text(yaml.safe_dump(catalog))
    mech.load_pairs.cache_clear()
    mech.pair_for.cache_clear()
    mech.review_status.cache_clear()

    marked_first, marked_second = chosen[0]
    xs, ys = exact_correlation(40, 0.343)
    import random

    rng = random.Random(99)
    built = {
        name: series([rng.gauss(0, 1) for _ in range(40)])
        for name in names
    }
    built[marked_first] = series(xs)
    built[marked_second] = series(ys)

    result = correlate(built, path=path)
    mech.load_pairs.cache_clear()
    mech.pair_for.cache_clear()
    mech.review_status.cache_clear()

    assert result["tested"] == 20
    marked = next(
        row
        for row in result["reported"] + result["withheld"]
        if row["pair_id"] == f"{marked_first}__{marked_second}"
    )
    assert marked["p_value"] == pytest.approx(0.030, abs=0.002)
    assert abs(marked["coefficient"]) > MIN_ABS_R
    assert marked["withheld"] == NOT_SIGNIFICANT
