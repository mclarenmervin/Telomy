"""One turn of the concierge, end to end, with the model faked.

The model is faked because nothing interesting here is the model's decision.
Every property worth asserting is one of the deterministic steps around it:
what runs before it (the emergency screen, the budget), what is allowed to
reach it (this user's own data, read through the scoped loader), and what is
done to what it says (the figure check, the guardrails, the escalation line).
"""

from types import SimpleNamespace

import pytest

from app.agent.guardrails import (
    ESCALATION_LINE,
    MIXED_REVIEW_FALLBACK,
    SAFE_FALLBACK,
    UNKEEPABLE_PROMISE_FALLBACK,
)
from app.analytics.safety import EMERGENCY_RESPONSE
from app.common.context_loader import ContextLoader
from app.concierge.turn import (
    ANSWERED,
    EMERGENCY,
    GUARDRAIL_REPLACED,
    UNAVAILABLE,
    Concierge,
    TurnRefused,
)
from tests.fakes import FakeSupabase, make_settings

USER = "11111111-0000-4000-8000-000000000001"

SIGNED_BODY = (
    "Magnesium was 1.4 mg/dL on 3 October 2026, below the standard range of "
    "1.7-2.2 mg/dL. Magnesium supplementation is the usual response to a level "
    "below the reference range."
)


class FakeNarrator:
    """Stands in for the compiled agent. Records what it was asked, so a test
    can assert the model was never called at all."""

    def __init__(self, reply="Your readiness was 68 on 10 October.", tool_json=None, raises=None):
        self._reply = reply
        self._tool_json = tool_json
        self._raises = raises
        self.calls = []

    def invoke(self, payload, context=None):
        self.calls.append((payload, context))
        if self._raises is not None:
            raise self._raises
        messages = []
        if self._tool_json is not None:
            messages.append(SimpleNamespace(type="tool", content=self._tool_json))
        messages.append(SimpleNamespace(type="ai", content=self._reply))
        return {"messages": messages}


def insight_row(**overrides):
    row = {
        "id": "aaaaaaaa-0000-4000-8000-00000000000a",
        "user_id": USER,
        "kind": "supplement",
        "title": "Magnesium below range",
        "body": SIGNED_BODY,
        "evidence": [],
        "noticed_by": "agent",
        "reviewed_at": "2026-10-05T09:00:00+00:00",
        "reviewer_name": "Dr A. Rao",
        "reviewer_registration": "KMC/12345",
        "delivery_route": "clinician_signed",
        "delivered_at": "2026-10-05T09:00:05+00:00",
        "disputed_at": None,
        "dispute_reason": None,
        "dismissed_at": None,
        "withdrawn_at": None,
    }
    row.update(overrides)
    return row


def escalation_row(**overrides):
    row = {
        "id": "eeeeeeee-0000-4000-8000-00000000000e",
        "user_id": USER,
        "upload_id": "uuuuuuuu-0000-4000-8000-00000000000u",
        "biomarker_id": "potassium",
        "context": "standard",
        "value_canonical": 7.0,
        "operator": "=",
        "unit": "mmol/L",
        "severity": "critical",
        "message": "Potassium is critically high.",
        "acknowledged_at": None,
        "created_at": "2026-10-11T07:00:00+00:00",
    }
    row.update(overrides)
    return row


def build(tables=None, narrator=None, **setting_overrides):
    db = FakeSupabase(tables or {})
    settings = make_settings(**setting_overrides)
    concierge = Concierge(
        loader=ContextLoader(db),
        supabase=db,
        settings=settings,
        narrator=narrator if narrator is not None else FakeNarrator(),
    )
    return concierge, db


def saved(db):
    return db.tables.get("chat_turns", [])


# ── What runs before the model ───────────────────────────────────────────────

