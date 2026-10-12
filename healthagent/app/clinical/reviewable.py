"""Everything in this product that is waiting for a clinician's name.

Five files carry reviewed clinical content, signed per entry and bound to a
content hash. Between them they carry **zero signatures**, and the reason has
never been that nobody read them: there was nowhere for a signature to be
made. This module is what the admin surface reads to show what is waiting.

── Why a registry rather than five endpoints ────────────────────────────────

The five grew one per phase and each invented its own vocabulary for the same
three facts:

  file                     block key    entry key   fingerprint function
  biomarkers.v1.yaml       markers      id          marker_fingerprint
  supplements.v1.yaml      rules        id          rule_fingerprint
  correlations.v1.yaml     pairs        id          pair_fingerprint
  therapies.v1.yaml        effects      id          effect_fingerprint
  variants.v1.yaml         variants     rsid        variant_fingerprint

That is fine inside each engine. It is useless to a surface whose entire job
is "show me everything nobody has signed", and it is why the first version of
that surface would have handled two files and quietly not the other three.

── This module computes no hash of its own ──────────────────────────────────

Every fingerprint here comes from the engine that owns the file. The
alternative — hashing the entry again on this side — would be a second
implementation of what a signature is over, and the first time the two
disagreed we would collect a real signature from a real clinician that the
loader then refused to honour. The symptom would be a screen still saying
nobody has reviewed this, and nothing in the logs. There is a test per
catalog asserting the two agree.

── And it writes nothing ────────────────────────────────────────────────────

`signoff_block` renders the YAML a human commits. git stays the source of
truth for reviewed content, which is what keeps the loaders free of a
database call and keeps the audit trail in the diff. The verified identity,
the licence state at signing time and the unrewritable trail live in
`catalog_signoffs` (023); this is the bridge between the two.
"""

from dataclasses import dataclass
from functools import lru_cache
from typing import Callable

from app.analytics import (
    catalog,
    correlation_mechanisms,
    supplement_rules,
    therapy_catalog,
    variant_catalog,
)

#: Where the five live, relative to the repository root, because the last step
#: of collecting a signature is a human committing a file and they need to be
#: told which one.
_DATA = "healthagent/app/analytics/data"


class StaleSignature(Exception):
    """A signature over content that is no longer there.

    Never caught by the surface — it is a 409, not an empty list. Rendering a
    stale hash into a file would produce a block that looks committed and
    does nothing, which is the one failure mode worse than refusing.
    """


@dataclass(frozen=True)
class ReviewableEntry:
    """One entry somebody could sign, and whether anybody has."""

    catalogue: str
    entry_id: str
    #: What a clinician reads to know what they are being asked about. An id
    #: is not a thing to take a clinical view on: `rs1801133` means nothing
    #: and "MTHFR C677T — folate metabolism" means something.
    label: str
    fingerprint: str
    signed: bool
    reviewer: str | None = None
    reviewed_at: str | None = None


@dataclass(frozen=True)
class Catalogue:
    name: str
    path: str
    version: str
    #: The key under `clinical_review:` this file's sign-offs go in.
    review_key: str
    #: `id` in four of them, `rsid` in variants.
    id_key: str
    entries: tuple[ReviewableEntry, ...]


@dataclass(frozen=True)
class Signature:
    """What a clinician signed, as the surface received it."""

    entry_id: str
    content_sha256: str
    reviewer: str
    reviewed_at: str


# ── Reading each file in its own dialect ─────────────────────────────────────
#
# One function per catalog, each returning the uniform shape. Deliberately not
# generalised further: the differences are real and five small readers are
# easier to check against five files than one reader with five branches in it.

