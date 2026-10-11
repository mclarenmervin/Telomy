"""Loads the therapy effect catalog and checks it is coherent.

The sibling of `correlation_mechanisms.py`, for a different shape of claim.
A correlation says two things moved together; an entry here says this
intervention does this to that signal, in this direction, which is a stronger
statement and needs the same discipline: a named mechanism, a citation, and a
signature bound to both.

The arithmetic in `therapy_effect.py` can tell you that heart rate was eleven
beats higher after somebody's sauna sessions than before them. Nothing in the
arithmetic can tell you whether that is the sauna, and a person who uses the
sauna after training would get a confident, cited, entirely wrong sentence.

**Acute only.** Every effect here is the hour after a session against the hour
before it. Chronic adaptation is a different question on a different timescale
and often runs the other way -- sauna raises heart rate for the hour after and
lowers resting heart rate over months -- so the two must not share a file, a
direction, or a test.
"""

import re
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path

import yaml

from app.analytics.catalog import CatalogError, ClinicalReview, content_fingerprint
from app.analytics.event_analysis import TRACKED

MODALITIES_PATH = Path(__file__).parent / "data" / "therapies.v1.yaml"

INCREASE = "increase"
DECREASE = "decrease"
DIRECTIONS = (INCREASE, DECREASE)


class TherapyCatalogError(CatalogError):
    """The catalog is not internally coherent. Never caught — fail loudly."""


@dataclass(frozen=True)
class Effect:
    """One signal a modality is expected to move, and which way."""

    metric: str
    expect: str
    mechanism: str
    citation: str


@dataclass(frozen=True)
class Modality:
    """One therapy, the event types that are it, and what it is expected to do."""

    id: str
    label: str
    event_types: tuple[str, ...]
    effects: tuple[Effect, ...]


def _text(raw, key: str) -> str:
    value = raw.get(key)
    if isinstance(value, str):
        return " ".join(value.split())
    return ""


def effect_id(modality_id: str, metric: str) -> str:
    """The one name for a modality-and-metric hypothesis."""
    return f"{modality_id}__{metric}"


def _build_effect(raw: dict, modality_id: str) -> Effect:
    if not isinstance(raw, dict):
        raise TherapyCatalogError(f"{modality_id}: an effect is not a mapping")

    metric = str(raw.get("metric") or "").strip()
    if metric not in TRACKED:
        raise TherapyCatalogError(
            f"{modality_id}: {metric!r} is not a signal the event analysis "
            "tracks, so this effect could never be computed"
        )

    expect = str(raw.get("expect") or "").strip()
    if expect not in DIRECTIONS:
        raise TherapyCatalogError(
            f"{modality_id}/{metric}: must predict a direction -- without one "
            "any change in any direction would be reported as the mechanism"
        )

    mechanism = _text(raw, "mechanism")
    if not mechanism:
        raise TherapyCatalogError(f"{modality_id}/{metric}: carries no mechanism")
    citation = _text(raw, "citation")
    if not citation:
        raise TherapyCatalogError(f"{modality_id}/{metric}: carries no citation")

    return Effect(metric=metric, expect=expect, mechanism=mechanism, citation=citation)


def _build(entry: dict) -> Modality:
    if not isinstance(entry, dict):
        raise TherapyCatalogError(f"a modality entry is not a mapping: {entry!r}")

    modality_id = str(entry.get("id") or "").strip()
    if not modality_id:
        raise TherapyCatalogError(f"a modality entry has no id: {entry!r}")

    event_types = tuple(
        str(t).strip() for t in (entry.get("event_types") or []) if str(t).strip()
    )
    if not event_types:
        raise TherapyCatalogError(
            f"{modality_id}: names no event type, so no session of it could "
            "ever reach the engine and the failure would be silent"
        )

    effects = tuple(
        _build_effect(raw, modality_id) for raw in (entry.get("effects") or [])
    )
    if not effects:
        raise TherapyCatalogError(f"{modality_id}: declares no effects")

    seen = [e.metric for e in effects]
    if len(set(seen)) != len(seen):
        raise TherapyCatalogError(f"{modality_id}: declares a metric twice")

    return Modality(
        id=modality_id,
        label=_text(entry, "label") or modality_id,
        event_types=event_types,
        effects=effects,
    )


@dataclass(frozen=True)
class _SignedEffect:
    reviewer: str
    reviewed_at: str
    content_sha256: str


