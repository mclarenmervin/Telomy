"""Loads the wellness variant allowlist and checks it is coherent.

The fourth file in the `catalog.py` family and the one with the sharpest
edge. The others decide what a number means; this one decides what we are
willing to know about somebody.

**The allowlist is the enforcement, and it is default-deny.** A 23andMe raw
file has around 600,000 rows and a handful of them answer questions nobody
should receive from a wellness app unprompted. A blocklist would mean the
next hazard is whatever we failed to think of; an allowlist means the next
hazard is discarded by default and the cost of being wrong is a feature that
does less than it could.

**`context_for` is what makes "a variant may never originate an insight"
structural.** Every entry names the measured markers it may appear beside,
and a variant with no marker to be context for is refused at load time. A
user with no homocysteine result can therefore never be told anything about
MTHFR, because there is nothing for it to be context for -- not a line in a
prompt, not a rule a model might forget.
"""

import re
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path

import yaml

from app.analytics import catalog
from app.analytics.catalog import CatalogError, ClinicalReview, content_fingerprint

VARIANTS_PATH = Path(__file__).parent / "data" / "variants.v1.yaml"

RSID = re.compile(r"^rs\d+$")


class VariantCatalogError(CatalogError):
    """The catalog is not internally coherent. Never caught — fail loudly."""


@dataclass(frozen=True)
class Variant:
    """One wellness variant, and the markers it is allowed to sit beside."""

    rsid: str
    gene: str
    trait: str
    context_for: tuple[str, ...]
    note: str
    citation: str


@dataclass(frozen=True)
class Refused:
    """A genotype we will not store, named so that a test can assert it."""

    rsid: str
    gene: str
    reason: str


def _text(raw, key: str) -> str:
    value = raw.get(key)
    if isinstance(value, str):
        return " ".join(value.split())
    return ""


def _build(entry: dict) -> Variant:
    if not isinstance(entry, dict):
        raise VariantCatalogError(f"a variant entry is not a mapping: {entry!r}")

    rsid = str(entry.get("rsid") or "").strip().lower()
    if not RSID.match(rsid):
        raise VariantCatalogError(f"{rsid!r} is not an rsid")

    context_for = tuple(
        str(m).strip() for m in (entry.get("context_for") or []) if str(m).strip()
    )
    if not context_for:
        raise VariantCatalogError(
            f"{rsid}: names no marker to be context for, so it could never be "
            "shown beside anything -- a genotype we store and cannot use"
        )
    for biomarker_id in context_for:
        if catalog.get(biomarker_id) is None:
            raise VariantCatalogError(
                f"{rsid}: context_for names {biomarker_id}, which is not in the "
                "biomarker catalog"
            )

    note = _text(entry, "note")
    if not note:
        raise VariantCatalogError(f"{rsid}: carries no note")
    citation = _text(entry, "citation")
    if not citation:
        raise VariantCatalogError(f"{rsid}: carries no citation")

    gene = _text(entry, "gene")
    if not gene:
        raise VariantCatalogError(f"{rsid}: names no gene")

    return Variant(
        rsid=rsid,
        gene=gene,
        trait=_text(entry, "trait"),
        context_for=context_for,
        note=note,
        citation=citation,
    )


def _build_refused(entry: dict) -> Refused:
    if not isinstance(entry, dict):
        raise VariantCatalogError(f"a refused entry is not a mapping: {entry!r}")
    rsid = str(entry.get("rsid") or "").strip().lower()
    if not RSID.match(rsid):
        raise VariantCatalogError(f"refused: {rsid!r} is not an rsid")
    reason = _text(entry, "reason")
    if not reason:
        raise VariantCatalogError(
            f"refused {rsid}: carries no reason, and a refusal nobody can read "
            "is one somebody eventually undoes"
        )
    return Refused(rsid=rsid, gene=_text(entry, "gene"), reason=reason)


@dataclass(frozen=True)
class _SignedVariant:
    reviewer: str
    reviewed_at: str
    content_sha256: str


