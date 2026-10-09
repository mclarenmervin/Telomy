"""Which markers have actually moved, and which have merely wobbled.

This is the deterministic half of F5's draft producer: the rule that decides a
human should look at something. Per CLAUDE.md, alert *decisions* are testable
rules and only the *wording* is generative — so what fires is here, in ordinary
Python, and nothing in this module writes a sentence.

Two failure modes, and they pull against each other. Firing on noise fills a
clinician's queue with nothing and trains them to skim it; firing on nothing
means the queue is empty and the feature is theatre. The thresholds below are
v1 and the tests state what each one is protecting against, so tuning one later
is a decision rather than a guess.

Reuses `biomarker_selection`'s row filter rather than re-deriving it. Censored,
qualitative, undated and wrong-context rows are excluded for the reasons that
module explains at length, and a second copy of those rules would eventually
disagree with the first.
"""

from datetime import date, timedelta

from app.analytics.marker_trends import (
    FALLING,
    MIN_POINTS,
    MIN_RELATIVE_CHANGE,
    MIN_SPAN_DAYS,
    RISING,
    find_trends,
)

TODAY = date(2026, 10, 10)


def result(value, days_ago, *, marker="hba1c", unit="%", context="standard", **extra):
    row = {
        "biomarker_id": marker,
        "context": context,
        "result_type": "quantitative",
        "operator": "=",
        "value_canonical": value,
        "unit_canonical": unit,
        "collected_at": (TODAY - timedelta(days=days_ago)).isoformat(),
        "lab_name": "Test Labs",
    }
    row.update(extra)
    return row


def rising_series():
    """5.4 → 5.7 → 6.0 over eight months. An 11.1% rise, consistently upward,
    currently at its highest — just clear of MIN_RELATIVE_CHANGE."""
    return [result(5.4, 240), result(5.7, 120), result(6.0, 10)]


def trend_for(rows, marker="hba1c", as_of=TODAY):
    return next(
        (t for t in find_trends(rows, as_of=as_of) if t.biomarker_id == marker), None
    )


# ── What a trend is ──────────────────────────────────────────────────────────

def test_a_consistent_rise_is_a_trend():
    trend = trend_for(rising_series())

    assert trend is not None
    assert trend.direction == RISING
    assert trend.first.value_canonical == 5.4
    assert trend.latest.value_canonical == 6.0
    assert trend.unit == "%"


def test_a_consistent_fall_is_a_trend():
    rows = [result(14.8, 240), result(13.9, 120), result(12.4, 10),
            # Haemoglobin rather than HbA1c, so "falling" is a direction and
            # not a judgement — this module says which way, never whether that
            # is good or bad. That is the clinician's sentence to write.
            ]
    rows = [dict(r, biomarker_id="haemoglobin", unit_canonical="g/dL") for r in rows]
    trend = trend_for(rows, marker="haemoglobin")

    assert trend is not None
    assert trend.direction == FALLING


def test_the_relative_change_is_first_to_latest():
    trend = trend_for(rising_series())

    assert trend.relative_change == (6.0 - 5.4) / 5.4


def test_every_point_is_carried_for_the_clinician_to_see():
    """A clinician asked to put their registration number against a sentence
    needs the series, not the summary. This is what becomes the draft's
    `evidence`, and it is why the draft can be judged without the console
    querying anything else."""
    trend = trend_for(rising_series())

    assert [p.value_canonical for p in trend.points] == [5.4, 5.7, 6.0]
    assert [p.collected_at for p in trend.points] == sorted(
        p.collected_at for p in trend.points
    )


def test_the_span_is_recorded():
    trend = trend_for(rising_series())

    assert trend.span_days == 230


# ── Not firing on noise ──────────────────────────────────────────────────────

def test_two_points_are_not_a_trend():
    """Two results are a before and an after. Direction needs a third point, or
    every pair of consecutive panels becomes a clinician's problem."""
    assert trend_for([result(5.4, 240), result(5.9, 10)]) is None


def test_a_small_move_is_not_a_trend():
    """Assay imprecision on HbA1c is a couple of percent. A 3% rise is the
    machine, not the person."""
    assert trend_for([result(5.4, 240), result(5.5, 120), result(5.56, 10)]) is None


def test_the_threshold_is_the_one_the_module_publishes():
    """Pinned so that tuning MIN_RELATIVE_CHANGE cannot silently stop firing:
    just over the line fires, just under it does not."""
    base = 5.0
    over = base * (1 + MIN_RELATIVE_CHANGE + 0.01)
    under = base * (1 + MIN_RELATIVE_CHANGE - 0.01)

    assert trend_for([result(base, 240), result((base + over) / 2, 120),
                      result(over, 10)]) is not None
    assert trend_for([result(base, 240), result((base + under) / 2, 120),
                      result(under, 10)]) is None


