"""Deterministic hard contraindication screening for therapy.

Every rule consumes an explicitly named structured fact. Missing facts fail
closed for the modalities that need them. This module never reads a user id,
database, free-text condition history, or model output.
"""

from dataclasses import dataclass
import re
from typing import Mapping

from app.analytics import therapy_catalog


RULE_VERSION = "therapy-safety-v1"


@dataclass(frozen=True)
class SafetyDecision:
    eligible: bool
    reason_codes: tuple[str, ...]
    explanations: tuple[str, ...]
    rule_version: str = RULE_VERSION


_EXPLANATIONS = {
    "pregnancy": "This therapy is left out during pregnancy for safety.",
    "pregnancy_status_unknown": (
        "Pregnancy status must be confirmed before this therapy can be booked."
    ),
    "pacemaker": "This therapy is left out because an implanted electronic device is recorded.",
    "uncontrolled_blood_pressure": "This therapy requires controlled blood pressure.",
    "recent_cardiac_event": "This therapy is left out after a recent cardiac event.",
    "raynaud": "This cold exposure is left out because Raynaud disease is recorded.",
    "untreated_pneumothorax": "Hyperbaric therapy cannot proceed with an untreated pneumothorax.",
    "dvt": "Compression or bodywork cannot proceed while DVT is recorded.",
    "photosensitising_medication": "The recorded medicine may increase sensitivity to this light exposure.",
    "g6pd_deficiency": "IV vitamin C cannot proceed while G6PD deficiency is recorded.",
    "alcohol_today": "Heat therapy cannot proceed after alcohol use today.",
    "coronary_plaque": "Whole-body cryotherapy is left out because coronary plaque is recorded.",
}

_BOOLEAN_RULES = frozenset({
    "pacemaker",
    "uncontrolled_blood_pressure",
    "recent_cardiac_event",
    "raynaud",
    "untreated_pneumothorax",
    "dvt",
    "g6pd_deficiency",
    "alcohol_today",
    "coronary_plaque",
})

# A deliberately reviewable, bounded matching list. Drug-class expansion is
# clinical catalogue work; a model or fuzzy similarity must never decide it.
_PHOTOSENSITISING_MEDICATIONS = (
    re.compile(r"\b(doxycycline|tetracycline|minocycline)\b", re.I),
    re.compile(r"\b(amiodarone|isotretinoin|acitretin)\b", re.I),
    re.compile(r"\b(hydrochlorothiazide|chlorthalidone)\b", re.I),
    re.compile(r"\b(ciprofloxacin|levofloxacin)\b", re.I),
)


def _unknown(rule_id: str) -> tuple[str, str]:
    code = f"{rule_id}_unknown"
    return code, f"{rule_id.replace('_', ' ').capitalize()} must be confirmed before booking."


def _medication_text(rows) -> str:
    parts = []
    for row in rows or ():
        if isinstance(row, Mapping):
            parts.extend((str(row.get("title") or ""), str(row.get("notes") or "")))
        else:
            parts.append(str(row))
    return " ".join(parts)


def _evaluate_rule(rule_id: str, facts: Mapping) -> tuple[str, str] | None:
    if rule_id == "pregnancy":
        status = facts.get("pregnancy_status")
        if status in (None, "", "unknown"):
            return "pregnancy_status_unknown", _EXPLANATIONS["pregnancy_status_unknown"]
        if status == "pregnant":
            return rule_id, _EXPLANATIONS[rule_id]
        return None

    if rule_id == "photosensitising_medication":
        if facts.get("medications_known") is not True:
            return _unknown(rule_id)
        text = _medication_text(facts.get("medications"))
        if any(pattern.search(text) for pattern in _PHOTOSENSITISING_MEDICATIONS):
            return rule_id, _EXPLANATIONS[rule_id]
        return None

    if rule_id in _BOOLEAN_RULES:
        value = facts.get(rule_id)
        if not isinstance(value, bool):
            return _unknown(rule_id)
        if value:
            return rule_id, _EXPLANATIONS[rule_id]
        return None

    raise ValueError(f"unknown therapy safety rule: {rule_id}")


def screen_therapy(modality_id: str, facts: Mapping, path=None) -> SafetyDecision:
    """Evaluate every declared hard rule for one catalogue modality."""
    _, modalities = therapy_catalog.load_modalities(path)
    modality = modalities.get(modality_id)
    if modality is None:
        raise ValueError(f"unknown therapy modality: {modality_id}")

    failures = []
    for rule_id in modality.contraindication_rule_ids:
        failure = _evaluate_rule(rule_id, facts)
        if failure is not None:
            failures.append(failure)

    return SafetyDecision(
        eligible=not failures,
        reason_codes=tuple(code for code, _ in failures),
        explanations=tuple(explanation for _, explanation in failures),
    )
