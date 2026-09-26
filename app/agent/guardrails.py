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
_MEDICATION = [
    re.compile(r"\b\d+(?:\.\d+)?\s?(?:mg|mcg|ml|milligrams?)\b", re.I),
    re.compile(
        r"\b(?:stop|stopping|skip|skipping|increase|decrease|double|halve|start|starting|"
        r"take|taking|change|changing)\b[^.]{0,40}\b(?:medication|medications|medicine|dose|"
        r"dosage|pills?|tablets?|prescription)\b",
        re.I,
    ),
]

SPO2_LOW = 90.0
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
