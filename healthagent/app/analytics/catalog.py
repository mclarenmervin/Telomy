"""Loads the biomarker catalog and checks it is internally coherent.

The catalog is medical content kept in git (see
`app/analytics/data/biomarkers.v1.yaml`) so that changes get diffs, blame and a
pull request. This module is the only thing that reads it.

Validation is loud and happens at load time, in the same spirit as
`app/common/thresholds.py`: a mis-ordered range or a missing citation is a
safety failure, not a config nuisance, and it should stop the process rather
than silently grade someone against nonsense.
"""

import hashlib
import json
import re
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


def _parse_marker_reviews(raw: dict, where: str) -> dict[str, ClinicalReview]:
    """Sign-offs for individual markers, each bound to a hash of what was signed.

    Per marker rather than all-or-nothing because biological age needs nine
    markers and the catalog carries thirty-three. Requiring the whole file to be
    reviewed before any of it can be used makes the cheapest useful sign-off
    four times larger than it needs to be, and in practice that means it does
    not happen at all.

    `content_sha256` is what makes the signature mean something. A signature
    over "hba1c" is a signature over a name; a signature over a fingerprint of
    hba1c's entry covers the ranges, the units, the conversions, the aliases and
    the citation, so editing any of them afterwards withdraws the sign-off
    automatically. The git diff shows the range changed and the loader stops
    trusting the signature in the same commit, which is the whole reason medical
    content lives in git.

    The hash is NOT verified here -- that needs the marker set, which is built
    later. `marker_reviews` does the verifying.
    """
    block = raw.get("clinical_review") or {}
    entries = block.get("markers") or []
    if not isinstance(entries, list):
        raise CatalogError(f"{where}: clinical_review.markers must be a list")

    out: dict[str, ClinicalReview] = {}
    for entry in entries:
        if not isinstance(entry, dict):
            raise CatalogError(f"{where}: a clinical_review.markers entry is not a mapping")
        marker_id = str(entry.get("id") or "").strip()
        if not marker_id:
            raise CatalogError(f"{where}: a clinical_review.markers entry has no id")
        reviewer = str(entry.get("reviewer") or "").strip() or None
        reviewed_at = str(entry.get("reviewed_at") or "").strip() or None
        digest = str(entry.get("content_sha256") or "").strip().lower() or None

        # The same three refusals the catalog-level block makes, for the same
        # reason: a sign-off we cannot attribute is not an audit trail.
        if not reviewer:
            raise CatalogError(f"{where}: {marker_id} sign-off names no reviewer")
        if not reviewed_at:
            raise CatalogError(f"{where}: {marker_id} sign-off carries no reviewed_at date")
        if not digest:
            raise CatalogError(
                f"{where}: {marker_id} sign-off carries no content_sha256, so it is "
                "a signature over a name rather than over a set of ranges"
            )
        if not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise CatalogError(f"{where}: {marker_id} content_sha256 is not a sha256")
        if marker_id in out:
            raise CatalogError(f"{where}: {marker_id} is signed off twice")

        out[marker_id] = _SignedMarker(
            reviewer=reviewer, reviewed_at=reviewed_at, content_sha256=digest
        )
    return out


@dataclass(frozen=True)
class _SignedMarker:
    reviewer: str
    reviewed_at: str
    content_sha256: str


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


def normalise_label(text: str | None) -> str:
    """Fold a printed test name into a comparable key.

    `HbA1c`, `HBA1C`, `Hb A1c` and `Glycosylated Haemoglobin (HbA1c)` are one
    marker printed four ways, and labs vary punctuation and case freely. Every
    non-alphanumeric run becomes a single space, which is enough to collapse the
    spellings that actually occur without merging markers that differ.
    """
    if not text:
        return ""
    return " ".join(re.sub(r"[^a-z0-9]+", " ", str(text).lower()).split())


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
    aliases: tuple[str, ...] = ()

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

    # The label as printed is how a lab report refers to this marker, and the
    # marker's own name is always one of them.
    aliases = tuple(dict.fromkeys(
        normalise_label(alias)
        for alias in [entry.get("name") or marker_id, marker_id, *(entry.get("aliases") or [])]
        if normalise_label(alias)
    ))

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
        aliases=aliases,
    )

    if by_sex:
        for bands in by_sex.values():
            _check_nesting(marker, bands["standard"], bands["optimal"])
    else:
        _check_nesting(marker, standard, optimal)
    return marker


