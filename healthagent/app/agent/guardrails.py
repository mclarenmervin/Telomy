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

from app.common.logging_config import get_logger
from app.common.thresholds import get_thresholds

logger = get_logger(__name__)

# Shared with the activity agent's severity rules; a local copy meant tuning
# SPO2_DANGER_MIN moved one and not the other.
SPO2_LOW = get_thresholds().spo2_danger_min
# Deliberately NOT centralised: this describes a resting-ish context for the event
# agent. The activity agent uses a much higher exercise-aware ceiling.
HEART_RATE_HIGH = 150.0


# ── Who is going to read this? ───────────────────────────────────────────────
#
# The rules above exist because text was on its way to a user with no human in
# between. F5 adds a second audience and the right consequence differs.
#
#: Text goes straight to the user. A diagnosis or medication match replaces it.
#: Today's behaviour, unchanged, and the default — every existing caller passes
#: two arguments and must keep behaving byte-identically.
AUTONOMOUS = "autonomous"

#: Text goes to a clinician's review queue. The same matches attach routing
#: flags and the text is left alone, because in this profile the rules above
#: would blank out exactly the content the clinician is there to judge: a
#: supplement draft becomes SAFE_FALLBACK and the queue fills with drafts that
#: say nothing.
#:
#: This is only safe because of the other half, in 013_clinical_review.sql: a
#: draft carrying any routing flag can never be delivered without a signature,
#: so the uncensored text cannot reach the user by the SLA path that exists for
#: observations nobody reviewed. The flag is what makes that gate bite. Neither
#: half is safe alone.
CLINICIAN_QUEUE = "clinician_queue"

PROFILES = (AUTONOMOUS, CLINICIAN_QUEUE)


def _matches(patterns, text: str) -> bool:
    return any(p.search(text) for p in patterns)


def _dangerous_values(analysis: dict) -> bool:
    metrics = analysis.get("metrics", {})
    spo2 = metrics.get("spo2", {}).get("during_mean")
    heart_rate = metrics.get("heartRate", {}).get("during_mean")
    return (spo2 is not None and spo2 < SPO2_LOW) or (
        heart_rate is not None and heart_rate > HEART_RATE_HIGH
    )


def apply_guardrails(
    text: str, analysis: dict, profile: str = AUTONOMOUS
) -> tuple[str, list[str]]:
    """Deterministic checks after the LLM has spoken.

    Detection is identical in both profiles and only the consequence differs:
    `autonomous` replaces the text, `clinician_queue` labels it. They must not
    disagree about what counts as medication content — a draft that reached a
    user unflagged, carrying text the autonomous profile would have replaced,
    is the exact failure the flags exist to prevent.
    """
    if profile not in PROFILES:
        # A typo at a call site must not become a censorship bypass. Falling
        # back to the stricter profile makes a mistake over-cautious; falling
        # back the other way would put unreviewed medication advice on a
        # user's screen. Loud, because this is a safety boundary and not a
        # config nuisance.
        logger.error(
            f"unknown guardrail profile {profile!r}; using {AUTONOMOUS}"
        )
        profile = AUTONOMOUS

    flags: list[str] = []
    if _matches(_DIAGNOSIS, text):
        flags.append("diagnosis")
    if _matches(_MEDICATION, text):
        flags.append("medication")
    if flags and profile == AUTONOMOUS:
        text = SAFE_FALLBACK

    # Never gated on the profile, and deliberately after the replacement above
    # so the line survives either outcome. A dangerous reading is an emergency
    # whoever is reading the text, and the clinician queue is for
    # recommendations — exactly as `is_critical` is ungated in the lab path.
    if _dangerous_values(analysis):
        text = f"{text} {ESCALATION_LINE}"
        flags.append("escalation")

    return text, flags