def test_an_emergency_is_answered_without_calling_the_model():
    """A model having a bad generation must never be the thing between someone
    in crisis and a phone number. The screen is deterministic, it runs first,
    and the turn ends there."""
    narrator = FakeNarrator()
    concierge, db = build(narrator=narrator)

    turn = concierge.answer(user_id=USER, message="I think I'm having a heart attack")

    assert turn.route == EMERGENCY
    assert turn.answered == EMERGENCY_RESPONSE["medical"]
    assert narrator.calls == []


def test_a_crisis_message_gets_the_psychological_response():
    concierge, _ = build()

    turn = concierge.answer(user_id=USER, message="I want to kill myself")

    assert turn.answered == EMERGENCY_RESPONSE["psychological"]
    assert turn.route == EMERGENCY


def test_an_emergency_turn_is_recorded():
    """So that "how often does this fire" is answerable, and so a reply nobody
    can reconstruct never leaves the system."""
    concierge, db = build()

    concierge.answer(user_id=USER, message="I can't breathe")

    assert saved(db)[0]["route"] == EMERGENCY
    assert "emergency" in saved(db)[0]["guardrail_flags"]


def test_the_daily_cap_refuses_before_spending_anything():
    """Agents loop, and a chat turn is the easiest place in this product to
    spend hundreds of dollars unnoticed."""
    history = [{
        "id": f"t{n}", "user_id": USER, "asked": "q", "answered": "a",
        "route": ANSWERED, "guardrail_flags": [], "quoted_insight_ids": [],
        "model": "m", "created_at": "2026-10-11T08:00:00+00:00",
    } for n in range(3)]
    narrator = FakeNarrator()
    concierge, db = build({"chat_turns": history}, narrator=narrator, max_chat_turns_per_day=3)

    with pytest.raises(TurnRefused):
        concierge.answer(user_id=USER, message="why is my readiness low?")

    assert narrator.calls == []
    # Nothing was spent and nothing was said, so there is no turn to record --
    # and a row for it would count towards the cap that produced it.
    assert len(saved(db)) == 3


def test_an_empty_message_is_refused():
    concierge, db = build()

    with pytest.raises(TurnRefused):
        concierge.answer(user_id=USER, message="   ")

    assert saved(db) == []


def test_an_over_long_message_is_refused_rather_than_truncated():
    """Truncating would answer a question the person did not ask."""
    concierge, _ = build()

    with pytest.raises(TurnRefused):
        concierge.answer(user_id=USER, message="a" * 2001)


# ── What the model is given ──────────────────────────────────────────────────

def test_the_previous_turns_are_given_to_the_model_oldest_first():
    """A conversation that cannot remember the last exchange is not a
    conversation. History comes from the database rather than the client, so
    the user cannot forge what the product said earlier."""
    narrator = FakeNarrator()
    concierge, _ = build({"chat_turns": [
        {"id": "t1", "user_id": USER, "asked": "first?", "answered": "first answer.",
         "route": ANSWERED, "guardrail_flags": [], "quoted_insight_ids": [],
         "model": "m", "created_at": "2026-10-11T08:00:00+00:00"},
        {"id": "t2", "user_id": USER, "asked": "second?", "answered": "second answer.",
         "route": ANSWERED, "guardrail_flags": [], "quoted_insight_ids": [],
         "model": "m", "created_at": "2026-10-11T08:05:00+00:00"},
    ]}, narrator=narrator)

    concierge.answer(user_id=USER, message="third?")

    sent = [m["content"] for m in narrator.calls[0][0]["messages"]]
    assert sent == ["first?", "first answer.", "second?", "second answer.", "third?"]


def test_the_context_carries_the_user_and_the_model_cannot_name_another():
    narrator = FakeNarrator()
    concierge, _ = build(narrator=narrator)

    concierge.answer(user_id=USER, message="how am I doing?")

    assert narrator.calls[0][1].user_id == USER


# ── What is done to what the model says ──────────────────────────────────────

