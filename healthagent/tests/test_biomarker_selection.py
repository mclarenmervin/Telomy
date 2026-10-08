"""Choosing which lab results a biological age is computed from.

This is the part most likely to be quietly wrong, so the fixtures here are
deliberately messy. A panel with every marker present, all mid-range and one
collection date would exercise almost none of this.

Four kinds of row must never reach the arithmetic, and each of them looks
perfectly fine in a SQL prompt:

* a censored result -- `<0.01` carries operator '<' and the true value is unknown
* a qualitative result -- `value_canonical` is NULL and `value_text` is set
* a result with no collection date -- nullable while the confirmation UI is
  still asking, and a biological age needs a date to belong to
* the wrong one of two legitimate duplicates -- fasting and post-prandial
  glucose are one marker and two results, separated by `context`
"""

from datetime import date, timedelta

from app.analytics.biological_age import PHENOAGE_MARKERS
from app.analytics.biomarker_selection import (
    PANEL_WINDOW_DAYS,
    select_panel,
)

ANCHOR = date(2026, 10, 1)

# Canonical-unit values for a complete, plausible panel.
COMPLETE = {
    "albumin": 4.2,
    "creatinine": 0.96,
    "glucose_fasting": 97.0,
    "hs_crp": 1.5,
    "lymphocyte_percent": 28.0,
    "mcv": 90.0,
    "rdw": 13.5,
    "alkaline_phosphatase": 75.0,
    "wbc": 6.8,
}


def row(
    biomarker_id,
    value=1.0,
    collected_at=ANCHOR,
    *,
    context="standard",
    operator="=",
    result_type="quantitative",
    value_text=None,
    unit="x",
):
    return {
        "biomarker_id": biomarker_id,
        "value_canonical": value,
        "unit_canonical": unit,
        "value_text": value_text,
        "collected_at": None if collected_at is None else f"{collected_at}T08:30:00+00:00",
        "context": context,
        "operator": operator,
        "result_type": result_type,
        "lab_name": "Acme Diagnostics",
    }


def complete_panel(collected_at=ANCHOR, **overrides):
    values = dict(COMPLETE)
    values.update(overrides)
    return [row(marker, value, collected_at) for marker, value in values.items()]


# ── The happy path, and what "one panel" means ───────────────────────────────

def test_a_complete_panel_on_one_date_is_selected_whole():
    panel = select_panel(complete_panel())

    assert panel.as_of == ANCHOR
    assert panel.canonical == COMPLETE
    assert panel.complete is True


def test_panels_drawn_days_apart_still_count_as_one_assessment():
    """Real labs split a CBC and a metabolic panel across separate reports and
    often separate dates. Requiring one exact collection date would mean almost
    nobody ever gets a number."""
    cbc = [row(m, COMPLETE[m], date(2026, 10, 1))
           for m in ("mcv", "rdw", "wbc", "lymphocyte_percent")]
    cmp_ = [row(m, COMPLETE[m], date(2026, 9, 20))
            for m in ("albumin", "creatinine", "glucose_fasting",
                      "alkaline_phosphatase", "hs_crp")]

    panel = select_panel(cbc + cmp_)

    assert panel.complete
    assert panel.as_of == date(2026, 10, 1)
    assert panel.span_days == 11


def test_results_further_apart_than_the_window_are_not_one_panel():
    """A 2024 CBC and a 2026 metabolic panel describe two different bodies."""
    recent = [row(m, COMPLETE[m], ANCHOR) for m in ("mcv", "rdw", "wbc")]
    ancient = [row(m, COMPLETE[m], date(2024, 1, 1))
               for m in PHENOAGE_MARKERS if m not in ("mcv", "rdw", "wbc")]

    panel = select_panel(recent + ancient)

    assert not panel.complete
    assert "albumin" in panel.missing


def test_the_most_recent_complete_panel_wins_over_a_newer_fragment():
    """Uploading a single CRP today must not hide the complete panel from last
    month. The biological age then belongs to that panel's collection date, not
    to today."""
    fragment = [row("hs_crp", 0.9, date(2026, 10, 1))]
    full = complete_panel(date(2026, 6, 15))

    panel = select_panel(fragment + full)

    assert panel.complete
    assert panel.as_of == date(2026, 6, 15)
    assert panel.canonical["hs_crp"] == COMPLETE["hs_crp"]


def test_the_edge_of_the_window_is_inside_it_and_a_day_further_is_not():
    edge = ANCHOR - timedelta(days=PANEL_WINDOW_DAYS)
    rows = [r for r in complete_panel() if r["biomarker_id"] != "albumin"]

    assert select_panel(rows + [row("albumin", 4.2, edge)]).complete
    assert not select_panel(
        rows + [row("albumin", 4.2, edge - timedelta(days=1))]).complete


# ── Censored values (plan: excluded from biological age) ─────────────────────

def test_a_censored_value_is_excluded_and_says_why():
    """`<0.01` means the lab could not measure past that bound. The true value
    is unknown, so it may be displayed and may escalate, but it must never
    become a term in an arithmetic model."""
    rows = complete_panel()
    rows = [r for r in rows if r["biomarker_id"] != "hs_crp"]
    rows.append(row("hs_crp", 0.01, ANCHOR, operator="<"))

    panel = select_panel(rows)

    assert not panel.complete
    assert "hs_crp" in panel.missing
    assert panel.notes["hs_crp"] == "censored"


def test_an_upper_censored_value_is_excluded_too():
    rows = [r for r in complete_panel() if r["biomarker_id"] != "wbc"]
    rows.append(row("wbc", 500.0, ANCHOR, operator=">"))

    assert select_panel(rows).notes["wbc"] == "censored"