def _parse_signoffs(raw: dict, where: str) -> dict[str, _SignedVariant]:
    block = raw.get("clinical_review") or {}
    if not isinstance(block, dict):
        raise VariantCatalogError(f"{where}: clinical_review must be a mapping")
    entries = block.get("variants") or []
    if not isinstance(entries, list):
        raise VariantCatalogError(f"{where}: clinical_review.variants must be a list")

    out: dict[str, _SignedVariant] = {}
    for entry in entries:
        rsid = str(entry.get("rsid") or "").strip().lower()
        if not rsid:
            raise VariantCatalogError(f"{where}: a clinical_review entry has no rsid")
        reviewer = str(entry.get("reviewer") or "").strip()
        reviewed_at = str(entry.get("reviewed_at") or "").strip()
        digest = str(entry.get("content_sha256") or "").strip().lower()
        if not reviewer:
            raise VariantCatalogError(f"{where}: {rsid} sign-off names no reviewer")
        if not reviewed_at:
            raise VariantCatalogError(f"{where}: {rsid} sign-off carries no date")
        if not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise VariantCatalogError(
                f"{where}: {rsid} content_sha256 is missing or not a sha256"
            )
        if rsid in out:
            raise VariantCatalogError(f"{where}: {rsid} is signed off twice")
        out[rsid] = _SignedVariant(reviewer, reviewed_at, digest)
    return out


_FINGERPRINTS: dict[str, dict[str, str]] = {}
_REFUSED: dict[str, tuple[Refused, ...]] = {}


@lru_cache(maxsize=4)
def load_variants(path: Path | None = None) -> tuple[str, dict[str, Variant]]:
    """(version, {rsid: Variant}). Cached: the file does not change at runtime."""
    where = str(path or VARIANTS_PATH)
    raw = yaml.safe_load((path or VARIANTS_PATH).read_text())
    version = raw.get("version")
    if not version:
        raise VariantCatalogError(f"{where}: the file has no version")

    signed = _parse_signoffs(raw, where)

    refused = tuple(_build_refused(e) for e in (raw.get("refused") or []))
    variants: dict[str, Variant] = {}
    fingerprints: dict[str, str] = {}
    for entry in raw.get("variants", []):
        variant = _build(entry)
        if variant.rsid in variants:
            raise VariantCatalogError(f"{variant.rsid}: declared twice")
        variants[variant.rsid] = variant
        fingerprints[variant.rsid] = content_fingerprint(entry)

    # A variant on both lists would have its fate decided by whichever check
    # ran first, which is not how a boundary like this gets to work.
    contradictions = sorted({r.rsid for r in refused} & set(variants))
    if contradictions:
        raise VariantCatalogError(
            f"{where}: {', '.join(contradictions)} appear on both the allowlist "
            "and the refused list"
        )

    if not variants:
        raise VariantCatalogError(f"{where}: declares no variants")

    orphans = sorted(set(signed) - set(variants))
    if orphans:
        raise VariantCatalogError(
            f"{where}: clinical_review signs off variants that do not exist: "
            f"{', '.join(orphans)}"
        )

    _FINGERPRINTS[where] = fingerprints
    _REFUSED[where] = refused
    return version, variants


def variants_version(path: Path | None = None) -> str:
    return load_variants(path)[0]


def variant_fingerprint(rsid: str, path: Path | None = None) -> str | None:
    load_variants(path)
    return _FINGERPRINTS.get(str(path or VARIANTS_PATH), {}).get(rsid)


def allowed_rsids(path: Path | None = None) -> frozenset[str]:
    """The only genotypes this product will store."""
    return frozenset(load_variants(path)[1])


def refused_rsids(path: Path | None = None) -> frozenset[str]:
    """Named refusals. Redundant with the allowlist and written down anyway,
    so that "we do not store APOE" is a thing a test asserts."""
    load_variants(path)
    return frozenset(r.rsid for r in _REFUSED.get(str(path or VARIANTS_PATH), ()))


def get(rsid: str, path: Path | None = None) -> Variant | None:
    return load_variants(path)[1].get(str(rsid).strip().lower())


@lru_cache(maxsize=None)
def review_status(rsid: str, path: Path | None = None) -> ClinicalReview:
    """Has a clinician signed off what this variant means?

    The same narrow consequence as elsewhere: unsigned withholds the `note`,
    not the genotype. A genotype is a fact about a person's body, like a lab
    value; what it means about them is the clinical claim.
    """
    where = path or VARIANTS_PATH
    raw = yaml.safe_load(where.read_text())
    signed = _parse_signoffs(raw, str(where)).get(rsid)
    if signed is None or signed.content_sha256 != variant_fingerprint(rsid, path):
        return ClinicalReview(reviewed=False)
    return ClinicalReview(
        reviewed=True, reviewer=signed.reviewer, reviewed_at=signed.reviewed_at
    )
