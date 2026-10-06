"""Unit normalisation.

A report in mmol/L and one in mg/dL must produce identical clinical reasoning,
so every score reads the canonical value and nothing else. Conversions are
per-biomarker because the molar mass differs: glucose and cholesterol both go
mg/dL to mmol/L and the factors are not the same.
"""

import pytest

from app.analytics.units import (
    UnknownUnit,
    canonical_unit,
    normalise_unit_label,
    to_canonical,
)


def test_a_value_already_in_canonical_units_is_unchanged():
    assert to_canonical("glucose_fasting", 92.0, "mg/dL") == pytest.approx(92.0)


def test_glucose_converts_from_mmol_per_litre():
    # 5.1 mmol/L is ~92 mg/dL
    assert to_canonical("glucose_fasting", 5.1, "mmol/L") == pytest.approx(91.9, abs=0.3)


def test_cholesterol_uses_a_different_factor_from_glucose():
    """Both are mg/dL <-> mmol/L; sharing one factor would be a silent error."""
    glucose = to_canonical("glucose_fasting", 5.0, "mmol/L")
    ldl = to_canonical("ldl_cholesterol", 5.0, "mmol/L")

    assert glucose == pytest.approx(90.1, abs=0.3)
    assert ldl == pytest.approx(193.4, abs=0.5)


def test_creatinine_converts_from_micromoles():
    assert to_canonical("creatinine", 88.4, "umol/L") == pytest.approx(1.0, abs=0.01)


def test_hba1c_conversion_is_affine_not_merely_scaled():
    """IFCC mmol/mol to NGSP % has an offset; treating it as a ratio would put a
    well-controlled result in the diabetic range."""
    assert to_canonical("hba1c", 31.0, "mmol/mol") == pytest.approx(5.0, abs=0.05)
    assert to_canonical("hba1c", 53.0, "mmol/mol") == pytest.approx(7.0, abs=0.05)


def test_every_unit_round_trips_through_canonical():
    from app.analytics.units import from_canonical, known_units

    for biomarker in ("glucose_fasting", "ldl_cholesterol", "creatinine", "hba1c",
                      "vitamin_d_25oh", "ferritin", "insulin_fasting"):
        for unit in known_units(biomarker):
            canonical = to_canonical(biomarker, 10.0, unit)
            assert from_canonical(biomarker, canonical, unit) == pytest.approx(10.0, rel=1e-9)


def test_unit_labels_are_matched_case_and_micron_insensitively():
    assert normalise_unit_label("MG/DL") == normalise_unit_label("mg/dl")
    # Reports use mu, micro sign and a plain u interchangeably.
    assert normalise_unit_label("µIU/mL") == normalise_unit_label("uIU/mL")
    assert normalise_unit_label("μmol/L") == normalise_unit_label("umol/L")
    assert normalise_unit_label(" mg / dL ") == normalise_unit_label("mg/dL")


def test_a_unit_the_catalog_does_not_know_is_refused_not_guessed():
    with pytest.raises(UnknownUnit):
        to_canonical("glucose_fasting", 92.0, "furlongs")


def test_an_unknown_biomarker_is_refused():
    with pytest.raises(UnknownUnit):
        to_canonical("midichlorian_count", 1.0, "mg/dL")


def test_canonical_unit_is_reported_for_display():
    assert canonical_unit("glucose_fasting") == "mg/dL"
    assert canonical_unit("hba1c") == "%"
