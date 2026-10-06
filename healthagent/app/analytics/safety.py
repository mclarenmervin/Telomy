"""Emergency language screening, run before anything else touches a message.

Deterministic by design. A model having a bad generation must never be the thing
standing between someone in crisis and a phone number, so this is a fixed,
unit-tested rule set that runs ahead of any AI processing and bypasses the
ordinary response path entirely when it fires.

**This is a supplementary safeguard. It is not an emergency service and must
never be presented as one** — which is why the response says so and directs the
person to real help rather than attempting to manage anything.

False positives are not harmless either: a product that cries emergency at
"this workout is killing me" trains people to ignore its warnings. Patterns are
therefore written to require the phrasing people actually use in distress, not
merely the presence of an alarming noun.
"""

import re
from dataclasses import dataclass

EMERGENCY_RESPONSE = {
    "medical": (
        "What you have described needs urgent medical attention. Please contact "
        "your local emergency number or go to the nearest emergency department "
        "now. I am not an emergency service and cannot help with this."
    ),
    "psychological": (
        "I am sorry you are feeling this way, and I want you to be safe. Please "
        "contact your local emergency number or a crisis helpline right now — in "
        "India you can call Tele-MANAS on 14416, free and open 24 hours. I am not "
        "an emergency service and cannot provide crisis support."
    ),
}

# (rule name, pattern). The name is what gets logged — never the message text.
_MEDICAL_RULES = [
    ("chest_pain_with_radiation", re.compile(
        r"\bchest\b[^.]{0,30}\b(pain|pressure|tight\w*|hurt\w*|crush\w*)\b", re.I)),
    ("heart_attack", re.compile(r"\b(heart attack|cardiac arrest|myocardial)\b", re.I)),
    ("stroke_signs", re.compile(
        r"\b(stroke|face (has )?(gone )?droop\w*|droopy|slurr\w* speech)\b", re.I)),
    ("cannot_breathe", re.compile(
        r"\b(can'?t|cannot|unable to|struggling to)\b[^.]{0,20}\bbreath\w*", re.I)),
    ("coughing_blood", re.compile(
        r"\b(cough\w*|vomit\w*|throwing up)\b[^.]{0,15}\bblood\b", re.I)),
    ("overdose", re.compile(
        r"\b(overdose|took too many)\b[^.]{0,25}\b(pill|tablet|medication|drug)s?\b", re.I)),
    ("unconscious", re.compile(r"\b(passed out|blacked out|lost consciousness)\b", re.I)),
]

_PSYCHOLOGICAL_RULES = [
    ("suicidal_intent", re.compile(
        r"\b(kill myself|end(ing)?\s+(my\s+life|it\s+all)"
        r"|take my own life|suicid\w*)\b", re.I)),
    ("not_want_to_live", re.compile(
        r"\b(don'?t|do not|no longer) want to (be alive|live|wake up)\b", re.I)),
    ("self_harm", re.compile(
        r"\b(hurt|harm|cut)\b[^.]{0,12}\bmyself\b", re.I)),
]


@dataclass(frozen=True)
class EmergencyMatch:
    category: str  # medical | psychological
    matched_rule: str  # the rule name, for audit — never the text that matched
    response: str


def screen_for_emergency(text: str | None) -> EmergencyMatch | None:
    """A match, or None. Psychological risk is checked first: when a message
    carries both, the person is the more urgent half."""
    if not text or not text.strip():
        return None

    for category, rules in (
        ("psychological", _PSYCHOLOGICAL_RULES),
        ("medical", _MEDICAL_RULES),
    ):
        for name, pattern in rules:
            if pattern.search(text):
                return EmergencyMatch(
                    category=category,
                    matched_rule=name,
                    response=EMERGENCY_RESPONSE[category],
                )
    return None