def test_a_grounded_reply_goes_out_unchanged():
    narrator = FakeNarrator(
        reply="Your readiness was 68 on 10 October.",
        tool_json='{"status": "ok", "items": [{"value": 68}]}',
    )
    concierge, db = build(narrator=narrator)

    turn = concierge.answer(user_id=USER, message="what is my readiness?")

    assert turn.route == ANSWERED
    assert turn.answered == "Your readiness was 68 on 10 October."
    assert turn.flags == []
    assert saved(db)[0]["answered"] == turn.answered


def test_an_invented_measurement_is_not_shown_to_the_user():
    """The worst thing this feature can do. No tool returned 1.9 mg/dL, so the
    sentence is the model's invention about somebody's blood."""
    narrator = FakeNarrator(reply="Your magnesium is 1.9 mg/dL, which is fine.")
    concierge, _ = build(narrator=narrator)

    turn = concierge.answer(user_id=USER, message="what is my magnesium?")

    assert turn.answered == SAFE_FALLBACK
    assert "unsupported_measurement" in turn.flags


def test_an_ungrounded_figure_with_no_unit_is_flagged_but_not_refused():
    """Not every unsupported number is an invented measurement. A bare one is
    worth counting and not worth replacing a whole reply over — a check that
    fires on every honest sentence is a check somebody switches off."""
    narrator = FakeNarrator(reply="Your score came out at 91 overall.")
    concierge, _ = build(narrator=narrator)

    turn = concierge.answer(user_id=USER, message="how did I score?")

    assert turn.answered == "Your score came out at 91 overall."
    assert "unverified_number" in turn.flags
    assert turn.route == ANSWERED


def test_a_date_is_not_flagged_at_all():
    """Found on live data: naming a date, or the clinician who signed a
    finding, was enough to flag an honest answer. A conversation about lab
    history cannot avoid either."""
    narrator = FakeNarrator(
        reply="Your last panel was taken on 2026-10-10, signed by Dr A. Rao, KMC/12345."
    )
    concierge, _ = build(narrator=narrator)

    turn = concierge.answer(user_id=USER, message="when was my last panel?")

    assert turn.flags == []
    assert turn.route == ANSWERED


def test_the_models_own_supplement_advice_is_replaced():
    narrator = FakeNarrator(reply="I'd take 400 mg of magnesium before bed.")
    concierge, db = build(narrator=narrator)

    turn = concierge.answer(user_id=USER, message="should I take magnesium?")

    assert turn.answered == SAFE_FALLBACK
    assert turn.route == GUARDRAIL_REPLACED
    assert "medication" in turn.flags


def test_a_signed_finding_may_be_quoted_back():
    """What F6 made impossible and F7 exists to fix. The user is looking at
    these exact words on the Labs screen."""
    narrator = FakeNarrator(
        reply=f'Your clinician signed this off: "{SIGNED_BODY}"',
        tool_json='{"status": "ok", "items": []}',
    )
    concierge, _ = build({"insights": [insight_row()]}, narrator=narrator)

    turn = concierge.answer(user_id=USER, message="what did the doctor say?")

    assert SIGNED_BODY in turn.answered
    assert turn.route == ANSWERED
    assert turn.flags == []


def test_a_quote_records_which_finding_it_came_from():
    """Provenance. If the user ever asks why the app said something about a
    supplement, this names the finding and therefore the clinician."""
    narrator = FakeNarrator(reply=f'The finding reads: "{SIGNED_BODY}"')
    concierge, db = build({"insights": [insight_row()]}, narrator=narrator)

    turn = concierge.answer(user_id=USER, message="what did the doctor say?")

    assert turn.quoted_insight_ids == ["aaaaaaaa-0000-4000-8000-00000000000a"]
    assert saved(db)[0]["quoted_insight_ids"] == turn.quoted_insight_ids


def test_a_quoted_body_does_not_trip_the_figure_check():
    """The signed sentence is full of numbers that no tool returned as values —
    they are inside a string. Judging the quote as the model's own arithmetic
    would make every signed finding unquotable, which is the bug this phase
    opened with."""
    narrator = FakeNarrator(reply=f'The finding reads: "{SIGNED_BODY}"')
    concierge, _ = build({"insights": [insight_row()]}, narrator=narrator)

    turn = concierge.answer(user_id=USER, message="what did the doctor say?")

    assert turn.flags == []
    assert turn.answered.endswith('"')


