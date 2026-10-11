"""Which of this user's insights the concierge may repeat verbatim.

The guardrail's third profile takes a list of bodies and exempts them from the
language rules. This is the only thing that fills that list, so it is the whole
reach of the exemption and it is kept deliberately smaller than "everything the
user can see".
"""

from app.agent.guardrails import QUOTING_SIGNED, SAFE_FALLBACK, apply_guardrails
from app.concierge.grounding import quotable_bodies

SUPPLEMENT_BODY = (
    "Magnesium was 1.4 mg/dL on 3 October 2026, below the standard range of "
    "1.7-2.2 mg/dL. Magnesium supplementation is the usual response to a level "
    "below the reference range."
)


def signed(**overrides) -> dict:
    row = {
        "id": "11111111-1111-1111-1111-111111111111",
        "kind": "supplement",
        "title": "Magnesium below range",
        "body": SUPPLEMENT_BODY,
        "delivery_route": "clinician_signed",
        "reviewer_name": "Dr A. Rao",
        "reviewer_registration": "KMC/12345",
        "reviewed_at": "2026-10-05T09:00:00+00:00",
        "disputed_at": None,
        "dispute_reason": None,
    }
    row.update(overrides)
    return row


def test_a_clinician_signed_body_is_quotable():
    assert quotable_bodies([signed()]) == (SUPPLEMENT_BODY,)


def test_an_sla_released_body_is_not_quotable():
    """Nobody read it, so there is no signature for a quote to lean on.

    It costs nothing: a draft is only eligible for the SLA path if it carries
    no routing flags, and the flags come from the same detection the autonomous
    profile uses — so an `sla_expired` body passes the rules unaided and never
    needed an exemption. Putting it in the list would widen the exemption for
    no benefit at all.
    """
    body = "HbA1c has risen 11.1% across 3 results."
    row = signed(
        body=body,
        delivery_route="sla_expired",
        reviewer_name=None,
        reviewer_registration=None,
        reviewed_at=None,
    )

    assert quotable_bodies([row]) == ()
    # And the reason, asserted rather than claimed.
    assert apply_guardrails(body, {"metrics": {}}) == (body, [])


def test_an_unregistered_reviewer_is_not_a_signature():
    """The exemption's entire justification is that a named clinician with a
    registration number stands behind these exact words. A row that cannot
    name one does not get to lend its words to the model, whatever its
    delivery route says."""
    assert quotable_bodies([signed(reviewer_registration=None)]) == ()
    assert quotable_bodies([signed(reviewer_name=None)]) == ()


def test_a_disputed_insight_is_still_quotable():
    """The user disagreeing with a finding does not unsign it, and the
    alternative is worse: dropping it from the list turns the whole reply into
    SAFE_FALLBACK, so the concierge would answer "I can't discuss that" to
    someone asking about the finding they just disputed. The prompt handles the
    tone; the gate is not the place to argue."""
    row = signed(disputed_at="2026-10-06T10:00:00+00:00", dispute_reason="not mine")

    assert quotable_bodies([row]) == (SUPPLEMENT_BODY,)


def test_an_empty_body_never_enters_the_list():
    """`"".replace` is not a no-op in the other direction: an empty string in
    the list would have `_without_signed_quotes` insert a space between every
    character of the reply, which destroys every pattern in the rule set and
    exempts the entire text. The most dangerous possible entry, from the
    emptiest possible row."""
    assert quotable_bodies([signed(body="")]) == ()
    assert quotable_bodies([signed(body=None)]) == ()
    assert quotable_bodies([signed(body="   ")]) == ()


def test_the_list_is_empty_for_a_user_with_no_insights():
    assert quotable_bodies([]) == ()


def test_longest_first_so_a_shorter_body_cannot_shadow_a_longer_one():
    """Removal is sequential. If a short body is a substring of a long one and
    goes first, it is cut out of the middle of the long quote and the long
    quote no longer matches itself."""
    short = "Magnesium supplementation is the usual response."
    long = f"Magnesium was 1.4 mg/dL. {short} Also recorded: a diuretic."

    bodies = quotable_bodies([signed(body=short), signed(body=long)])

    assert bodies == (long, short)
    text = f"Your clinician signed this off: {long}"
    cleaned, flags = apply_guardrails(
        text, {"metrics": {}}, profile=QUOTING_SIGNED, signed_bodies=bodies
    )
    assert cleaned == text and flags == [], cleaned


