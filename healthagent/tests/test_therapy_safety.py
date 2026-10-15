"""Therapy contraindications are deterministic hard gates, never warnings."""

import pytest

from app.analytics.therapy_safety import RULE_VERSION, screen_therapy


SAFE = {
    "pregnancy_status": "not_pregnant",
    "pacemaker": False,
    "uncontrolled_blood_pressure": False,
    "recent_cardiac_event": False,
    "raynaud": False,
    "untreated_pneumothorax": False,
    "dvt": False,
    "g6pd_deficiency": False,
    "coronary_plaque": False,
    "alcohol_today": False,
    "medications": [],
    "medications_known": True,
}


@pytest.mark.parametrize(("modality", "fact", "value", "reason"), [
    ("sauna", "pregnancy_status", "pregnant", "pregnancy"),
    ("pemf", "pacemaker", True, "pacemaker"),
    ("sauna", "uncontrolled_blood_pressure", True, "uncontrolled_blood_pressure"),
    ("sauna", "recent_cardiac_event", True, "recent_cardiac_event"),
    ("cold_plunge", "raynaud", True, "raynaud"),
    ("hbot", "untreated_pneumothorax", True, "untreated_pneumothorax"),
    ("compression", "dvt", True, "dvt"),
    ("iv_vitamin_c", "g6pd_deficiency", True, "g6pd_deficiency"),
    ("sauna", "alcohol_today", True, "alcohol_today"),
    ("cryotherapy", "coronary_plaque", True, "coronary_plaque"),
])
def test_each_named_contraindication_is_a_hard_refusal(
    modality, fact, value, reason
):
    decision = screen_therapy(modality, {**SAFE, fact: value})

    assert decision.eligible is False
    assert reason in decision.reason_codes
    assert decision.rule_version == RULE_VERSION
    assert decision.explanations


def test_photosensitising_medicine_refuses_red_light():
    decision = screen_therapy(
        "red_light", {**SAFE, "medications": [{"title": "Doxycycline 100 mg"}]}
    )

    assert decision.eligible is False
    assert decision.reason_codes == ("photosensitising_medication",)


def test_an_unrelated_medicine_does_not_trigger_the_rule():
    decision = screen_therapy(
        "red_light", {**SAFE, "medications": [{"title": "Metformin 500 mg"}]}
    )

    assert decision.eligible is True
    assert decision.reason_codes == ()


def test_unknown_required_fact_fails_closed():
    facts = dict(SAFE)
    facts.pop("untreated_pneumothorax")

    decision = screen_therapy("hbot", facts)

    assert decision.eligible is False
    assert decision.reason_codes == ("untreated_pneumothorax_unknown",)


def test_unknown_pregnancy_status_fails_closed_when_the_rule_applies():
    decision = screen_therapy("sauna", {**SAFE, "pregnancy_status": "unknown"})

    assert decision.eligible is False
    assert decision.reason_codes == ("pregnancy_status_unknown",)


def test_safe_facts_pass_every_rule_for_a_modality():
    decision = screen_therapy("contrast_therapy", SAFE)

    assert decision.eligible is True
    assert decision.reason_codes == ()


def test_a_modality_with_no_hard_rules_still_returns_a_versioned_decision():
    decision = screen_therapy("float_therapy", {})

    assert decision.eligible is True
    assert decision.rule_version == RULE_VERSION


def test_every_shipped_catalogue_rule_has_an_implementation():
    from app.analytics.therapy_catalog import load_modalities

    _, modalities = load_modalities()

    for modality_id in modalities:
        assert screen_therapy(modality_id, SAFE).eligible, modality_id


def test_unknown_modality_is_refused_instead_of_skipping_safety():
    with pytest.raises(ValueError, match="unknown therapy modality"):
        screen_therapy("made_up", SAFE)
