import hashlib
import re
from dataclasses import dataclass

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
    # A dose, and deliberately not a concentration. `mg/dL` and `mL/min` are how
    # every lab in the catalog prints a result, and matching them meant a glucose
    # of 92 mg/dL read as medication advice: replaced wholesale in the autonomous
    # profile, and flagged in the clinician profile, which made F5's trend drafts
    # for glucose, creatinine, magnesium, uric acid and eGFR permanently
    # ineligible for the SLA path and certain to strand.
    #
    # The lookahead costs the `mg/kg` form of a weight-based dose, which is rare
    # in consumer-facing text and still caught by the verb rule below and by the
    # drug-name rule. A unit deciding that a human is needed was the worse of the
    # two errors: it made the flag mean nothing.
    re.compile(r"\b\d+(?:\.\d+)?\s?(?:mg|mcg|ml|milligrams?)\b(?!\s*/)", re.I),
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
    # A supplement named next to the act of taking it, which is how a clinical
    # source phrases a recommendation and how a reviewed rule file states one:
    # "vitamin D supplementation is the usual response to a level this low".
    # Every rule here used to need a recommending verb, so that sentence reached
    # a user untouched and unflagged -- unreviewed supplement advice on a
    # screen, which is the one thing these rules exist to stop. It also decides
    # whether a supplement draft is flagged, and an unflagged one would be
    # eligible for the unreviewed SLA path.
    #
    # A couple of intervening words are allowed because the name and the noun
    # are rarely adjacent: "vitamin D supplementation", "a magnesium
    # supplement", "vitamin D repletion".
    re.compile(
        rf"\b(?:{_SUPPLEMENT_NAMES})\b[\s,)-]*(?:[\w-]+\s+){{0,2}}"
        r"(?:supplementation|supplements?\b|repletion|replacement)",
        re.I,
    ),
    re.compile(
        r"\b(?:supplementing|supplementation|repletion)\b(?:\s+with)?\s+"
        rf"(?:[\w-]+\s+){{0,2}}(?:{_SUPPLEMENT_NAMES})\b",
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


# ── The delivery gate ────────────────────────────────────────────────────────
#
# The last deterministic check between the LLM and the user, which is why it
# lives here beside the others rather than in the clinical package: every
# gate that stands in that gap is in this file.
#
# `013_clinical_review.sql` is the enforcement. A BEFORE INSERT trigger on
# `insights` applies exactly these rules, so they bind the clinician console
# and our own service role alike and nothing can be delivered by going around
# this function. What this half adds is a decision the worker can act on
# *before* writing: an insert it already knows will fail, turned into a reason
# string rather than a 23514 to reverse-engineer out of a log.
#
# The two must agree. Disagreement in either direction is a real bug -- a
# delivery skipped that Postgres would have allowed, or attempted when it would
# not -- so `tests/test_delivery_gate.py` pins the hash against values Postgres
# actually produced.

#: Delivered because a clinician signed exactly this text.
CLINICIAN_SIGNED = "clinician_signed"

#: Delivered unreviewed because the queue stalled. The plan's de-risk for
#: "the clinician queue becomes the bottleneck and the product feels dead",
#: and deliberately the narrowest path in the system.
SLA_EXPIRED = "sla_expired"

#: The only status from which an unsigned delivery is possible. A draft still
#: in the queue has not been given up on, and delivering it would make the
#: queue decorative -- the clinician would arrive to find it already sent.
SLA_DELIVERABLE_STATUS = "expired"


def body_sha256(body: str) -> str:
    """Hex sha256 of an insight body.

    Byte-identical to `encode(sha256(convert_to(body, 'UTF8')), 'hex')`, which
    is what the database stores and compares. Nothing is normalised first --
    not whitespace, not Unicode form -- because a signature over trimmed text
    is a signature over text nobody read.
    """
    return hashlib.sha256(body.encode("utf-8")).hexdigest()


@dataclass(frozen=True)
class DeliveryDecision:
    """Whether this body may reach the user, by which route, and if not why.

    `reason` is for the operator and the queue metrics, and names the draft
    status or the flag that blocked it -- "stalled on 41 supplement drafts" is
    actionable in a way that "delivery refused" is not.
    """

    deliverable: bool
    route: str | None = None
    reason: str | None = None


def _refuse(reason: str) -> DeliveryDecision:
    return DeliveryDecision(deliverable=False, reason=reason)


def gate_delivery(
    draft: dict, review: dict | None, body: str | None = None
) -> DeliveryDecision:
    """May this body be delivered as an insight?

    `body` defaults to the draft's own, which is what delivery normally sends.
    Passing it separately is for a caller that has changed it -- precisely the
    caller this exists to catch.
    """
    status = draft.get("status")
    if status in ("delivered", "withdrawn"):
        # The sweep is not transactional with the insert and the webhook
        # retries, so "already dealt with" is a normal answer, not an error.
        return _refuse(f"draft is {status}")

    if body is None:
        body = draft.get("body")
    if not body:
        return _refuse("draft has no body to deliver")

    if review is None:
        # The unreviewed route. Every condition here is load-bearing: this is
        # the one path that reaches a user without a human having read the
        # text, and widening any of them would quietly undo the gate.
        flags = draft.get("routing_flags") or []
        if flags:
            return _refuse(
                "draft carries routing flags and needs a signature: "
                + ", ".join(sorted(flags))
            )
        if status != SLA_DELIVERABLE_STATUS:
            return _refuse(f"draft is {status}, not {SLA_DELIVERABLE_STATUS}")
        return DeliveryDecision(deliverable=True, route=SLA_EXPIRED)

    if review.get("action") != "signed":
        return _refuse(f"review is a {review.get('action')}, not a signature")

    if review.get("draft_id") != draft.get("id"):
        return _refuse(
            f"review signed draft {review.get('draft_id')}, not {draft.get('id')}"
        )

    if review.get("signed_body_sha256") != body_sha256(body):
        # The gate itself. A status check would have passed every caller above
        # this line, which is the whole reason it is a hash.
        return _refuse("the body being delivered is not the body that was signed")

    return DeliveryDecision(deliverable=True, route=CLINICIAN_SIGNED)
