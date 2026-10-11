"""Loads the correlation mechanism catalog and checks it is coherent.

The third file in the `catalog.py` / `supplement_rules.py` family, and the one
that answers a question the statistics cannot. `statistics.py` answers "could
this be chance?". Nothing in it can answer "could this be real?", and a
correlation that is clean and meaningless is the easiest false statement this
product could make.

**Only declared pairs are ever tested.** That is not a filter applied after the
fact — `correlations.py` builds its hypothesis set from this file. The
difference matters twice: it is pre-registration rather than a fishing trip,
and it makes the multiple-comparison correction honest, because the number of
tests becomes the number of things we were ever prepared to report.

**Three outcomes, not two.** A pair with a `mechanism` is testable; a pair
marked `tautological` is two spellings of the same measurement and is never
tested; a pair that is absent is not a claim that nothing is there, only that
we have not named it. The tautological verdict earns its place: the stress
score every wearable here reports is computed *from* heart rate variability,
and a plain allowlist would have let us hand a user the ring's own arithmetic
back as a discovery about their body.

Nothing here decides anything about a person. That is `correlations.py`.
"""

import re
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path

import yaml

from app.analytics.catalog import CatalogError, ClinicalReview, content_fingerprint

PAIRS_PATH = Path(__file__).parent / "data" / "correlations.v1.yaml"

#: The daily series the engine knows how to build. A pair naming anything else
#: can never fire, and would fail invisibly: the screen shows one fewer pattern
#: and nobody can tell a quiet month from a typo.
SERIES = frozenset({
    "sleep_duration",
    "steps",
    "active_minutes",
    "resting_heart_rate",
    "hrv",
    "stress",
    "food_energy",
    "protein",
    "hydration",
    "workout_minutes",
})

#: A named physiological path, with a direction and a citation.
MECHANISM = "mechanism"
#: Two spellings of one measurement. Never tested.
TAUTOLOGICAL = "tautological"
VERDICTS = (MECHANISM, TAUTOLOGICAL)

POSITIVE = "positive"
NEGATIVE = "negative"
DIRECTIONS = (POSITIVE, NEGATIVE)


class MechanismError(CatalogError):
    """The catalog is not internally coherent. Never caught — fail loudly."""


@dataclass(frozen=True)
class Pair:
    """One unordered pair of series and what we are prepared to say about it.

    `expect` is the half of plausibility that catches confounders. A
    correlation that is statistically clean but runs against the mechanism is
    not that mechanism, and reporting it under that explanation would be the
    most convincing way to be wrong.
    """

    id: str
    first: str
    second: str
    verdict: str
    expect: str | None = None
    mechanism: str = ""
    citation: str = ""
    reason: str = ""

    @property
    def testable(self) -> bool:
        return self.verdict == MECHANISM


def _text(raw, key: str) -> str:
    value = raw.get(key)
    if isinstance(value, str):
        return " ".join(value.split())
    return ""


def _build(entry: dict) -> Pair:
    if not isinstance(entry, dict):
        raise MechanismError(f"a pair entry is not a mapping: {entry!r}")

    pair_id = str(entry.get("id") or "").strip()
    if not pair_id:
        raise MechanismError(f"a pair entry has no id: {entry!r}")

    first = str(entry.get("first") or "").strip()
    second = str(entry.get("second") or "").strip()
    for name in (first, second):
        if name not in SERIES:
            raise MechanismError(
                f"{pair_id}: {name!r} is not a series the engine can build"
            )
    if first == second:
        raise MechanismError(f"{pair_id}: a series cannot be correlated with itself")
    if first > second:
        raise MechanismError(
            f"{pair_id}: first and second must be in alphabetical order, so an "
            "unordered pair has exactly one spelling and cannot be declared "
            "twice under two verdicts"
        )
    if pair_id != f"{first}__{second}":
        raise MechanismError(f"{pair_id}: id must be {first}__{second}")

    verdict = str(entry.get("verdict") or "").strip()
    if verdict not in VERDICTS:
        raise MechanismError(
            f"{pair_id}: verdict {verdict!r} is not one of {', '.join(VERDICTS)}"
        )

    expect = str(entry.get("expect") or "").strip() or None
    mechanism = _text(entry, "mechanism")
    citation = _text(entry, "citation")
    reason = _text(entry, "reason")

    if verdict == MECHANISM:
        if expect not in DIRECTIONS:
            raise MechanismError(
                f"{pair_id}: a mechanism must predict a direction -- without one "
                "the gate cannot refuse a correlation that runs the wrong way, "
                "which is the half of plausibility that catches confounders"
            )
        if not mechanism:
            raise MechanismError(f"{pair_id}: carries no mechanism")
        if not citation:
            raise MechanismError(f"{pair_id}: carries no citation")
    else:
        if expect is not None:
            raise MechanismError(
                f"{pair_id}: a tautological pair may not predict a direction -- "
                "it is not a finding at any direction"
            )
        if not reason:
            raise MechanismError(
                f"{pair_id}: carries no reason, so nobody reading the file can "
                "tell why this pair is excluded"
            )

    return Pair(
        id=pair_id,
        first=first,
        second=second,
        verdict=verdict,
        expect=expect,
        mechanism=mechanism,
        citation=citation,
        reason=reason,
    )


@dataclass(frozen=True)
class _SignedPair:
    reviewer: str
    reviewed_at: str
    content_sha256: str