def _biomarkers() -> Catalogue:
    version, markers = catalog.load_catalog()
    entries = []
    for marker_id, marker in markers.items():
        review = catalog.review_status(marker_id)
        entries.append(ReviewableEntry(
            catalogue="biomarkers",
            entry_id=marker_id,
            label=f"{marker.name} ({marker.system}, {marker.canonical_unit})",
            fingerprint=catalog.marker_fingerprint(marker_id),
            signed=review.reviewed,
            reviewer=review.reviewer,
            reviewed_at=review.reviewed_at,
        ))
    return Catalogue(
        name="biomarkers",
        path=f"{_DATA}/biomarkers.v1.yaml",
        version=version,
        review_key="markers",
        id_key="id",
        entries=tuple(entries),
    )


def _supplements() -> Catalogue:
    version, rules = supplement_rules.load_rules()
    entries = []
    for rule_id, rule in rules.items():
        review = supplement_rules.review_status(rule_id)
        entries.append(ReviewableEntry(
            catalogue="supplements",
            entry_id=rule_id,
            label=f"{rule.supplement} for {rule.biomarker_id} ({rule.trigger})",
            fingerprint=supplement_rules.rule_fingerprint(rule_id),
            signed=review.reviewed,
            reviewer=review.reviewer,
            reviewed_at=review.reviewed_at,
        ))
    return Catalogue(
        name="supplements",
        path=f"{_DATA}/supplements.v1.yaml",
        version=version,
        review_key="rules",
        id_key="id",
        entries=tuple(entries),
    )


def _correlations() -> Catalogue:
    version, pairs = correlation_mechanisms.load_pairs()
    entries = []
    for pair_id, pair in pairs.items():
        # A tautological pair is never tested and never reported, so there is
        # nothing for anybody to sign and listing it would pad the queue with
        # work that cannot be done. Only the mechanism sentences are signable.
        if pair.verdict != "mechanism":
            continue
        review = correlation_mechanisms.review_status(pair_id)
        entries.append(ReviewableEntry(
            catalogue="correlations",
            entry_id=pair_id,
            label=f"{pair.first} & {pair.second} — expects {pair.expect}",
            fingerprint=correlation_mechanisms.pair_fingerprint(pair_id),
            signed=review.reviewed,
            reviewer=review.reviewer,
            reviewed_at=review.reviewed_at,
        ))
    return Catalogue(
        name="correlations",
        path=f"{_DATA}/correlations.v1.yaml",
        version=version,
        review_key="pairs",
        id_key="id",
        entries=tuple(entries),
    )


def _therapies() -> Catalogue:
    version, modalities = therapy_catalog.load_modalities()
    entries = []
    for modality in modalities.values():
        # Per modality AND metric: agreeing that a sauna raises heart rate is
        # not agreeing that it raises temperature, which is why the catalog
        # fingerprints each effect separately.
        for effect in modality.effects:
            key = therapy_catalog.effect_id(modality.id, effect.metric)
            review = therapy_catalog.review_status(modality.id, effect.metric)
            entries.append(ReviewableEntry(
                catalogue="therapies",
                entry_id=key,
                label=(
                    f"{modality.label}: {effect.metric} "
                    f"expects {effect.expect}"
                ),
                fingerprint=therapy_catalog.effect_fingerprint(key),
                signed=review.reviewed,
                reviewer=review.reviewer,
                reviewed_at=review.reviewed_at,
            ))
    return Catalogue(
        name="therapies",
        path=f"{_DATA}/therapies.v1.yaml",
        version=version,
        review_key="effects",
        id_key="id",
        entries=tuple(entries),
    )


def _variants() -> Catalogue:
    version, variants = variant_catalog.load_variants()
    entries = []
    for rsid, variant in variants.items():
        review = variant_catalog.review_status(rsid)
        entries.append(ReviewableEntry(
            catalogue="variants",
            entry_id=rsid,
            label=f"{variant.gene} — {variant.trait or 'wellness variant'}",
            fingerprint=variant_catalog.variant_fingerprint(rsid),
            signed=review.reviewed,
            reviewer=review.reviewer,
            reviewed_at=review.reviewed_at,
        ))
    return Catalogue(
        name="variants",
        path=f"{_DATA}/variants.v1.yaml",
        version=version,
        # The one that is not `id`. Four files out of five is exactly the ratio
        # that produces a surface which works on four of them.
        review_key="variants",
        id_key="rsid",
        entries=tuple(entries),
    )