def content_fingerprint(entry: dict) -> str:
    """Hex sha256 over one entry of reviewed medical content.

    Public because `supplement_rules` signs its rules the same way, and what a
    signature is over must be one decision in one place: two hashes that
    disagreed about whether key order matters would withdraw sign-offs in one
    file and not the other, for the same reformat.

    The whole entry, not a chosen subset. A clinician signing off a marker is
    signing off the ranges, the unit they are expressed in, the conversions
    into it, the labels that map onto it and the citation behind it -- and
    picking a subset means guessing which edits matter, then being wrong once.
    Hashing everything errs toward asking for re-review, which is the correct
    direction to be wrong in for medical content.

    Serialised with sorted keys so a reordered YAML file -- a reformat, a merge
    -- does not withdraw every sign-off in it.
    """
    canonical = json.dumps(entry, sort_keys=True, separators=(",", ":"),
                           default=str)
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


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
    signed = _parse_marker_reviews(raw, str(path or CATALOG_PATH))
    markers: dict[str, Biomarker] = {}
    fingerprints: dict[str, str] = {}
    for entry in raw.get("biomarkers", []):
        marker = _build(entry)
        if marker.id in markers:
            raise CatalogError(f"{marker.id}: declared twice")
        markers[marker.id] = marker
        fingerprints[marker.id] = content_fingerprint(entry)
    if not markers:
        raise CatalogError("catalog declares no biomarkers")

    # A sign-off left behind after a marker was removed or renamed. Ignoring it
    # silently would leave a reviewer's name in the file against nothing, which
    # reads like coverage we do not have.
    orphans = sorted(set(signed) - set(markers))
    if orphans:
        raise CatalogError(
            f"clinical_review.markers signs off markers that do not exist: "
            f"{', '.join(orphans)}"
        )

    _FINGERPRINTS[str(path or CATALOG_PATH)] = fingerprints
    return version, markers


#: Per-path fingerprints, populated by `load_catalog`. Keyed by path because the
#: tests repoint CATALOG_PATH and would otherwise read each other's.
_FINGERPRINTS: dict[str, dict[str, str]] = {}


def marker_fingerprint(biomarker_id: str) -> str | None:
    """The hash a sign-off for this marker has to match, or None if unknown."""
    load_catalog()
    return _FINGERPRINTS.get(str(CATALOG_PATH), {}).get(biomarker_id)


def get(biomarker_id: str) -> Biomarker | None:
    return load_catalog()[1].get(biomarker_id)


def catalog_version() -> str:
    return load_catalog()[0]


@lru_cache(maxsize=1)
def alias_index() -> dict[str, str]:
    """{normalised printed label: biomarker_id}.

    An alias claimed by two markers is refused at load time rather than
    resolved. Order-dependent mapping would mean the losing marker's results are
    silently misfiled under the winner — a wrong number attributed to the right
    person, which is the hardest kind of error to notice.
    """
    _, markers = load_catalog()
    index: dict[str, str] = {}
    for marker in markers.values():
        for alias in marker.aliases:
            owner = index.get(alias)
            if owner is not None and owner != marker.id:
                raise CatalogError(
                    f"alias {alias!r} is claimed by both {owner} and {marker.id}"
                )
            index[alias] = marker.id
    return index


def _catalog_review() -> ClinicalReview:
    """The catalog-level block: has a clinician signed off *all* of this?

    Cached and read from the catalog separately from the marker set, which costs
    one extra read of a small file at startup and buys a narrow dependency: the
    gate asks one question and does not need the whole catalog parsed to answer
    it. Tests that repoint `CATALOG_PATH` must clear this cache too.
    """
    return _parse_review(yaml.safe_load(CATALOG_PATH.read_text()), str(CATALOG_PATH))


def marker_reviews() -> dict[str, ClinicalReview]:
    """Per-marker sign-offs whose hash still matches what is in the file.

    A sign-off whose hash no longer matches is not returned at all. That is the
    withdrawal: somebody edited the ranges after a clinician signed them, and
    the signature is over numbers that are no longer there.
    """
    raw = yaml.safe_load(CATALOG_PATH.read_text())
    signed = _parse_marker_reviews(raw, str(CATALOG_PATH))
    out: dict[str, ClinicalReview] = {}
    for marker_id, entry in signed.items():
        if entry.content_sha256 != marker_fingerprint(marker_id):
            continue
        out[marker_id] = ClinicalReview(
            reviewed=True, reviewer=entry.reviewer, reviewed_at=entry.reviewed_at
        )
    return out


@lru_cache(maxsize=None)
def review_status(biomarker_id: str | None = None) -> ClinicalReview:
    """Has a clinician signed off the ranges we are about to grade against?

    The only cached entry point of the three, deliberately. `_catalog_review`
    and `marker_reviews` re-read the file each call and this memoises per
    marker, so clearing `review_status` and `load_catalog` -- which is what
    every test that repoints CATALOG_PATH already does -- is enough to clear
    all of it. A second cache underneath would survive that and serve one
    test's catalog to the next.

    With no argument this is the blunt question -- "all of it" -- and the
    answer is unchanged from before: the catalog-level block and nothing else.
    Anything making a claim about the catalog as a whole still gets the whole
    catalog's answer.

    With a biomarker_id it is the useful question. A fully reviewed catalog
    covers every marker; otherwise the marker's own sign-off decides, and only
    while its hash still matches the entry in the file.
    """
    whole = _catalog_review()
    if biomarker_id is None or whole.reviewed:
        return whole
    return marker_reviews().get(biomarker_id, ClinicalReview(reviewed=False))
