"""Loads the supplement rule file and checks it is internally coherent.

The sibling of `catalog.py`, for content that makes a stronger claim. A
reference range says what a number means; a rule here says what to do about it,
so it lives in its own file with its own sign-off, signed by its own
professional act. A clinician who agreed vitamin D's reference interval is
30-100 ng/mL has not thereby agreed that a level below it should be
supplemented.

Validation is loud and happens at load time, as it is in the catalog and in
`thresholds.py`: a rule naming a marker that does not exist, or carrying no
citation, is a safety failure rather than a config nuisance. The one validation
that is specific to this file is the trigger -- `below_standard` is the only
accepted value, because recommending a supplement for a value inside the
reference range is optimisation rather than repletion, and adding that is a
clinical decision rather than a typo somebody can make in passing.

Nothing here decides whether a *person* should take a supplement. That is
`analytics/supplements.py`, which applies these rules to one user's results.
"""

import re
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path

import yaml

from app.analytics import catalog
from app.analytics.catalog import CatalogError, ClinicalReview, content_fingerprint

RULES_PATH = Path(__file__).parent / "data" / "supplements.v1.yaml"

#: The only trigger a rule may declare. See the module docstring.
BELOW_STANDARD = "below_standard"


class SupplementRuleError(CatalogError):
    """The rule file is not internally coherent. Never caught — fail loudly."""


@dataclass(frozen=True)
class Interaction:
    """A medication that changes the answer, and why.

    Never a reason to suppress a rule. A match is named in the draft and in its
    evidence, because "this person is on metformin" is exactly the fact that
    makes a recommendation a human's decision rather than an arithmetic one --
    and for several of these the interaction changes the answer entirely rather
    than merely qualifying it.
    """

    medications: tuple[str, ...]
    note: str

    def matched_in(self, text: str) -> str | None:
        """The term that matched, or None.

        Substring matching over what the user recorded, deliberately. A
        medication list is free text typed by a person -- "Metformin 500mg
        BD", "tab. metformin" -- and a tokeniser would miss more than it
        caught. The terms are specific enough that a false positive needs a
        drug name to actually appear.
        """
        haystack = (text or "").lower()
        for term in self.medications:
            if term in haystack:
                return term
        return None


@dataclass(frozen=True)
class SupplementRule:
    """One deficiency and the response to it, as reviewed content.

    `recommendation` is printed verbatim into the draft a clinician signs. The
    code fills in the number, the unit and the range; the sentence comes from
    the file, so the medical wording is reviewed rather than chosen by whoever
    wrote the producer.
    """

    id: str
    biomarker_id: str
    supplement: str
    trigger: str
    recommendation: str
    citation: str
    interactions: tuple[Interaction, ...] = ()


@dataclass(frozen=True)
class _SignedRule:
    reviewer: str
    reviewed_at: str
    content_sha256: str


def _text(raw, key: str) -> str:
    value = raw.get(key)
    if isinstance(value, str):
        return " ".join(value.split())
    return ""


def _interactions(raw: dict, rule_id: str) -> tuple[Interaction, ...]:
    entries = raw.get("interactions") or []
    if not isinstance(entries, list):
        raise SupplementRuleError(f"{rule_id}: interactions must be a list")

    out = []
    for entry in entries:
        if not isinstance(entry, dict):
            raise SupplementRuleError(f"{rule_id}: an interaction is not a mapping")
        terms = entry.get("medications") or []
        if not isinstance(terms, list) or not terms:
            raise SupplementRuleError(
                f"{rule_id}: an interaction names no medications, so nothing "
                "could ever match it"
            )
        note = _text(entry, "note")
        if not note:
            raise SupplementRuleError(
                f"{rule_id}: an interaction carries no note, so a draft would "
                "route to a human without telling them why"
            )
        out.append(
            Interaction(
                medications=tuple(str(t).strip().lower() for t in terms if str(t).strip()),
                note=note,
            )
        )
    return tuple(out)


def _build(entry: dict) -> SupplementRule:
    if not isinstance(entry, dict):
        raise SupplementRuleError(f"a rule entry is not a mapping: {entry!r}")

    rule_id = str(entry.get("id") or "").strip()
    if not rule_id:
        raise SupplementRuleError(f"a rule entry has no id: {entry!r}")

    biomarker_id = str(entry.get("biomarker") or "").strip()
    if not biomarker_id:
        raise SupplementRuleError(f"{rule_id}: names no biomarker")
    # The marker has to exist, or the rule can never fire and the failure is
    # invisible: the queue simply stays empty and nobody can tell whether that
    # is a quiet period or a typo.
    if catalog.get(biomarker_id) is None:
        raise SupplementRuleError(
            f"{rule_id}: biomarker {biomarker_id} is not in the catalog"
        )

    trigger = str(entry.get("trigger") or "").strip()
    if trigger != BELOW_STANDARD:
        raise SupplementRuleError(
            f"{rule_id}: trigger {trigger!r} is not {BELOW_STANDARD!r}, which is "
            "the only one this phase accepts -- recommending for a value inside "
            "the reference range is optimisation, not repletion"
        )

    recommendation = _text(entry, "recommendation")
    if not recommendation:
        raise SupplementRuleError(
            f"{rule_id}: carries no recommendation, which is the sentence a "
            "clinician would be signing"
        )

    citation = _text(entry, "citation")
    if not citation:
        raise SupplementRuleError(f"{rule_id}: carries no citation")

    supplement = _text(entry, "supplement")
    if not supplement:
        raise SupplementRuleError(f"{rule_id}: names no supplement")

    return SupplementRule(
        id=rule_id,
        biomarker_id=biomarker_id,
        supplement=supplement,
        trigger=trigger,
        recommendation=recommendation,
        citation=citation,
        interactions=_interactions(entry, rule_id),
    )


