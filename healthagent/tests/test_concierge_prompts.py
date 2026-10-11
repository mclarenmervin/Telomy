"""The concierge's system prompt.

A prompt is not a gate — every rule that matters here is also enforced
deterministically after the model speaks, and the tests for those live beside
the code that enforces them. What is worth asserting here is the opposite
direction: that the prompt does not quietly undo a gate by inviting the model
to do something the gate will then refuse, and that it carries no data the
model is supposed to fetch with a tool.
"""

from app.concierge.prompts import build_system_prompt
from app.concierge.state import ConciergeContext


def state(**kw):
    base = {"profile": {"displayName": "Asha"}, "safety_facts": [], "escalations": []}
    base.update(kw)
    return base


def prompt(**kw):
    return build_system_prompt(state(**kw), ConciergeContext(user_id="u1"))


def test_the_prompt_carries_no_measurements_at_all():
    """Grounding is a tool call, never a recollection. A number in the prompt
    is a number the model can recite without the tool that owns it — and the
    figure check admits only what a tool returned this turn, so a prompt-fed
    value would be refused anyway. This is the one rule where the prompt and
    the gate have to agree in advance."""
    text = prompt()

    assert "68" not in text
    assert "mg/dL" not in text


def test_the_prompt_tells_the_model_to_quote_a_signed_finding_in_full():
    """The gate exempts a verbatim body and nothing else, so a prompt that
    invited paraphrase would be a prompt that produces refused replies."""
    text = build_system_prompt(state(), None).lower()

    assert "word for word" in text or "verbatim" in text
    assert "paraphras" in text


def test_the_prompt_forbids_promising_a_review():
    text = build_system_prompt(state(), None).lower()

    assert "promise" in text
    assert "clinician will" in text or "will look at" in text


def test_the_prompt_forbids_grading_a_lab_value():
    """Our reference ranges are not clinically signed off, so the app shows
    every value without a verdict and the model must do the same."""
    text = build_system_prompt(state(), None).lower()

    assert "normal" in text
    assert "range" in text


def test_the_users_own_words_are_marked_as_data():
    text = build_system_prompt(state(), None).lower()

    assert "data" in text
    assert "instruction" in text


def test_the_name_is_used_when_known():
    assert "Asha" in prompt()


def test_an_unknown_name_does_not_become_a_placeholder():
    text = build_system_prompt(state(profile={}), ConciergeContext(user_id="u1"))

    assert "unknown" in text.lower()
    assert "{" not in text


def test_recorded_medications_are_passed_as_data_not_as_something_to_mention():
    text = prompt(safety_facts=[{"kind": "medication", "name": "atenolol"}])

    assert "atenolol" in text
    assert "never name" in text.lower() or "do not name" in text.lower()


def test_an_open_critical_value_tells_the_model_not_to_reassure():
    """The escalation line is appended deterministically whatever the model
    says. Without this the two contradict each other: "nothing to worry about"
    followed by "seek medical care right away"."""
    text = prompt(escalations=[{
        "biomarker_id": "potassium", "value_canonical": 7.0, "unit": "mmol/L",
        "message": "Potassium is critically high.",
    }]).lower()

    assert "reassur" in text
    assert "potassium" in text


def test_nothing_urgent_means_no_urgency_section():
    assert "critically high" not in prompt()


def test_the_prompt_never_suggests_giving_a_phone_number():
    text = build_system_prompt(state(), None).lower()

    assert "contact details" in text or "phone number" in text
