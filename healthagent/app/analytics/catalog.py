"""Loads the biomarker catalog and checks it is internally coherent.

The catalog is medical content kept in git (see
`app/analytics/data/biomarkers.v1.yaml`) so that changes get diffs, blame and a
pull request. This module is the only thing that reads it.

Validation is loud and happens at load time, in the same spirit as
`app/common/thresholds.py`: a mis-ordered range or a missing citation is a
safety failure, not a config nuisance, and it should stop the process rather
than silently grade someone against nonsense.
"""

from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path

import yaml

CATALOG_PATH = Path(__file__).parent / "data" / "biomarkers.v1.yaml"


class CatalogError(ValueError):
    """The catalog is not internally coherent. Never caught — fail loudly."""


@dataclass(frozen=True)
class Range:
    low: float
    high: float

    def contains(self, value: float) -> bool:
        return self.low <= value <= self.high


@dataclass(frozen=True)
class ClinicalReview:
    """Whether a clinician has signed off these ranges, and who.

    The catalog ships unreviewed, and while it is unreviewed we may show someone
    the number printed on their report but must make no claim about what it
    means. `reference_ranges.grade_for_display` is where that is enforced.

    Critical bounds are the deliberate exception and are handled separately: a
    bound we are unsure about is still a far better reason to escalate than
    silence is.
    """

    reviewed: bool
    reviewer: str | None = None
    reviewed_at: str | None = None


def _parse_review(raw: dict, where: str) -> ClinicalReview:
    """The review block, refusing a claim it cannot evidence.

    `reviewed: true` is deliberately not something that can be typed on the way
    past. Without a named reviewer and a date there is no audit trail, and an
    audit trail is the entire reason medical content lives in git.
    """
    block = raw.get("clinical_review") or {}
    if not isinstance(block, dict):
        raise CatalogError(f"{where}: clinical_review must be a mapping")

    reviewed = bool(block.get("reviewed", False))
    reviewer = str(block.get("reviewer") or "").strip() or None
    reviewed_at = str(block.get("reviewed_at") or "").strip() or None

    if reviewed and not reviewer:
        raise CatalogError(f"{where}: clinical_review.reviewed is true but names no reviewer")
    if reviewed and not reviewed_at:
        raise CatalogError(
            f"{where}: clinical_review.reviewed is true but carries no reviewed_at date"
        )
    return ClinicalReview(reviewed=reviewed, reviewer=reviewer, reviewed_at=reviewed_at)


@dataclass(frozen=True)
class Conversion:
    """canonical = value * factor + offset.

    The offset exists because HbA1c's IFCC-to-NGSP conversion is affine, not a
    ratio; treating it as a ratio puts a well-controlled result in the diabetic
    range.
    """

    factor: float
    offset: float = 0.0

    def to_canonical(self, value: float) -> float:
        return value * self.factor + self.offset

    def from_canonical(self, value: float) -> float:
        return (value - self.offset) / self.factor


@dataclass(frozen=True)
class Biomarker:
    id: str
    name: str
    system: str
    canonical_unit: str
    conversions: dict[str, Conversion]
    citation: str
    critical: Range
    standard: Range | None = None
    optimal: Range | None = None
    by_sex: dict[str, dict[str, Range]] | None = None

    @property
    def sex_specific(self) -> bool:
        return self.by_sex is not None

    def ranges_for(self, sex: str | None) -> tuple[Range, Range] | None:
        """(standard, optimal) for this person, or None when we cannot say.

        A sex-specific marker with an unknown sex returns None rather than
        picking a default — the same discipline the app's calculators already
        apply when they ask for sex before reporting body fat.
        """
        if not self.sex_specific:
            return (self.standard, self.optimal) if self.standard else None
        band = (self.by_sex or {}).get((sex or "").lower())
        if band is None:
            return None
        return band["standard"], band["optimal"]


def _range(raw, where: str) -> Range:
    if not isinstance(raw, list) or len(raw) != 2:
        raise CatalogError(f"{where}: expected [low, high], got {raw!r}")
    low, high = float(raw[0]), float(raw[1])
    if low > high:
        raise CatalogError(f"{where}: low {low} is above high {high}")
    return Range(low, high)


def _conversions(raw: dict, where: str) -> dict[str, Conversion]:
    from app.analytics.units import normalise_unit_label

    out: dict[str, Conversion] = {}
    for unit, spec in (raw or {}).items():
        if isinstance(spec, dict):
            conversion = Conversion(float(spec["factor"]), float(spec.get("offset", 0.0)))
        else:
            conversion = Conversion(float(spec))
        if conversion.factor == 0:
            raise CatalogError(f"{where}: unit {unit!r} has a zero factor")
        out[normalise_unit_label(unit)] = conversion
    if not out:
        raise CatalogError(f"{where}: no units declared")
    return out


