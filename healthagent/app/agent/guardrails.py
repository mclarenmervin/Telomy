import re

SAFE_FALLBACK = (
    "I can describe how your readings changed around this event, but I can't give "
    "medical diagnoses or medication advice. Please talk to a clinician about any "
    "health concerns."
)
ESCALATION_LINE = (
    "If you feel unwell, have chest pain, or trouble breathing, seek medical care "
    "right away."
)

_DIAGNOSIS = [
    re.compile(r"\bdiagnos\w*", re.I),
    re.compile(
        r"\byou (?:likely |probably |may |might )?(?:have|are suffering from|suffer from) "
        r"(?:an? )?(?:[\w-]+ ){0,2}(?:disease|disorder|syndrome|infection|cancer|diabetes|"
        r"hypertension|arrhythmia|fibrillation|condition)\b",
        re.I,
    ),
]
_SUPPLEMENT_NAMES = (
    r"supplements?|multivitamins?|vitamins?|minerals?|magnesium|zinc|iron|calcium|"
    r"creatine|collagen|melatonin|omega[- ]?3|fish oil|probiotics?|ashwagandha|"
    r"turmeric|curcumin|caffeine pills?|electrolytes?|beetroot juice|nitrates?|"
    r"coq10|l-?theanine|beta-?alanine|bcaas?|whey|protein powder|glutamine|"
    r"ashwaghanda|rhodiola|st\.? john'?s wort"
)
_MEDICATION = [
    re.compile(r"\b\d+(?:\.\d+)?\s?(?:mg|mcg|ml|milligrams?)\b", re.I),
    re.compile(
        r"\b(?:stop|stopping|skip|skipping|increase|decrease|double|halve|start|starting|"
        r"take|taking|change|changing)\b[^.]{0,40}\b(?:medication|medications|medicine|dose|"
        r"dosage|pills?|tablets?|prescription)\b",
        re.I,
    ),
    # Recommending a supplement, not merely naming one. The earlier version required a
    # verb from a closed list, which left "Magnesium before bed would help you sleep"
    # and "I'd look into creatine" straight through — the same workaround the supplement
    # rule exists to close. Now any recommending construction counts.
    re.compile(
        rf"\b(?:{_SUPPLEMENT_NAMES})\b[^.]{{0,40}}"
        r"\b(?:would help|would make|helps|help|benefit|recommend|worth|good idea|"
        r"before bed|after training|daily)\b",
        re.I,
    ),
    re.compile(
        r"\b(?:take|taking|try|trying|start|starting|add|adding|consider|considering|"
        r"supplement|look into|looking into|benefit from|more of|some)\w*\b"
        rf"[^.]{{0,40}}\b(?:{_SUPPLEMENT_NAMES})\b",
        re.I,
    ),
    # Naming a drug or drug class at all. The prompt feeds the user's own medications in
    # as SAFETY FACTS and forbids repeating them; without this the only enforcement was a
    # verb near a generic noun, so "Your beta-blocker is why your heart rate stayed low"
    # passed clean. Suffixes catch whole classes without maintaining a drug dictionary.
    re.compile(
        r"\b(?:beta[- ]?blocker|ace[- ]?inhibitor|statins?|insulin|inhalers?|"
        r"antidepressants?|antihistamines?|steroids?|diuretics?|anticoagulants?|"
        # Per-suffix minimum stems: 4 keeps "April" out of the -pril class, but
        # "metformin" has only a 3-letter stem, so -formin gets its own bound.
        r"\w{2,}formin|"
        r"\w{4,}(?:olol|statin|pril|sartan|azepam|cillin|profen|tidine|"
        r"zosin|dipine|glutide))\b",
        re.I,
    ),
]

from app.common.thresholds import get_thresholds

# Shared with the activity agent's severity rules; a local copy meant tuning
# SPO2_DANGER_MIN moved one and not the other.
SPO2_LOW = get_thresholds().spo2_danger_min
# Deliberately NOT centralised: this describes a resting-ish context for the event
# agent. The activity agent uses a much higher exercise-aware ceiling.
HEART_RATE_HIGH = 150.0


def _matches(patterns, text: str) -> bool:
    return any(p.search(text) for p in patterns)


def _dangerous_values(analysis: dict) -> bool:
    metrics = analysis.get("metrics", {})
    spo2 = metrics.get("spo2", {}).get("during_mean")
    heart_rate = metrics.get("heartRate", {}).get("during_mean")
    return (spo2 is not None and spo2 < SPO2_LOW) or (
        heart_rate is not None and heart_rate > HEART_RATE_HIGH
    )


def apply_guardrails(text: str, analysis: dict) -> tuple[str, list[str]]:
    flags: list[str] = []
    if _matches(_DIAGNOSIS, text):
        flags.append("diagnosis")
    if _matches(_MEDICATION, text):
        flags.append("medication")
    if flags:
        text = SAFE_FALLBACK

    if _dangerous_values(analysis):
        text = f"{text} {ESCALATION_LINE}"
        flags.append("escalation")

    return text, flags
