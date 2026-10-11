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

#: The only delivery route a quote may lean on. `sla_expired` is the other one.
SIGNED = "clinician_signed"


def quotable_bodies(insights) -> tuple[str, ...]:
    """The bodies of this user's signed insights, longest first.

    Order is load-bearing rather than cosmetic. Removal is sequential, so if a
    short body is a substring of a longer one and goes first, it is cut out of
    the middle of the longer quote and that quote no longer matches itself —
    the longer, better-qualified finding would be the one that failed the gate.
    """
    bodies = []
    for insight in insights or []:
        if insight.get("delivery_route") != SIGNED:
            continue
        if not (insight.get("reviewer_name") and insight.get("reviewer_registration")):
            continue
        body = insight.get("body")
        if not body or not body.strip():
            continue
        bodies.append(body)
    return tuple(sorted(bodies, key=len, reverse=True))