def test_a_censored_duplicate_does_not_hide_a_measured_one():
    """Both rows are legitimate -- a repeat draw where the assay saturated once.
    The measured one must still be used."""
    rows = [r for r in complete_panel() if r["biomarker_id"] != "hs_crp"]
    rows.append(row("hs_crp", 0.01, date(2026, 10, 1), operator="<"))
    rows.append(row("hs_crp", 1.5, date(2026, 9, 28)))

    panel = select_panel(rows)

    assert panel.complete
    assert panel.canonical["hs_crp"] == 1.5


# ── Qualitative results ──────────────────────────────────────────────────────

def test_a_qualitative_result_never_reaches_arithmetic():
    """`value_canonical` is NULL and `value_text` is 'Positive'. Letting a None
    through is a TypeError at best and a zero at worst."""
    rows = [r for r in complete_panel() if r["biomarker_id"] != "albumin"]
    rows.append(row("albumin", None, ANCHOR, result_type="qualitative",
                    value_text="Trace"))

    panel = select_panel(rows)

    assert "albumin" in panel.missing
    assert panel.notes["albumin"] == "qualitative"


def test_a_quantitative_row_with_a_null_value_is_also_refused():
    """Belt and braces: the table's own constraint should prevent this, but a
    None reaching a multiplication is not a failure mode worth risking."""
    rows = [r for r in complete_panel() if r["biomarker_id"] != "mcv"]
    rows.append(row("mcv", None, ANCHOR))

    assert "mcv" in select_panel(rows).missing


# ── Collection dates ─────────────────────────────────────────────────────────

def test_a_result_with_no_collection_date_is_refused_not_dated_today():
    """`collected_at` is null while the confirmation UI is still asking. A
    biological age needs a date to belong to, and defaulting to today would put
    an undated 2019 panel on this week's chart."""
    rows = [r for r in complete_panel() if r["biomarker_id"] != "rdw"]
    rows.append(row("rdw", 13.5, None))

    panel = select_panel(rows)

    assert "rdw" in panel.missing
    assert panel.notes["rdw"] == "no_collection_date"


def test_an_entirely_undated_set_produces_no_panel_at_all():
    panel = select_panel([row(m, COMPLETE[m], None) for m in PHENOAGE_MARKERS])

    assert panel.as_of is None
    assert not panel.complete


def test_no_rows_at_all_is_an_empty_panel_rather_than_an_error():
    panel = select_panel([])

    assert panel.as_of is None
    assert panel.canonical == {}
    assert set(panel.missing) == set(PHENOAGE_MARKERS)


# ── The same marker twice, legitimately ──────────────────────────────────────

def test_fasting_glucose_is_preferred_over_an_undesignated_one():
    """One marker, two results, separated by context. PhenoAge wants fasting."""
    rows = [r for r in complete_panel() if r["biomarker_id"] != "glucose_fasting"]
    rows.append(row("glucose_fasting", 140.0, ANCHOR, context="standard"))
    rows.append(row("glucose_fasting", 92.0, ANCHOR, context="fasting"))

    assert select_panel(rows).canonical["glucose_fasting"] == 92.0


def test_a_post_prandial_glucose_is_never_used_even_when_it_is_the_only_one():
    """The catalog maps post-prandial and random glucose labels onto the same
    biomarker_id, so the context is the only thing keeping a two-hour value out
    of a model fitted on fasting glucose. Averaging them, or taking whichever
    sorts first, is how a well-controlled person ends up looking diabetic."""
    rows = [r for r in complete_panel() if r["biomarker_id"] != "glucose_fasting"]
    rows.append(row("glucose_fasting", 168.0, ANCHOR, context="post_prandial"))

    panel = select_panel(rows)

    assert "glucose_fasting" in panel.missing
    assert panel.notes["glucose_fasting"] == "wrong_context"


def test_a_random_glucose_is_refused_for_the_same_reason():
    rows = [r for r in complete_panel() if r["biomarker_id"] != "glucose_fasting"]
    rows.append(row("glucose_fasting", 155.0, ANCHOR, context="random"))

    assert select_panel(rows).notes["glucose_fasting"] == "wrong_context"


def test_duplicates_are_never_averaged():
    """Two draws a week apart are two measurements, not one with error bars.
    The nearer to the anchor is the one that describes the panel."""
    rows = [r for r in complete_panel() if r["biomarker_id"] != "wbc"]
    rows.append(row("wbc", 5.0, date(2026, 9, 25)))
    rows.append(row("wbc", 9.0, date(2026, 10, 1)))

    assert select_panel(rows).canonical["wbc"] == 9.0


# ── Provenance ───────────────────────────────────────────────────────────────

def test_the_panel_records_what_it_selected_so_a_score_can_be_explained():
    panel = select_panel(complete_panel())

    albumin = panel.selected["albumin"]

    assert albumin.collected_at == ANCHOR
    assert albumin.unit_canonical == "x"
    assert albumin.context == "standard"
    assert albumin.value_canonical == 4.2


def test_the_fingerprint_is_stable_across_row_order():
    """This feeds `inputs_hash`. Reordering rows must not look like the user's
    data changed."""
    rows = complete_panel()

    assert select_panel(rows).fingerprint() == select_panel(
        list(reversed(rows))).fingerprint()


def test_the_fingerprint_changes_when_a_value_does():
    assert select_panel(complete_panel()).fingerprint() != select_panel(
        complete_panel(rdw=14.1)).fingerprint()
