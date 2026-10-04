from types import SimpleNamespace

from app.agent.narration import build_prompt, fallback_summary, narrate

FULL = {
    "data_quality": "full",
    "metrics": {
        "heartRate": {"baseline_mean": 60.0, "during_mean": 82.0, "delta_during": 22.0},
        "hrv": {"baseline_mean": 55.0, "during_mean": 40.0, "delta_during": -15.0},
        "temperature": {"baseline_mean": None, "during_mean": None, "delta_during": None},
        "spo2": {"baseline_mean": 97.0, "during_mean": 96.0, "delta_during": -1.0},
    },
}
NONE = {"data_quality": "none", "metrics": {}}


class FakeLLM:
    """Stands in for a LangChain chat model: invoke(messages) -> object with .content."""

    def __init__(self, reply="LLM says hello", fail=False):
        self.reply = reply
        self.fail = fail
        self.calls = []

    def invoke(self, messages):
        system = next(text for role, text in messages if role == "system")
        user = next(text for role, text in messages if role == "human")
        self.calls.append((system, user))
        if self.fail:
            raise RuntimeError("api down")
        return SimpleNamespace(content=self.reply)


def test_fallback_mentions_computed_numbers_and_event():
    text = fallback_summary("alcohol", FULL)

    assert "alcohol" in text
    assert "82" in text and "22" in text
    assert "hrv" in text.lower()


def test_fallback_with_no_data_says_readings_are_missing():
    text = fallback_summary("sauna", NONE)

    assert "sauna" in text
    assert "don't have" in text.lower()


def test_prompt_contains_computed_numbers_and_safety_rules():
    system, user = build_prompt("alcohol", FULL)

    assert "82" in user and "22" in user
    assert "diagnos" in system.lower()
    assert "medication" in system.lower()


def test_narrate_uses_llm_when_available():
    llm = FakeLLM("Your heart rate rose during the session.")

    assert narrate(llm, "alcohol", FULL) == "Your heart rate rose during the session."
    assert len(llm.calls) == 1


def test_narrate_falls_back_when_llm_fails():
    text = narrate(FakeLLM(fail=True), "alcohol", FULL)

    assert text == fallback_summary("alcohol", FULL)


def test_narrate_falls_back_when_llm_returns_empty():
    text = narrate(FakeLLM(reply="   "), "alcohol", FULL)

    assert text == fallback_summary("alcohol", FULL)


def test_narrate_without_llm_uses_fallback():
    assert narrate(None, "alcohol", FULL) == fallback_summary("alcohol", FULL)


def test_narrate_skips_llm_when_there_is_no_data():
    llm = FakeLLM()

    text = narrate(llm, "alcohol", NONE)

    assert llm.calls == []
    assert text == fallback_summary("alcohol", NONE)


from app.analytics.check_in import CheckIn  # noqa: E402
from app.agent.narration import (  # noqa: E402
    build_check_in_prompt,
    check_in_fallback,
    narrate_check_in,
)

CHECK_IN = CheckIn("hr_elevated", "Heart rate is running 16 bpm above the baseline.")


def test_check_in_fallback_states_the_fact_and_names_the_event():
    text = check_in_fallback("alcohol", CHECK_IN)

    assert "16 bpm" in text
    assert "alcohol" in text


def test_check_in_prompt_carries_the_fact_and_forbids_diagnosis():
    system, user = build_check_in_prompt("alcohol", CHECK_IN, {"data_quality": "full"})

    assert "diagnos" in system.lower()
    assert "right now" in system.lower() or "happening" in system.lower()
    assert "16 bpm" in user
    assert "alcohol" in user


def test_narrate_check_in_uses_the_llm_reply():
    llm = FakeLLM("Your heart rate is climbing — worth easing off.")

    text = narrate_check_in(llm, "alcohol", CHECK_IN, {"data_quality": "full"})

    assert text == "Your heart rate is climbing — worth easing off."


def test_narrate_check_in_falls_back_without_an_llm_and_never_goes_silent():
    text = narrate_check_in(None, "alcohol", CHECK_IN, {"data_quality": "full"})

    assert "16 bpm" in text


def test_narrate_check_in_falls_back_when_the_llm_raises():
    text = narrate_check_in(FakeLLM(fail=True), "alcohol", CHECK_IN, {"data_quality": "full"})

    assert "16 bpm" in text


def test_narrate_check_in_falls_back_on_an_empty_reply():
    text = narrate_check_in(FakeLLM("   "), "alcohol", CHECK_IN, {"data_quality": "full"})

    assert "16 bpm" in text
