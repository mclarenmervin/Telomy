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


DRUG_COMMENTS = [
    "Your beta-blocker is probably why your heart rate stayed low today.",
    "Since you're on metformin, keep an eye on this.",
    "Your statin may be a factor here.",
    "The lisinopril could explain the lower reading.",
    "Your inhaler use before the session may matter.",
]


def test_commenting_on_a_named_drug_is_blocked():
    """The prompt feeds the user's medications in as SAFETY FACTS and forbids naming
    them. Without drug-name detection the only enforcement was a verb-gated rule."""
    for text in DRUG_COMMENTS:
        cleaned, flags = apply_guardrails(text, {"metrics": {}})

        assert "medication" in flags, text
        assert cleaned == SAFE_FALLBACK


SUPPLEMENT_SUGGESTIONS_WITHOUT_A_VERB = [
    "Magnesium before bed would help you sleep.",
    "You might benefit from some vitamin D.",
    "I'd look into creatine.",
    "Electrolytes would make a difference on long rides.",
]


def test_supplement_suggestions_without_a_listed_verb_are_blocked():
    """The verb gate reintroduced the workaround the supplement rule exists to close."""
    for text in SUPPLEMENT_SUGGESTIONS_WITHOUT_A_VERB:
        cleaned, flags = apply_guardrails(text, {"metrics": {}})

        assert "medication" in flags, text
        assert cleaned == SAFE_FALLBACK


def test_ordinary_nutrition_and_training_talk_still_passes():
    """Over-blocking would gut the report; these must stay."""
    for text in (
        "Leafy greens are a good source of magnesium.",
        "Your heart rate settled faster than usual after this ride.",
        "A steadier pace would make the second half easier.",
        "Hydration before a long session helps most people.",
    ):
        cleaned, flags = apply_guardrails(text, {"metrics": {}})

        assert flags == [], text
        assert cleaned == text


# ── Profiles ─────────────────────────────────────────────────────────────────
#
# Everything above is the `autonomous` profile: text on its way to a user with
# no human in between, so a medication or supplement match replaces it. F5 adds
# a second audience. A draft on its way to a *clinician's* screen must not be
# censored, because in that profile today's guardrail blanks out exactly the
# content the clinician is there to judge — "magnesium before bed" becomes the
# safe fallback, and the queue fills with drafts that say nothing.
#
# The two halves lock together: `clinician_queue` labels instead of replacing,
# and 013_clinical_review.sql refuses to deliver a labelled draft without a
# signature. Neither is safe alone. The flag is what makes the gate bite.

from app.agent.guardrails import AUTONOMOUS, CLINICIAN_QUEUE, PROFILES


def test_autonomous_is_the_default_and_the_default_is_unchanged():
    """The whole suite above calls `apply_guardrails` with two arguments and must
    keep passing byte-identically. Naming the default explicitly has to be the
    same call as omitting it."""
    for text in (CLEAN, *DRUG_COMMENTS, *SUPPLEMENT_SUGGESTIONS_WITHOUT_A_VERB):
        assert apply_guardrails(text, analysis()) == apply_guardrails(
            text, analysis(), profile=AUTONOMOUS
        ), text


def test_a_supplement_recommendation_survives_for_a_clinician_to_read():
    text, flags = apply_guardrails(
        "Magnesium glycinate 200mg before bed would help your sleep.",
        analysis(),
        profile=CLINICIAN_QUEUE,
    )

    assert text == "Magnesium glycinate 200mg before bed would help your sleep."
    assert "medication" in flags


def test_a_medication_comment_survives_for_a_clinician_to_read():
    """A clinician is exactly the person qualified to judge "your beta-blocker
    explains this". The user is not, and the gate is what keeps them apart."""
    for original in DRUG_COMMENTS:
        text, flags = apply_guardrails(original, analysis(), profile=CLINICIAN_QUEUE)

        assert text == original, original
        assert "medication" in flags, original


def test_the_clinician_profile_flags_exactly_what_the_autonomous_one_blocks():
    """Same detection, different consequence. If the two profiles disagreed about
    what counts as medication content, a draft could reach a user unflagged
    carrying text the autonomous profile would have replaced."""
    for original in (*DRUG_COMMENTS, *SUPPLEMENT_SUGGESTIONS_WITHOUT_A_VERB, CLEAN):
        _, autonomous_flags = apply_guardrails(original, analysis())
        _, queue_flags = apply_guardrails(original, analysis(), profile=CLINICIAN_QUEUE)

        assert autonomous_flags == queue_flags, original


def test_clean_text_is_unflagged_in_both_profiles():
    """A draft with no flags is the one the SLA sweep may deliver unreviewed, so
    a false positive here does not merely annoy — it strands an observation in a
    queue forever."""
    text, flags = apply_guardrails(CLEAN, analysis(), profile=CLINICIAN_QUEUE)

    assert text == CLEAN
    assert flags == []


def test_escalation_is_appended_in_the_clinician_profile_too():
    """Safety is never gated on a human. A dangerous reading adds the escalation
    line whatever audience the text is for — the queue is for recommendations,
    never for emergencies."""
    text, flags = apply_guardrails(
        CLEAN, analysis(spo2=88.0), profile=CLINICIAN_QUEUE
    )

    assert text.startswith(CLEAN)
    assert "seek medical" in text.lower()
    assert "escalation" in flags


def test_escalation_survives_alongside_unreplaced_medication_text():
    """In the autonomous profile the text is replaced and the line is appended to
    the fallback. Here the original text is kept — and the line must still be
    there, rather than being lost with the replacement it used to follow."""
    text, flags = apply_guardrails(
        "Your beta-blocker is probably why your heart rate stayed low.",
        analysis(spo2=88.0),
        profile=CLINICIAN_QUEUE,
    )

    assert text.startswith("Your beta-blocker")
    assert "seek medical" in text.lower()
    assert set(flags) == {"medication", "escalation"}


def test_an_unknown_profile_falls_back_to_the_stricter_one():
    """A typo at a call site must not become a censorship bypass. Falling back to
    `autonomous` makes a mistake over-cautious; falling back the other way would
    put unreviewed medication advice on a user's screen."""
    text, flags = apply_guardrails(
        "Your statin may be a factor here.", analysis(), profile="clinician-queue"
    )

    assert text == SAFE_FALLBACK
    assert "medication" in flags


def test_the_profiles_are_enumerated_so_a_caller_cannot_invent_one():
    assert PROFILES == (AUTONOMOUS, CLINICIAN_QUEUE)