def _parse_signoffs(raw: dict, where: str) -> dict[str, _SignedPair]:
    """Per-pair sign-offs, refusing any claim the file cannot evidence."""
    block = raw.get("clinical_review") or {}
    if not isinstance(block, dict):
        raise MechanismError(f"{where}: clinical_review must be a mapping")
    entries = block.get("pairs") or []
    if not isinstance(entries, list):
        raise MechanismError(f"{where}: clinical_review.pairs must be a list")

    out: dict[str, _SignedPair] = {}
    for entry in entries:
        if not isinstance(entry, dict):
            raise MechanismError(f"{where}: a clinical_review.pairs entry is not a mapping")
        pair_id = str(entry.get("id") or "").strip()
        if not pair_id:
            raise MechanismError(f"{where}: a clinical_review.pairs entry has no id")
        reviewer = str(entry.get("reviewer") or "").strip()
        reviewed_at = str(entry.get("reviewed_at") or "").strip()
        digest = str(entry.get("content_sha256") or "").strip().lower()

        if not reviewer:
            raise MechanismError(f"{where}: {pair_id} sign-off names no reviewer")
        if not reviewed_at:
            raise MechanismError(f"{where}: {pair_id} sign-off carries no reviewed_at date")
        if not digest:
            raise MechanismError(
                f"{where}: {pair_id} sign-off carries no content_sha256, so it is a "
                "signature over a name rather than over a mechanism"
            )
        if not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise MechanismError(f"{where}: {pair_id} content_sha256 is not a sha256")
        if pair_id in out:
            raise MechanismError(f"{where}: {pair_id} is signed off twice")

        out[pair_id] = _SignedPair(
            reviewer=reviewer, reviewed_at=reviewed_at, content_sha256=digest
        )
    return out


#: Per-path fingerprints, populated by `load_pairs`. Keyed by path because the
#: tests repoint PAIRS_PATH and would otherwise read each other's.
_FINGERPRINTS: dict[str, dict[str, str]] = {}


@lru_cache(maxsize=4)
def load_pairs(path: Path | None = None) -> tuple[str, dict[str, Pair]]:
    """(version, {id: Pair}). Cached: the file does not change at runtime."""
    where = str(path or PAIRS_PATH)
    raw = yaml.safe_load((path or PAIRS_PATH).read_text())
    version = raw.get("version")
    if not version:
        raise MechanismError(f"{where}: the pair file has no version")

    signed = _parse_signoffs(raw, where)

    pairs: dict[str, Pair] = {}
    fingerprints: dict[str, str] = {}
    for entry in raw.get("pairs", []):
        pair = _build(entry)
        if pair.id in pairs:
            raise MechanismError(f"{pair.id}: declared twice")
        pairs[pair.id] = pair
        fingerprints[pair.id] = content_fingerprint(entry)
    if not pairs:
        raise MechanismError(f"{where}: declares no pairs")

    orphans = sorted(set(signed) - set(pairs))
    if orphans:
        raise MechanismError(
            f"{where}: clinical_review.pairs signs off pairs that do not exist: "
            f"{', '.join(orphans)}"
        )

    _FINGERPRINTS[where] = fingerprints
    return version, pairs


def pairs_version(path: Path | None = None) -> str:
    return load_pairs(path)[0]


def pair_fingerprint(pair_id: str, path: Path | None = None) -> str | None:
    """The hash a sign-off for this pair has to match, or None if unknown."""
    load_pairs(path)
    return _FINGERPRINTS.get(str(path or PAIRS_PATH), {}).get(pair_id)


def canonical_id(first: str, second: str) -> str:
    """The one spelling of an unordered pair."""
    low, high = sorted((first, second))
    return f"{low}__{high}"


@lru_cache(maxsize=None)
def pair_for(first: str, second: str, path: Path | None = None) -> Pair | None:
    """What the catalog says about these two series, in either order."""
    _, pairs = load_pairs(path)
    return pairs.get(canonical_id(first, second))


def testable_pairs(path: Path | None = None) -> tuple[Pair, ...]:
    """Every pair the engine may form a hypothesis about, in a stable order.

    This is the hypothesis set, and its length is the `m` the false discovery
    rate is computed over. Widening it widens the correction for everything
    else, which is the correct incentive.
    """
    _, pairs = load_pairs(path)
    return tuple(sorted((p for p in pairs.values() if p.testable), key=lambda p: p.id))


@lru_cache(maxsize=None)
def review_status(pair_id: str, path: Path | None = None) -> ClinicalReview:
    """Has a clinician signed off this mechanism, and is the signature still
    over it?

    A sign-off whose hash no longer matches is not returned. That is the
    withdrawal: somebody edited the mechanism or the citation after it was
    signed, and the signature is over a sentence that is no longer there.

    What an unsigned mechanism costs is narrower than it is for a supplement
    rule, deliberately. A correlation is a statement about measurements, like
    a lab value, so it may still be reported; the mechanism *sentence* is a
    clinical claim about why, and that is what is withheld. The user is told
    two of their series moved together and is not told why.
    """
    where = path or PAIRS_PATH
    raw = yaml.safe_load(where.read_text())
    signed = _parse_signoffs(raw, str(where)).get(pair_id)
    if signed is None or signed.content_sha256 != pair_fingerprint(pair_id, path):
        return ClinicalReview(reviewed=False)
    return ClinicalReview(
        reviewed=True, reviewer=signed.reviewer, reviewed_at=signed.reviewed_at
    )
