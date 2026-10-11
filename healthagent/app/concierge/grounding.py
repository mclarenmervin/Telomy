"""What the concierge is allowed to repeat word for word.

`apply_guardrails(..., profile=QUOTING_SIGNED, signed_bodies=...)` exempts a
list of bodies from the language rules. This module is the only thing that
fills that list, so it is the entire reach of the exemption — and it is kept
smaller than "everything on the user's screen" on purpose.

Three things are excluded that a looser reading would have let in:

  * **`sla_expired` insights.** Nobody read them, so there is no signature for
    the quote to lean on. It costs nothing, because a draft only reaches that
    path if the guardrail gave it no routing flags — which is the same
    detection the autonomous profile runs — so such a body passes the rules
    unaided and never needed an exemption.
  * **rows that cannot name a registered reviewer.** The justification for the
    whole mechanism is that a named clinician stands behind these exact words.
    A row that cannot say who does not get to lend its words to the model.
  * **empty bodies.** `text.replace("", " ")` inserts a space between every
    character, which would dismantle every pattern in the rule set and exempt
    the entire reply. The emptiest row is the most dangerous entry.

Withdrawn insights never arrive here at all: `ContextLoader.clinical_insights`
filters them out, which means a clinician retracting a finding stops it being
quotable without this module knowing anything about it.
"""

#: The only delivery route a quote may lean on.
SIGNED = "clinician_signed"

#: The other one: delivered because the queue stalled, read by nobody.
UNREVIEWED = "sla_expired"


def _quotable(insights):
    """The insights a quote may lean on, as (id, body) pairs."""
    for insight in insights or []:
        if insight.get("delivery_route") != SIGNED:
            continue
        if not (insight.get("reviewer_name") and insight.get("reviewer_registration")):
            continue
        body = insight.get("body")
        if not body or not body.strip():
            continue
        yield insight.get("id"), body


def quoted_insight_ids(text: str, insights) -> list[str]:
    """Which of these insights the text repeats word for word.

    The provenance half of the exemption: the gate decides whether a quote may
    go out, and this records which clinician's words went out. Same standard as
    the gate -- a verbatim appearance, nothing normalised -- so a paraphrase is
    recorded as nobody's but the model's, which is exactly what it is.
    """
    return [
        insight_id
        for insight_id, body in _quotable(insights)
        if insight_id and body in (text or "")
    ]


def quotable_bodies(insights) -> tuple[str, ...]:
    """The bodies of this user's signed insights, longest first.

    Order is load-bearing rather than cosmetic. Removal is sequential, so if a
    short body is a substring of a longer one and goes first, it is cut out of
    the middle of the longer quote and that quote no longer matches itself —
    the longer, better-qualified finding would be the one that failed the gate.
    """
    bodies = [body for _, body in _quotable(insights)]
    return tuple(sorted(bodies, key=len, reverse=True))


def repeated_unreviewed(text: str, insights) -> list[str]:
    """Which unreviewed findings this text repeats word for word.

    Found by asking the real model, against live data, "what has a clinician
    signed off for me? Quote it exactly." It quoted the signed finding and then
    the SLA-released one directly underneath, both under one heading: "Dr Meera
    Raghavan signed these off."

    Nothing refused it, and nothing was going to. There is no medication
    language in a sentence about ferritin falling 34%, every figure came from
    the tool's own evidence, and the guardrail has no notion of who said what.
    The harm is not unreviewed advice reaching a user — it is a named
    clinician's signature attributed to words nobody read, which is the single
    distinction this product rests on.

    A bright line, rather than a cleverer check for whether an attribution sits
    near a quote: **repeating a finding word for word is a privilege that comes
    from a signature.** An unreviewed finding can still be described in the
    model's own words, and its numbers are grounded by the tool's evidence like
    any others -- what it cannot do is borrow the authority of somebody's exact
    phrasing when nobody stands behind it.
    """
    return [
        insight.get("id")
        for insight in insights or []
        if insight.get("delivery_route") == UNREVIEWED
        and insight.get("id")
        and (insight.get("body") or "").strip()
        and insight["body"] in (text or "")
    ]