def test_a_series_that_doubles_back_is_not_a_trend():
    """5.4 → 6.1 → 5.5 ends 1.9% above where it started and went both ways in
    between. There is nothing here for a clinician to act on, and flagging it
    would mean flagging ordinary variation."""
    assert trend_for([result(5.4, 240), result(6.1, 120), result(5.5, 10)]) is None


def test_a_rise_that_has_already_turned_around_is_not_a_trend():
    """5.4 → 6.2 → 5.95. Up 10% overall, but the latest result is a fall from
    the one before it. "It rose and is now at its highest" is a sentence worth a
    human's time; "it rose and is coming back down" is not."""
    assert trend_for([result(5.4, 240), result(6.2, 120), result(5.95, 10)]) is None


def test_three_results_in_one_week_are_not_a_trend():
    """A repeat panel to confirm an odd result is not eight months of movement.
    Without a minimum span, one anxious week of retesting reads as a trend."""
    assert trend_for([result(5.4, 6), result(5.6, 3), result(5.9, 1)]) is None


def test_the_minimum_span_is_the_one_the_module_publishes():
    rows = [result(5.0, MIN_SPAN_DAYS + 2), result(5.3, MIN_SPAN_DAYS // 2),
            result(5.6, 1)]

    assert trend_for(rows) is not None
    assert trend_for([result(5.0, MIN_SPAN_DAYS - 2), result(5.3, 10),
                      result(5.6, 1)]) is None


def test_the_minimum_point_count_is_the_one_the_module_publishes():
    rows = [result(5.0 + 0.3 * i, 240 - 115 * i) for i in range(MIN_POINTS)]

    assert trend_for(rows) is not None
    assert trend_for(rows[1:]) is None


# ── Rows that must not reach the arithmetic ──────────────────────────────────
#
# Same four as biomarker_selection, for the same reasons, and tested here too
# because this module has its own path to them.

def test_a_censored_result_cannot_be_a_point_in_a_trend():
    """`<0.01` is not 0.01. The true value is unknown, so it cannot be a term in
    a change calculation — and dropping it leaves two points, which is not a
    trend either. It may still escalate; that path does not come through here."""
    rows = rising_series()
    rows[1] = dict(rows[1], operator="<", value_canonical=5.6)

    assert trend_for(rows) is None


def test_a_qualitative_result_cannot_be_a_point_in_a_trend():
    rows = rising_series()
    rows[1] = dict(rows[1], result_type="qualitative", value_canonical=None,
                   value_text="Positive")

    assert trend_for(rows) is None


def test_an_undated_result_cannot_be_a_point_in_a_trend():
    """`collected_at` is null while the confirmation UI is still asking which of
    the three dates on the PDF it is. An undated point cannot be ordered, and a
    trend of unordered points is not a trend."""
    rows = rising_series()
    rows[1] = dict(rows[1], collected_at=None)

    assert trend_for(rows) is None


def test_fasting_and_post_prandial_glucose_are_not_one_series():
    """The catalog maps both labels onto `glucose_fasting` and only `context`
    separates them. Mixing them produces a sawtooth that reads as a dramatic
    trend in whichever direction the last draw happened to be."""
    rows = [
        result(88, 240, marker="glucose_fasting", unit="mg/dL", context="fasting"),
        result(150, 200, marker="glucose_fasting", unit="mg/dL",
               context="post_prandial"),
        result(90, 120, marker="glucose_fasting", unit="mg/dL", context="fasting"),
        result(165, 80, marker="glucose_fasting", unit="mg/dL",
               context="post_prandial"),
        result(92, 10, marker="glucose_fasting", unit="mg/dL", context="fasting"),
    ]

    # The fasting series is 88 → 90 → 92: a 4.5% rise, under the threshold.
    # Read as one series it would be a wild oscillation ending on a fall.
    assert trend_for(rows, marker="glucose_fasting") is None


def test_each_context_trends_on_its_own():
    rows = [
        result(88, 240, marker="glucose_fasting", unit="mg/dL", context="fasting"),
        result(96, 120, marker="glucose_fasting", unit="mg/dL", context="fasting"),
        result(104, 10, marker="glucose_fasting", unit="mg/dL", context="fasting"),
        result(150, 200, marker="glucose_fasting", unit="mg/dL",
               context="post_prandial"),
    ]
    trend = trend_for(rows, marker="glucose_fasting")

    assert trend is not None
    assert trend.context == "fasting"
    assert len(trend.points) == 3


def test_two_results_on_one_day_do_not_both_count():
    """A lab reissuing a corrected report gives two rows with one collection
    date. Counting both inflates the point count and can satisfy MIN_POINTS with
    two real draws."""
    rows = [result(5.4, 240), result(5.7, 120), result(5.72, 120), result(6.0, 10)]
    trend = trend_for(rows)

    assert trend is not None
    assert len(trend.points) == 3


# ── Dates and windows ────────────────────────────────────────────────────────

def test_results_after_as_of_are_not_considered():
    """Asking what was trending in June must not reach for a panel drawn in
    September — the same rule `scores._results_up_to` applies to biological
    age, for the same reason."""
    rows = rising_series()
    june = date(2026, 6, 1)

    assert trend_for(rows, as_of=june) is None


def test_a_trend_is_dated_to_its_latest_draw_not_to_today():
    """The draft says something about a blood draw, not about the day a sweep
    happened to run. Dating it to today would put a June panel on October's
    chart and re-draft the same trend every night."""
    trend = trend_for(rising_series())

    assert trend.as_of == TODAY - timedelta(days=10)


def test_an_old_series_is_outside_the_window():
    """Five-year-old results populate a chart. They are not a reason to put
    something in front of a clinician today."""
    rows = [result(5.4, 2000), result(5.6, 1800), result(5.9, 1600)]

    assert trend_for(rows) is None


def test_a_backfilled_history_upload_does_not_produce_a_trend():
    """The plan's rule: documents older than N days are ingested as history —
    they populate trends but generate no alerts and no drafts. A new user
    uploading five years of reports in one sitting must not create five years of
    clinician drafts.

    Tested by the collection date of the *latest* point, which is how
    `extraction.ingest` decides `is_history` in the first place. Older points
    being historical is exactly normal — that is what history is for."""
    rows = [result(5.4, 1200), result(5.6, 1000), result(5.9, 800)]

    assert trend_for(rows) is None


def test_history_feeds_a_trend_whose_latest_point_is_current():
    """The other half, and the one a naive "skip history" would break: four
    years of backfill plus a panel from last week is precisely when a trend
    becomes visible for the first time."""
    rows = [result(5.0, 700), result(5.3, 450), result(5.6, 200), result(5.9, 5)]
    trend = trend_for(rows)

    assert trend is not None
    assert len(trend.points) == 4


# ── Shapes that must not crash ───────────────────────────────────────────────

def test_no_rows_is_no_trends():
    assert find_trends([], as_of=TODAY) == []


def test_none_rows_is_no_trends():
    assert find_trends(None, as_of=TODAY) == []


def test_a_zero_first_value_does_not_divide_by_zero():
    """A genuine 0 is rare but real on some markers, and a relative change from
    zero is undefined rather than infinite."""
    rows = [result(0.0, 240), result(0.2, 120), result(0.4, 10)]

    assert trend_for(rows) is None


def test_an_unknown_marker_still_trends():
    """Unlike biological age, this is not restricted to a fitted marker set.
    Any marker the catalog maps can move, and the catalog is consulted for
    critical bounds at the draft layer, not here."""
    rows = [result(100, 240, marker="ferritin", unit="ng/mL"),
            result(130, 120, marker="ferritin", unit="ng/mL"),
            result(160, 10, marker="ferritin", unit="ng/mL")]

    assert trend_for(rows, marker="ferritin") is not None


def test_several_markers_trend_independently():
    rows = rising_series() + [
        result(100, 240, marker="ferritin", unit="ng/mL"),
        result(130, 120, marker="ferritin", unit="ng/mL"),
        result(160, 10, marker="ferritin", unit="ng/mL"),
    ]
    trends = find_trends(rows, as_of=TODAY)

    assert {t.biomarker_id for t in trends} == {"hba1c", "ferritin"}


def test_trends_come_back_in_a_stable_order():
    """A draft producer that enumerated these in dictionary order would create
    drafts in a different order on each run, which makes a queue impossible to
    reason about and a test impossible to write."""
    rows = rising_series() + [
        result(100, 240, marker="ferritin", unit="ng/mL"),
        result(130, 120, marker="ferritin", unit="ng/mL"),
        result(160, 10, marker="ferritin", unit="ng/mL"),
    ]

    assert [t.biomarker_id for t in find_trends(rows, as_of=TODAY)] == [
        t.biomarker_id for t in find_trends(list(reversed(rows)), as_of=TODAY)
    ]