# ── Which finding a reply repeated ───────────────────────────────────────────
#
# The other half of the exemption. If a user ever asks why the app said
# something about a supplement, the answer has to name the finding, and
# therefore the clinician whose registration number stands behind the words.

from app.concierge.grounding import quoted_insight_ids


def test_a_verbatim_quote_names_its_insight():
    reply = f'Your clinician signed this off: "{SUPPLEMENT_BODY}"'

    assert quoted_insight_ids(reply, [signed()]) == [
        "11111111-1111-1111-1111-111111111111"
    ]


def test_a_reply_that_quotes_nothing_names_nothing():
    assert quoted_insight_ids("Your readiness was 68 yesterday.", [signed()]) == []


def test_a_paraphrase_is_not_a_quote():
    """The same standard the gate uses. A paraphrase is the model's sentence,
    so it must not be recorded as a clinician's."""
    reply = "Your clinician said magnesium supplementation is usually the answer."

    assert quoted_insight_ids(reply, [signed()]) == []


def test_only_quotable_insights_can_be_cited():
    """An `sla_expired` body nobody signed must not be recorded as a quote of
    something a clinician said, even when the reply does repeat it."""
    row = signed(
        delivery_route="sla_expired", reviewer_name=None, reviewer_registration=None
    )

    assert quoted_insight_ids(f"The finding reads: {SUPPLEMENT_BODY}", [row]) == []


# ── Repeating what nobody reviewed ───────────────────────────────────────────
#
# Found by asking the real model, against live data, "what has a clinician
# signed off for me? Quote it exactly." It quoted the signed HbA1c finding and
# then quoted the *SLA-released* ferritin finding directly underneath, under
# one heading: "Dr Meera Raghavan signed these off:".
#
# Nothing refused it. There is no medication language in a sentence about
# ferritin falling 34%, the figures all came from the tool's own evidence, and
# the guardrail has no notion of who said what. The harm is not unreviewed
# advice — it is a signature attributed to text nobody read, which is the one
# distinction this entire product rests on.
#
# The rule is a bright line rather than a cleverer attribution check: repeating
# a finding word for word is a privilege that comes from a signature. An
# unreviewed finding can still be described, and its numbers are grounded by
# the tool's evidence like any others.

from app.concierge.grounding import repeated_unreviewed

FERRITIN_BODY = (
    "Ferritin has fallen 34.0% across 3 results, from 94 ng/mL on 12 February "
    "2026 to 62 ng/mL on 30 September 2026."
)


def unreviewed(**overrides) -> dict:
    return signed(
        id="22222222-2222-2222-2222-222222222222",
        body=FERRITIN_BODY,
        delivery_route="sla_expired",
        reviewer_name=None,
        reviewer_registration=None,
        reviewed_at=None,
        **overrides,
    )


def test_repeating_an_unreviewed_finding_is_caught():
    reply = f'Dr A. Rao signed these off:\n\n"{FERRITIN_BODY}"'

    assert repeated_unreviewed(reply, [unreviewed()]) == [
        "22222222-2222-2222-2222-222222222222"
    ]


def test_describing_an_unreviewed_finding_is_not_repeating_it():
    """The model keeps the ability to talk about it. Only the verbatim form is
    reserved, because the only reason to use somebody's exact words is to
    present them as authoritative — and for this one there is no authority."""
    reply = (
        "One finding about ferritin was released without a clinician reading "
        "it. It says your ferritin fell about 34% across three results."
    )

    assert repeated_unreviewed(reply, [unreviewed()]) == []


def test_a_signed_finding_is_not_an_unreviewed_one():
    reply = f'The finding reads: "{SUPPLEMENT_BODY}"'

    assert repeated_unreviewed(reply, [signed(), unreviewed()]) == []


def test_the_real_reply_that_found_this_is_caught():
    """Verbatim, from the live run. Both findings quoted under one attribution,
    only one of them signed."""
    reply = (
        "Dr Meera Raghavan signed these off:\n\n"
        f'"{SUPPLEMENT_BODY}"\n\n'
        f'"{FERRITIN_BODY}"'
    )

    assert repeated_unreviewed(reply, [signed(), unreviewed()]) == [
        "22222222-2222-2222-2222-222222222222"
    ]
