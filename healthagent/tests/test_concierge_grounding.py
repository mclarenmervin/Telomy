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
