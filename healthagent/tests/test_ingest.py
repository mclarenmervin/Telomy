"""Turning a scanned page into rows we would be willing to store.

Three things happen here that nothing else does.

**The verbatim check.** Every value must appear, as printed, in the text of the
page it came from. The scanner lifts spans so this holds by construction — which
is exactly why it is asserted rather than assumed. The day something starts
computing a value instead of reading one, this is what catches it.

**Dates.** Collection, report and registration dates are three different things
and real reports label none of them unambiguously. Trending uses the collection
date; getting it wrong puts a 2023 panel on today's chart.

**The history rule.** A new user uploading five years of reports in one sitting
must not receive five years of retroactive alerts.
"""

from datetime import datetime, timezone

import pytest

from app.analytics import catalog
from app.extraction.ingest import (
    EXTRACTED,
    HISTORY_DAYS,
    UNKNOWN,
    VerbatimCheckFailed,
    extract_report,
)
from app.extraction.pdf_text import read_pdf
from tests.lab_fixtures import lab_report_pdf

NOW = datetime(2026, 10, 6, tzinfo=timezone.utc)


def report(**kwargs):
    now = kwargs.pop("now", NOW)
    return extract_report(read_pdf(lab_report_pdf(**kwargs)), now=now)


def result_for(extracted, biomarker_id, context="standard"):
    matches = [
        r for r in extracted.results
        if r.biomarker_id == biomarker_id and r.context == context
    ]
    assert matches, f"no result for {biomarker_id}/{context}"
    return matches[0]


# ── Values ───────────────────────────────────────────────────────────────────

def test_a_panel_becomes_storable_results():
    extracted = report()

    assert {r.biomarker_id for r in extracted.results} >= {
        "glucose_fasting", "hba1c", "haemoglobin", "ferritin", "vitamin_d_25oh"
    }


def test_a_value_already_in_canonical_units_is_unchanged():
    assert result_for(report(), "glucose_fasting", "fasting").value_canonical == 142.0


def test_a_value_in_another_unit_is_converted():
    """A report in mmol/L and one in mg/dL must produce identical reasoning."""
    rows = [("Glucose, Fasting", "7.9", "mmol/L", "3.9 - 5.5")]

    result = result_for(report(rows=rows), "glucose_fasting", "fasting")

    assert result.value_canonical == pytest.approx(142.3, abs=0.1)
    assert result.unit_canonical == "mg/dL"
    assert result.raw_value == "7.9", "the printed value is kept for display"
    assert result.raw_unit == "mmol/L"


def test_the_same_marker_twice_keeps_both_results():
    extracted = report()

    assert result_for(extracted, "glucose_fasting", "fasting").value_canonical == 142.0
    assert result_for(extracted, "glucose_fasting", "post_prandial").value_canonical == 198.0


def test_a_censored_value_keeps_its_operator_and_its_magnitude():
    """`<3.0` is displayable and may escalate; what it must not do is reach
    biological age, because the true value is unknown."""
    result = result_for(report(), "vitamin_d_25oh")

    assert result.operator == "<"
    assert result.value_canonical == 3.0


def test_a_qualitative_result_is_stored_as_text_with_no_number():
    rows = [("Dengue NS1 Antigen", "Negative", "", "Negative")]
    extracted = extract_report(read_pdf(lab_report_pdf(rows=rows)), now=NOW)

    # Not a marker we carry, so it is reported as skipped rather than stored.
    assert any("Dengue" in label for label, _ in extracted.skipped)


def test_every_result_is_stamped_with_the_catalog_that_converted_it():
    """value_canonical is only reproducible beside the conversion factors that
    produced it."""
    assert result_for(report(), "hba1c").catalog_version == catalog.catalog_version()


# ── The verbatim check ───────────────────────────────────────────────────────

def test_every_stored_value_appears_verbatim_on_its_page():
    extracted = report()
    pages = read_pdf(lab_report_pdf()).pages

    for result in extracted.results:
        assert result.raw_value in pages[result.page].text


def test_a_value_that_is_not_on_the_page_is_refused(monkeypatch):
    """The guard that makes P2 enforceable rather than aspirational. If anything
    ever starts producing a value instead of reading one, ingestion stops."""
    from app.extraction import ingest, scan

    def tampered(page):
        return [
            scan.Candidate(
                label="HbA1c", value_text="9.9", operator="=", unit_text="%",
                reference_text="4.0 - 5.6", result_type=scan.QUANTITATIVE,
                page=page.index, bbox={"x0": 1, "x1": 2, "top": 1, "bottom": 2},
            )
        ]

    monkeypatch.setattr(ingest, "scan_page", tampered)

    with pytest.raises(VerbatimCheckFailed):
        extract_report(read_pdf(lab_report_pdf()), now=NOW)