#: Ordered oldest first, which is also roughly order of consequence: the nine
#: PhenoAge markers at the top are what unblock a biological age.
_READERS: tuple[Callable[[], Catalogue], ...] = (
    _biomarkers, _supplements, _correlations, _therapies, _variants,
)


@lru_cache(maxsize=1)
def catalogues() -> tuple[Catalogue, ...]:
    """All five, read the same way. Cached like the loaders under it, for the
    same reason: the files do not change at runtime."""
    return tuple(read() for read in _READERS)


def clear_caches() -> None:
    """Every test that repoints a catalog path has to clear this as well as
    the loader's own — the F8 report's note about `lru_cache` on every catalog
    loader, now with one more cache in the chain."""
    catalogues.cache_clear()


def get(name: str) -> Catalogue | None:
    return next((c for c in catalogues() if c.name == name), None)


def pending() -> tuple[ReviewableEntry, ...]:
    """Everything nobody has signed, across all five."""
    return tuple(
        entry
        for catalogue in catalogues()
        for entry in catalogue.entries
        if not entry.signed
    )


def summary() -> dict:
    """The counts for the admin dashboard.

    Reported per file as well as in total, because "117 unsigned" is a number
    nobody can act on and "nine markers unsigned, and they are the nine that
    unblock biological age" is a morning's work.
    """
    per_catalogue = {}
    for catalogue in catalogues():
        signed = sum(1 for entry in catalogue.entries if entry.signed)
        per_catalogue[catalogue.name] = {
            "path": catalogue.path,
            "version": catalogue.version,
            "total": len(catalogue.entries),
            "signed": signed,
            "unsigned": len(catalogue.entries) - signed,
        }
    return {
        "catalogues": per_catalogue,
        "total": sum(c["total"] for c in per_catalogue.values()),
        "signed": sum(c["signed"] for c in per_catalogue.values()),
        "unsigned": sum(c["unsigned"] for c in per_catalogue.values()),
    }


def fingerprint_for(name: str, entry_id: str) -> str | None:
    """The hash a signature for this entry has to be over, right now."""
    catalogue = get(name)
    if catalogue is None:
        return None
    return next(
        (e.fingerprint for e in catalogue.entries if e.entry_id == entry_id), None
    )


def signoff_block(name: str, signatures: list[Signature]) -> str:
    """The `clinical_review:` block to commit into that file.

    Refuses rather than renders when a hash no longer matches what is in the
    file. A block carrying a stale hash is worse than no block: it looks
    committed, the loader ignores it, and the screen still says nobody has
    reviewed this — with a clinician's name sitting in git against it.
    """
    catalogue = get(name)
    if catalogue is None:
        raise StaleSignature(f"{name} is not a reviewable catalogue")

    current = {entry.entry_id: entry.fingerprint for entry in catalogue.entries}
    for signature in signatures:
        expected = current.get(signature.entry_id)
        if expected is None:
            raise StaleSignature(
                f"{name}: {signature.entry_id} is not an entry in "
                f"{catalogue.path} — it has been renamed or removed since it "
                "was signed"
            )
        if expected != signature.content_sha256:
            raise StaleSignature(
                f"{name}: {signature.entry_id} has changed since it was "
                f"signed. The signature is over {signature.content_sha256[:12]}… "
                f"and the file now hashes to {expected[:12]}…, so it needs "
                "reading again rather than committing"
            )

    rows = "".join(
        f"    - {catalogue.id_key}: {s.entry_id}\n"
        f'      reviewer: "{s.reviewer}"\n'
        f'      reviewed_at: "{s.reviewed_at}"\n'
        f'      content_sha256: "{s.content_sha256}"\n'
        for s in signatures
    )
    return f"clinical_review:\n  {catalogue.review_key}:\n{rows}"