def test_another_users_signed_finding_is_not_quotable():
    """The exemption is scoped by the loader, which filters on user_id. A
    sentence somebody else's clinician signed is, for this user, just the model
    claiming a clinician said something."""
    narrator = FakeNarrator(reply=f'Your clinician signed this off: "{SIGNED_BODY}"')
    concierge, _ = build(
        {"insights": [insight_row(user_id="99999999-0000-4000-8000-000000000099")]},
        narrator=narrator,
    )

    turn = concierge.answer(user_id=USER, message="what did the doctor say?")

    assert turn.answered == SAFE_FALLBACK


def test_promising_that_a_clinician_will_look_at_something_is_refused():
    """There is no clinician console yet, so every flagged draft eventually
    strands. A reply that cheerfully promises a review is the product lying,
    and it is the kind of lie a user acts on by waiting."""
    narrator = FakeNarrator(
        reply="I've flagged this and a clinician will review it and get back to you."
    )
    concierge, _ = build(narrator=narrator)

    turn = concierge.answer(user_id=USER, message="can a doctor check this?")

    assert turn.answered == UNKEEPABLE_PROMISE_FALLBACK
    assert "unkeepable_promise" in turn.flags
    assert turn.route == GUARDRAIL_REPLACED


def test_saying_a_clinician_already_signed_something_is_not_a_promise():
    """The past tense is the whole product. Only the future tense is the lie."""
    narrator = FakeNarrator(reply="A clinician reviewed and signed that finding on 5 October.")
    concierge, _ = build(narrator=narrator)

    turn = concierge.answer(user_id=USER, message="did a doctor check this?")

    assert turn.route == ANSWERED
    assert "unkeepable_promise" not in turn.flags


# ── The escalation line is never gated on anything ───────────────────────────

def test_an_open_critical_value_is_appended_to_the_reply():
    narrator = FakeNarrator(reply="Nothing much has changed this week.")
    concierge, _ = build({"lab_escalations": [escalation_row()]}, narrator=narrator)

    turn = concierge.answer(user_id=USER, message="how am I doing?")

    assert turn.answered.endswith(ESCALATION_LINE)
    assert "escalation" in turn.flags


def test_the_escalation_survives_a_guardrail_replacement():
    """A dangerous reading is an emergency whatever else the reply was doing,
    exactly as it is in the activity report and in the lab path."""
    narrator = FakeNarrator(reply="I'd take 400 mg of magnesium before bed.")
    concierge, _ = build({"lab_escalations": [escalation_row()]}, narrator=narrator)

    turn = concierge.answer(user_id=USER, message="should I take magnesium?")

    assert turn.answered.startswith(SAFE_FALLBACK)
    assert turn.answered.endswith(ESCALATION_LINE)


def test_chat_never_acknowledges_an_escalation():
    """Chat must not be the thing that marks an emergency as handled. The
    person acknowledging it on the Labs screen is what does that."""
    rows = [escalation_row()]
    narrator = FakeNarrator(reply="Nothing much has changed this week.")
    concierge, db = build({"lab_escalations": rows}, narrator=narrator)

    concierge.answer(user_id=USER, message="how am I doing?")

    assert db.tables["lab_escalations"][0]["acknowledged_at"] is None


# ── When there is no model ───────────────────────────────────────────────────

def test_without_a_model_the_turn_says_so_rather_than_guessing():
    concierge, db = build(narrator=False)

    turn = concierge.answer(user_id=USER, message="how am I doing?")

    assert turn.route == UNAVAILABLE
    assert turn.answered
    assert saved(db)[0]["route"] == UNAVAILABLE


