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