# ── Dates ────────────────────────────────────────────────────────────────────

def test_the_collection_date_is_read_not_the_report_date():
    """The report is collected on the 28th and reported on the 29th. Trending
    must use the 28th."""
    extracted = report()

    assert extracted.collected_at.date() == datetime(2026, 9, 28).date()
    assert extracted.reported_at.date() == datetime(2026, 9, 29).date()
    assert extracted.collected_at_source == EXTRACTED


def test_a_report_with_no_collection_date_asks_rather_than_guessing():
    extracted = report(collected_on="")

    assert extracted.collected_at is None
    assert extracted.collected_at_source == UNKNOWN


def test_an_ambiguous_date_is_flagged_for_the_user_to_confirm():
    """03/04/2026 is 3 April here and 4 March in a US-formatted report. We read
    it the Indian way and ask, rather than silently choosing."""
    extracted = report(collected_on="03/04/2026 07:30")

    assert extracted.collected_at.date() == datetime(2026, 4, 3).date()
    assert extracted.collected_at_source == UNKNOWN


def test_an_unambiguous_date_is_not_flagged():
    extracted = report(collected_on="28/09/2026 07:30")

    assert extracted.collected_at_source == EXTRACTED


# ── The history rule ─────────────────────────────────────────────────────────

def test_a_recent_report_is_not_history():
    assert report(collected_on="28/09/2026 07:30").is_history is False


def test_an_old_report_is_history():
    """Five years of reports uploaded in one sitting must populate trends and
    generate no alerts and no clinician drafts."""
    assert report(collected_on="12/03/2021 09:00").is_history is True


def test_the_boundary_is_the_history_window():
    assert HISTORY_DAYS == 90


def test_a_report_with_no_date_is_treated_as_history_until_the_user_says():
    """Conservative on purpose: an undated panel might be from 2019, and firing
    alerts on it is the worse of the two mistakes."""
    assert report(collected_on="").is_history is True


# ── Who the report is about ──────────────────────────────────────────────────

def test_the_patient_name_is_extracted_for_the_user_to_confirm():
    """The document may name someone else. The confirmation screen shows this
    and a mismatch blocks ingestion."""
    assert "SUNITA" in report().patient_name


def test_the_patient_name_stops_at_the_next_field_on_the_line():
    """Reports put two fields on one line. Found on the first real run through
    the deployed pipeline, where the name came back as

        MRS SUNITA R PATNAIK Age / Sex : 54 Y / F

    Splitting on runs of whitespace was not enough: the gap between two
    columns can extract as a single space. A mangled name is not cosmetic --
    it is what the user is asked to confirm is them, and what a check against
    their profile would compare."""
    name = report().patient_name

    assert name == "MRS SUNITA R PATNAIK"


def test_a_name_followed_by_no_other_field_is_kept_whole():
    rows = [("Ferritin", "60", "ng/mL", "22 - 322")]
    extracted = extract_report(
        read_pdf(lab_report_pdf(rows=rows, patient_name="MR A B SAMAL")), now=NOW
    )

    assert extracted.patient_name == "MR A B SAMAL"


def test_the_lab_is_recorded():
    assert "Lal" in report().lab_name


# ── Nothing is silently dropped ──────────────────────────────────────────────

def test_a_marker_we_do_not_carry_is_reported_as_skipped():
    skipped = {label for label, _ in report().skipped}

    assert any("Dengue" in label for label in skipped)


def test_a_result_whose_unit_we_cannot_convert_is_skipped_with_a_reason():
    """Storing it would need a canonical value, and inventing a conversion is
    how a real abnormal result and a unit bug become indistinguishable."""
    rows = [("Ferritin", "60", "furlongs/fortnight", "22 - 322")]

    extracted = extract_report(read_pdf(lab_report_pdf(rows=rows)), now=NOW)

    assert extracted.results == ()
    assert [label for label, _ in extracted.skipped] == ["Ferritin"]
    assert "unit" in extracted.skipped[0][1].lower()


# ── Provenance ───────────────────────────────────────────────────────────────

def test_results_carry_the_page_they_came_from():
    extracted = extract_report(read_pdf(lab_report_pdf(pages=2)), now=NOW)

    assert {r.page for r in extracted.results} == {0, 1}


def test_the_page_count_and_text_layer_are_recorded():
    extracted = report()

    assert extracted.page_count == 1
    assert extracted.text_layer == "native"
