"""Emergency language must be caught before anything else happens to a message.

This is a supplementary safeguard, not an emergency service, and it is screened
deterministically — a model that has a bad generation must not be the thing
standing between someone in crisis and a phone number.
"""

import pytest

from app.analytics.safety import EMERGENCY_RESPONSE, screen_for_emergency

MEDICAL = [
    "I have crushing chest pain and my left arm is numb",
    "my chest hurts and I can't breathe",
    "I think I'm having a heart attack",
    "I can't breathe properly",
    "the left side of my face has gone droopy and I can't speak properly",
    "I'm coughing up blood",
    "I took too many of my pills",
]

PSYCHOLOGICAL = [
    "I want to kill myself",
    "I'm thinking about ending my life",
    "I don't want to be alive anymore",
    "I'm going to hurt myself tonight",
]

ORDINARY = [
    "my heart rate was high during the sauna",
    "I had chest congestion from a cold last week",
    "my resting heart rate is up 4 bpm",
    "this training block is killing my legs",
    "I'm dead tired after that session",
    "how do I improve my HRV?",
    "my sleep score dropped and I feel breathless on the stairs lately",
]


@pytest.mark.parametrize("text", MEDICAL)
def test_medical_emergencies_are_caught(text):
    result = screen_for_emergency(text)

    assert result is not None
    assert result.category == "medical"


@pytest.mark.parametrize("text", PSYCHOLOGICAL)
def test_psychological_emergencies_are_caught(text):
    result = screen_for_emergency(text)

    assert result is not None
    assert result.category == "psychological"


@pytest.mark.parametrize("text", ORDINARY)
def test_ordinary_health_talk_is_not_an_emergency(text):
    """False positives are not harmless: a product that cries emergency at
    'this workout is killing me' gets its warnings ignored."""
    assert screen_for_emergency(text) is None


def test_the_response_names_a_concrete_action_and_disclaims_itself():
    result = screen_for_emergency("I want to kill myself")

    assert "emergency" in result.response.lower()
    assert EMERGENCY_RESPONSE["psychological"] == result.response


def test_the_matched_rule_is_reported_for_audit_but_not_the_text():
    result = screen_for_emergency("I think I'm having a heart attack")

    assert result.matched_rule
    assert "heart attack" not in result.matched_rule


def test_empty_and_none_input_are_safe():
    assert screen_for_emergency("") is None
    assert screen_for_emergency(None) is None


def test_matching_ignores_case_and_punctuation_padding():
    assert screen_for_emergency("  I WANT TO KILL MYSELF!!!  ") is not None