def _parse_signoffs(raw: dict, where: str) -> dict[str, _SignedRule]:
    """Per-rule sign-offs, refusing any claim the file cannot evidence.

    The same three refusals `catalog._parse_marker_reviews` makes, deliberately
    written out again rather than shared: the two blocks are different shapes
    over different content, and the refusal messages are what somebody reads at
    three in the morning when a deploy stops. What *is* shared is
    `content_fingerprint`, because what a signature is over must not differ
    between the two files.
    """
    block = raw.get("clinical_review") or {}
    if not isinstance(block, dict):
        raise SupplementRuleError(f"{where}: clinical_review must be a mapping")
    entries = block.get("rules") or []
    if not isinstance(entries, list):
        raise SupplementRuleError(f"{where}: clinical_review.rules must be a list")

    out: dict[str, _SignedRule] = {}
    for entry in entries:
        if not isinstance(entry, dict):
            raise SupplementRuleError(f"{where}: a clinical_review.rules entry is not a mapping")
        rule_id = str(entry.get("id") or "").strip()
        if not rule_id:
            raise SupplementRuleError(f"{where}: a clinical_review.rules entry has no id")
        reviewer = str(entry.get("reviewer") or "").strip()
        reviewed_at = str(entry.get("reviewed_at") or "").strip()
        digest = str(entry.get("content_sha256") or "").strip().lower()

        if not reviewer:
            raise SupplementRuleError(f"{where}: {rule_id} sign-off names no reviewer")
        if not reviewed_at:
            raise SupplementRuleError(
                f"{where}: {rule_id} sign-off carries no reviewed_at date"
            )
        if not digest:
            raise SupplementRuleError(
                f"{where}: {rule_id} sign-off carries no content_sha256, so it is a "
                "signature over a name rather than over a recommendation"
            )
        if not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise SupplementRuleError(f"{where}: {rule_id} content_sha256 is not a sha256")
        if rule_id in out:
            raise SupplementRuleError(f"{where}: {rule_id} is signed off twice")

        out[rule_id] = _SignedRule(
            reviewer=reviewer, reviewed_at=reviewed_at, content_sha256=digest
        )
    return out


#: Per-path fingerprints, populated by `load_rules`. Keyed by path because the
#: tests repoint RULES_PATH and would otherwise read each other's.
_FINGERPRINTS: dict[str, dict[str, str]] = {}


@lru_cache(maxsize=1)
def load_rules(path: Path | None = None) -> tuple[str, dict[str, SupplementRule]]:
    """(version, {id: SupplementRule}). Cached: the file does not change at runtime."""
    where = str(path or RULES_PATH)
    raw = yaml.safe_load((path or RULES_PATH).read_text())
    version = raw.get("version")
    if not version:
        raise SupplementRuleError(f"{where}: the rule file has no version")

    signed = _parse_signoffs(raw, where)

    rules: dict[str, SupplementRule] = {}
    fingerprints: dict[str, str] = {}
    for entry in raw.get("rules", []):
        rule = _build(entry)
        if rule.id in rules:
            raise SupplementRuleError(f"{rule.id}: declared twice")
        rules[rule.id] = rule
        fingerprints[rule.id] = content_fingerprint(entry)
    if not rules:
        raise SupplementRuleError(f"{where}: declares no rules")

    # A sign-off left behind after a rule was renamed or removed. Ignoring it
    # would leave a reviewer's name in the file against nothing, which reads
    # like coverage we do not have.
    orphans = sorted(set(signed) - set(rules))
    if orphans:
        raise SupplementRuleError(
            f"{where}: clinical_review.rules signs off rules that do not exist: "
            f"{', '.join(orphans)}"
        )

    _FINGERPRINTS[where] = fingerprints
    return version, rules


def rule_fingerprint(rule_id: str) -> str | None:
    """The hash a sign-off for this rule has to match, or None if unknown."""
    load_rules()
    return _FINGERPRINTS.get(str(RULES_PATH), {}).get(rule_id)


def get(rule_id: str) -> SupplementRule | None:
    return load_rules()[1].get(rule_id)


def rules_version() -> str:
    return load_rules()[0]


@lru_cache(maxsize=None)
def rules_for(biomarker_id: str) -> tuple[SupplementRule, ...]:
    """Every rule about this marker, in a stable order."""
    _, rules = load_rules()
    return tuple(
        sorted(
            (r for r in rules.values() if r.biomarker_id == biomarker_id),
            key=lambda r: r.id,
        )
    )


@lru_cache(maxsize=None)
def review_status(rule_id: str) -> ClinicalReview:
    """Has a clinician signed off this rule, and is the signature still over it?

    A sign-off whose hash no longer matches is not returned at all. That is the
    withdrawal: somebody edited the recommendation or the citation after a
    clinician signed it, and the signature is over a sentence that is no longer
    there. A recommendation can therefore stop being deliverable because
    somebody edited the file, which is correct.

    Per rule only. There is deliberately no "the whole file is reviewed"
    shortcut: the catalog has one because thirty-three markers of ranges are a
    coherent thing to take a view on at once, and four independent
    recommendations are not.
    """
    raw = yaml.safe_load(RULES_PATH.read_text())
    signed = _parse_signoffs(raw, str(RULES_PATH)).get(rule_id)
    if signed is None or signed.content_sha256 != rule_fingerprint(rule_id):
        return ClinicalReview(reviewed=False)
    return ClinicalReview(
        reviewed=True, reviewer=signed.reviewer, reviewed_at=signed.reviewed_at
    )