def _check_nesting(marker: Biomarker, standard: Range, optimal: Range) -> None:
    """optimal must sit inside standard, and standard inside critical.

    This is the check that catches a transposed digit in a range nobody reads
    closely — the failure mode that silently poisons biological age and
    supplement recommendations.
    """
    if not (marker.critical.low <= standard.low and standard.high <= marker.critical.high):
        raise CatalogError(
            f"{marker.id}: standard {standard} is not inside critical {marker.critical}"
        )
    if not (standard.low <= optimal.low and optimal.high <= standard.high):
        raise CatalogError(
            f"{marker.id}: optimal {optimal} is not inside standard {standard}"
        )


def _build(entry: dict) -> Biomarker:
    from app.analytics.units import normalise_unit_label

    marker_id = entry.get("id")
    if not marker_id:
        raise CatalogError(f"a catalog entry has no id: {entry!r}")
    citation = (entry.get("citation") or "").strip()
    if not citation:
        # Every range must be traceable to a source. A range we cannot cite is a
        # range we cannot defend to a clinician.
        raise CatalogError(f"{marker_id}: no citation")

    canonical = entry.get("canonical_unit")
    if not canonical:
        raise CatalogError(f"{marker_id}: no canonical_unit")
    conversions = _conversions(entry.get("units"), marker_id)
    if normalise_unit_label(canonical) not in conversions:
        raise CatalogError(f"{marker_id}: canonical unit {canonical!r} is not in units")

    by_sex = None
    standard = optimal = None
    if "ranges_by_sex" in entry:
        by_sex = {
            sex.lower(): {
                "standard": _range(bands["standard"], f"{marker_id}.{sex}.standard"),
                "optimal": _range(bands["optimal"], f"{marker_id}.{sex}.optimal"),
            }
            for sex, bands in entry["ranges_by_sex"].items()
        }
        missing = {"male", "female"} - set(by_sex)
        if missing:
            raise CatalogError(f"{marker_id}: ranges_by_sex missing {sorted(missing)}")
    else:
        standard = _range(entry["standard"], f"{marker_id}.standard")
        optimal = _range(entry["optimal"], f"{marker_id}.optimal")

    marker = Biomarker(
        id=marker_id,
        name=entry.get("name") or marker_id,
        system=entry.get("system") or "other",
        canonical_unit=canonical,
        conversions=conversions,
        citation=citation,
        critical=_range(entry["critical"], f"{marker_id}.critical"),
        standard=standard,
        optimal=optimal,
        by_sex=by_sex,
    )

    if by_sex:
        for bands in by_sex.values():
            _check_nesting(marker, bands["standard"], bands["optimal"])
    else:
        _check_nesting(marker, standard, optimal)
    return marker


@lru_cache(maxsize=1)
def load_catalog(path: Path | None = None) -> tuple[str, dict[str, Biomarker]]:
    """(version, {id: Biomarker}). Cached: the file does not change at runtime."""
    raw = yaml.safe_load((path or CATALOG_PATH).read_text())
    version = raw.get("version")
    if not version:
        raise CatalogError("catalog has no version")
    # Validated here as well as in `review_status`, so a malformed review block
    # stops the process at startup rather than the first time someone is graded.
    _parse_review(raw, str(path or CATALOG_PATH))
    markers: dict[str, Biomarker] = {}
    for entry in raw.get("biomarkers", []):
        marker = _build(entry)
        if marker.id in markers:
            raise CatalogError(f"{marker.id}: declared twice")
        markers[marker.id] = marker
    if not markers:
        raise CatalogError("catalog declares no biomarkers")
    return version, markers


def get(biomarker_id: str) -> Biomarker | None:
    return load_catalog()[1].get(biomarker_id)


def catalog_version() -> str:
    return load_catalog()[0]


@lru_cache(maxsize=1)
def review_status() -> ClinicalReview:
    """Has a clinician signed these ranges off?

    Cached and read from the catalog separately from the marker set, which costs
    one extra read of a small file at startup and buys a narrow dependency: the
    gate asks one question and does not need the whole catalog parsed to answer
    it. Tests that repoint `CATALOG_PATH` must clear this cache too.
    """
    return _parse_review(yaml.safe_load(CATALOG_PATH.read_text()), str(CATALOG_PATH))
