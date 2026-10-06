"""Unit normalisation.

A report in mmol/L and one in mg/dL must produce identical clinical reasoning,
so every score reads the canonical value and nothing else. The raw value and
unit are kept alongside it purely for display.

Conversions are per-biomarker because the molar mass differs: glucose and
cholesterol both convert mg/dL to mmol/L, and sharing one factor between them
would be a silent, clinically significant error. The factors therefore live in
the catalog beside the ranges they belong to, not in a generic table here.
"""

import re
import unicodedata

from app.analytics import catalog


class UnknownUnit(ValueError):
    """The catalog cannot convert this unit for this marker.

    Raised rather than guessed: a wrong conversion is indistinguishable from a
    real abnormal result once it is a number on a chart.
    """


def normalise_unit_label(unit: str | None) -> str:
    """Fold the spellings real reports use into one key.

    Lab reports are inconsistent about case, spacing and the micro sign — µ
    (micro sign), μ (Greek mu) and a plain `u` all appear for the same unit.
    """
    if not unit:
        return ""
    text = unicodedata.normalize("NFKC", str(unit)).strip()
    text = text.replace("µ", "u").replace("μ", "u")  # micro sign, Greek mu
    text = re.sub(r"\s+", "", text)
    return text.lower()


def _marker(biomarker_id: str) -> catalog.Biomarker:
    marker = catalog.get(biomarker_id)
    if marker is None:
        raise UnknownUnit(f"no biomarker {biomarker_id!r} in the catalog")
    return marker


def _conversion(biomarker_id: str, unit: str | None) -> catalog.Conversion:
    marker = _marker(biomarker_id)
    key = normalise_unit_label(unit)
    conversion = marker.conversions.get(key)
    if conversion is None:
        known = ", ".join(sorted(marker.conversions)) or "none"
        raise UnknownUnit(
            f"{biomarker_id}: cannot convert from {unit!r}; catalog knows {known}"
        )
    return conversion


def canonical_unit(biomarker_id: str) -> str:
    return _marker(biomarker_id).canonical_unit


def known_units(biomarker_id: str) -> tuple[str, ...]:
    return tuple(sorted(_marker(biomarker_id).conversions))


def to_canonical(biomarker_id: str, value: float, unit: str | None) -> float:
    """The value in the marker's canonical unit. The only form any score reads."""
    return _conversion(biomarker_id, unit).to_canonical(float(value))


def from_canonical(biomarker_id: str, value: float, unit: str | None) -> float:
    """Back out of canonical, for displaying a value in the unit a user expects."""
    return _conversion(biomarker_id, unit).from_canonical(float(value))
