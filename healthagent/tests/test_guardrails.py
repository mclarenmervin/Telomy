import pytest

from app.agent.guardrails import SAFE_FALLBACK, apply_guardrails

CLEAN = "Your heart rate rose about 22 bpm above your usual level during this session."


def analysis(spo2=97.0, heart_rate=80.0):
    return {
        "data_quality": "full",
        "metrics": {
            "spo2": {"during_mean": spo2},
            "heartRate": {"during_mean": heart_rate},
        },
    }


def test_clean_text_passes_unchanged():
    text, flags = apply_guardrails(CLEAN, analysis())

    assert text == CLEAN
    assert flags == []


@pytest.mark.parametrize(
    "unsafe",
    [
        "This is a clear diagnosis of atrial fibrillation.",
        "You likely have a heart condition.",
        "You probably have an infection.",
    ],
)
def test_diagnosis_is_blocked(unsafe):
    text, flags = apply_guardrails(unsafe, analysis())

    assert text == SAFE_FALLBACK
    assert flags == ["diagnosis"]


@pytest.mark.parametrize(
    "unsafe",
    [
        "You should take 20 mg of your medication now.",
        "Consider stopping your medication tonight.",
        "Increase the dose if it happens again.",
    ],
)
def test_medication_and_dosage_advice_is_blocked(unsafe):
    text, flags = apply_guardrails(unsafe, analysis())

    assert text == SAFE_FALLBACK
    assert flags == ["medication"]


def test_low_spo2_adds_escalation_line():
    text, flags = apply_guardrails(CLEAN, analysis(spo2=88.0))

    assert text.startswith(CLEAN)
    assert "seek medical" in text.lower()
    assert flags == ["escalation"]


def test_very_high_heart_rate_adds_escalation_line():
    text, flags = apply_guardrails(CLEAN, analysis(heart_rate=165.0))

    assert "seek medical" in text.lower()
    assert flags == ["escalation"]


def test_missing_metrics_do_not_crash_escalation_check():
    text, flags = apply_guardrails(CLEAN, {"data_quality": "none", "metrics": {}})

    assert text == CLEAN
    assert flags == []


def test_supplement_recommendations_are_blocked():
    """The obvious workaround to a medication-only rule, and less regulated."""
    for text in (
        "You should try magnesium to help your recovery.",
        "Consider taking a vitamin D supplement.",
        "Start taking zinc before bed.",
        "Adding creatine would help here.",
    ):
        cleaned, flags = apply_guardrails(text, {"metrics": {}})

        assert "medication" in flags, text
        assert cleaned == SAFE_FALLBACK


def test_merely_naming_a_nutrient_is_not_blocked():
    """Blocking the word outright would censor ordinary nutrition talk."""
    text = "Leafy greens are a good source of magnesium."

    cleaned, flags = apply_guardrails(text, {"metrics": {}})

    assert flags == []
    assert cleaned == text