def test_a_failed_model_call_does_not_look_like_an_answer():
    narrator = FakeNarrator(raises=RuntimeError("provider exploded"))
    concierge, _ = build(narrator=narrator)

    turn = concierge.answer(user_id=USER, message="how am I doing?")

    assert turn.route == UNAVAILABLE


def test_an_empty_model_reply_is_not_an_answer():
    narrator = FakeNarrator(reply="   ")
    concierge, _ = build(narrator=narrator)

    turn = concierge.answer(user_id=USER, message="how am I doing?")

    assert turn.route == UNAVAILABLE


def test_the_turn_records_which_model_answered():
    concierge, db = build(llm_model="gpt-test-1")

    concierge.answer(user_id=USER, message="how am I doing?")

    assert saved(db)[0]["model"] == "gpt-test-1"


# ── Repeating what nobody reviewed ───────────────────────────────────────────
#
# The defect the device run found, and the one the whole product rests on: a
# named clinician's signature attributed to words nobody read. See
# `grounding.repeated_unreviewed` for the reply that found it.

FERRITIN_BODY = (
    "Ferritin has fallen 34.0% across 3 results, from 94 ng/mL on 12 February "
    "2026 to 62 ng/mL on 30 September 2026."
)


def unreviewed_row(**overrides):
    return insight_row(
        id="22222222-2222-2222-2222-222222222222",
        kind="lab_finding",
        body=FERRITIN_BODY,
        delivery_route="sla_expired",
        reviewer_name=None,
        reviewer_registration=None,
        reviewed_at=None,
        **overrides,
    )


def test_quoting_an_unreviewed_finding_under_a_signature_is_refused():
    """The live reply, which nothing else in the system would have caught:
    no medication language, and every figure grounded by the tool's own
    evidence."""
    narrator = FakeNarrator(
        reply=f'Dr A. Rao signed these off:\n\n"{SIGNED_BODY}"\n\n"{FERRITIN_BODY}"',
        # The ferritin figures as the tool returned them, in `evidence`. Live,
        # this is what made the reply pass the figure check -- the numbers were
        # all real. Nothing else in the system would have stopped it.
        tool_json='{"status": "ok", "items": [{"evidence": ['
        '{"value_canonical": 94}, {"value_canonical": 62}, {"value_canonical": 34.0}]}]}',
    )
    concierge, _ = build(
        {"insights": [insight_row(), unreviewed_row()]}, narrator=narrator
    )

    turn = concierge.answer(user_id=USER, message="what has a clinician signed off?")

    assert turn.answered == MIXED_REVIEW_FALLBACK
    assert "repeated_unreviewed" in turn.flags
    assert turn.route == GUARDRAIL_REPLACED


def test_a_refused_reply_claims_no_quotes():
    """The trail must not record a clinician's words as having gone out in a
    reply the user never saw."""
    narrator = FakeNarrator(
        reply=f'"{SIGNED_BODY}"\n\n"{FERRITIN_BODY}"',
        tool_json='{"status": "ok", "items": [{"evidence": ['
        '{"value_canonical": 94}, {"value_canonical": 62}, {"value_canonical": 34.0}]}]}',
    )
    concierge, db = build(
        {"insights": [insight_row(), unreviewed_row()]}, narrator=narrator
    )

    turn = concierge.answer(user_id=USER, message="what has a clinician signed off?")

    assert turn.quoted_insight_ids == []
    assert saved(db)[0]["quoted_insight_ids"] == []


def test_describing_an_unreviewed_finding_still_works():
    """The capability is not withdrawn, only the verbatim form. Everything the
    model says here is its own, and the numbers come from the tool."""
    narrator = FakeNarrator(
        reply=(
            "One finding about ferritin was released without a clinician "
            "reading it, so nobody has checked it."
        ),
        tool_json='{"status": "ok", "items": []}',
    )
    concierge, _ = build({"insights": [unreviewed_row()]}, narrator=narrator)

    turn = concierge.answer(user_id=USER, message="what about ferritin?")

    assert turn.route == ANSWERED
    assert turn.flags == []