def _parse_signoffs(raw: dict, where: str) -> dict[str, _SignedEffect]:
    block = raw.get("clinical_review") or {}
    if not isinstance(block, dict):
        raise TherapyCatalogError(f"{where}: clinical_review must be a mapping")
    entries = block.get("effects") or []
    if not isinstance(entries, list):
        raise TherapyCatalogError(f"{where}: clinical_review.effects must be a list")

    out: dict[str, _SignedEffect] = {}
    for entry in entries:
        if not isinstance(entry, dict):
            raise TherapyCatalogError(f"{where}: a clinical_review entry is not a mapping")
        key = str(entry.get("id") or "").strip()
        if not key:
            raise TherapyCatalogError(f"{where}: a clinical_review entry has no id")
        reviewer = str(entry.get("reviewer") or "").strip()
        reviewed_at = str(entry.get("reviewed_at") or "").strip()
        digest = str(entry.get("content_sha256") or "").strip().lower()

        if not reviewer:
            raise TherapyCatalogError(f"{where}: {key} sign-off names no reviewer")
        if not reviewed_at:
            raise TherapyCatalogError(f"{where}: {key} sign-off carries no reviewed_at")
        if not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise TherapyCatalogError(
                f"{where}: {key} content_sha256 is missing or not a sha256, so it "
                "would be a signature over a name rather than over a mechanism"
            )
        if key in out:
            raise TherapyCatalogError(f"{where}: {key} is signed off twice")

        out[key] = _SignedEffect(reviewer, reviewed_at, digest)
    return out


#: Per-path fingerprints, keyed by path because the tests repoint the file.
_FINGERPRINTS: dict[str, dict[str, str]] = {}


@lru_cache(maxsize=4)
def load_modalities(path: Path | None = None) -> tuple[str, dict[str, Modality]]:
    """(version, {id: Modality}). Cached: the file does not change at runtime."""
    where = str(path or MODALITIES_PATH)
    raw = yaml.safe_load((path or MODALITIES_PATH).read_text())
    version = raw.get("version")
    if not version:
        raise TherapyCatalogError(f"{where}: the file has no version")

    signed = _parse_signoffs(raw, where)

    modalities: dict[str, Modality] = {}
    fingerprints: dict[str, str] = {}
    for entry in raw.get("modalities", []):
        modality = _build(entry)
        if modality.id in modalities:
            raise TherapyCatalogError(f"{modality.id}: declared twice")
        modalities[modality.id] = modality
        # Each effect is signed separately, so each is fingerprinted
        # separately: agreeing that a sauna raises heart rate is not agreeing
        # that it raises temperature.
        for raw_effect in entry.get("effects") or []:
            fingerprints[effect_id(modality.id, raw_effect["metric"])] = (
                content_fingerprint(raw_effect)
            )
    if not modalities:
        raise TherapyCatalogError(f"{where}: declares no modalities")

    orphans = sorted(set(signed) - set(fingerprints))
    if orphans:
        raise TherapyCatalogError(
            f"{where}: clinical_review.effects signs off effects that do not "
            f"exist: {', '.join(orphans)}"
        )

    _FINGERPRINTS[where] = fingerprints
    return version, modalities


def catalog_version(path: Path | None = None) -> str:
    return load_modalities(path)[0]


def effect_fingerprint(key: str, path: Path | None = None) -> str | None:
    load_modalities(path)
    return _FINGERPRINTS.get(str(path or MODALITIES_PATH), {}).get(key)


def modality_for_event(event_type: str, path: Path | None = None) -> Modality | None:
    """Which modality, if any, this event type is a session of."""
    _, modalities = load_modalities(path)
    for modality in modalities.values():
        if event_type in modality.event_types:
            return modality
    return None


@lru_cache(maxsize=None)
def review_status(
    modality_id: str, metric: str, path: Path | None = None
) -> ClinicalReview:
    """Has a clinician signed off this mechanism, and is it still over it?

    The same narrow consequence as the correlation catalog: an unsigned
    mechanism withholds the *explanation*, not the measured change. "Your
    heart rate was 16 bpm higher after your sauna sessions" is a statement
    about measurements; "because heat stress drives vasodilation" is a
    clinical claim.
    """
    where = path or MODALITIES_PATH
    key = effect_id(modality_id, metric)
    raw = yaml.safe_load(where.read_text())
    signed = _parse_signoffs(raw, str(where)).get(key)
    if signed is None or signed.content_sha256 != effect_fingerprint(key, path):
        return ClinicalReview(reviewed=False)
    return ClinicalReview(
        reviewed=True, reviewer=signed.reviewer, reviewed_at=signed.reviewed_at
    )
