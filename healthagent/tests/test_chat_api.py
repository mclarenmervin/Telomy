"""The chat REST surface.

The same two properties the scores router is built around — the caller comes
from the verified token and never from the request, and the handler is thin —
plus one this endpoint introduces: it is the only place in the product where a
request can cost money, so a refusal has to be cheap and has to say which kind
it is.

There is deliberately no endpoint for reading the conversation back. The app
reads `chat_turns` through Supabase like it reads scores and lab uploads; its
RLS policy admits exactly the owner, and the agent stays invisible to the
frontend.
"""

from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.concierge.turn import (
    ANSWERED,
    EMERGENCY,
    RATE_LIMITED,
    TOO_LONG,
    Turn,
    TurnRefused,
)
from app.gateway.api.chat import router
from app.gateway.auth import current_user_id
from app.gateway.concierge_provider import get_concierge

ALICE = "00000000-0000-0000-0000-00000000000a"


class FakeConcierge:
    def __init__(self, turn=None, raises=None):
        self._turn = turn or Turn(
            asked="why is my readiness low?",
            answered="Your readiness was 68 on 10 October.",
            route=ANSWERED,
            flags=[],
            quoted_insight_ids=[],
            model="gpt-test",
        )
        self._raises = raises
        self.calls = []

    def answer(self, user_id, message, display_name=None):
        self.calls.append((user_id, message))
        if self._raises is not None:
            raise self._raises
        return self._turn


def client_for(concierge, user_id=ALICE):
    app = FastAPI()
    app.include_router(router)
    app.dependency_overrides[current_user_id] = lambda: user_id
    app.dependency_overrides[get_concierge] = lambda: concierge
    return TestClient(app)


def test_a_question_is_answered():
    concierge = FakeConcierge()

    response = client_for(concierge).post("/api/v1/chat", json={"message": "why is my readiness low?"})

    assert response.status_code == 200
    assert response.json()["answer"] == "Your readiness was 68 on 10 October."
    assert response.json()["route"] == ANSWERED


def test_the_caller_comes_from_the_token_and_not_the_body():
    """There is no user_id in the request to tamper with, and a body that
    carries one is ignored rather than honoured."""
    concierge = FakeConcierge()

    client_for(concierge).post(
        "/api/v1/chat",
        json={"message": "how am I doing?", "user_id": "00000000-0000-0000-0000-00000000000b"},
    )

    assert concierge.calls == [(ALICE, "how am I doing?")]


def test_a_quoted_finding_is_named_in_the_response():
    """So the app can link the sentence to the finding the clinician signed,
    rather than asking the user to take the product's word for it."""
    concierge = FakeConcierge(Turn(
        asked="what did the doctor say?",
        answered="The finding reads: ...",
        route=ANSWERED,
        quoted_insight_ids=["aaaaaaaa-0000-4000-8000-00000000000a"],
    ))

    body = client_for(concierge).post("/api/v1/chat", json={"message": "what did the doctor say?"}).json()

    assert body["quoted_insight_ids"] == ["aaaaaaaa-0000-4000-8000-00000000000a"]


def test_an_emergency_answer_says_so_in_the_route():
    """The app styles this differently and does not offer a follow-up chip
    under it. It is still a 200: the person got the right answer."""
    concierge = FakeConcierge(Turn(
        asked="I think I'm having a heart attack",
        answered="What you have described needs urgent medical attention...",
        route=EMERGENCY,
    ))

    response = client_for(concierge).post(
        "/api/v1/chat", json={"message": "I think I'm having a heart attack"}
    )

    assert response.status_code == 200
    assert response.json()["route"] == EMERGENCY


def test_the_daily_cap_answers_429():
    concierge = FakeConcierge(raises=TurnRefused(RATE_LIMITED, "you have reached today's limit"))

    response = client_for(concierge).post("/api/v1/chat", json={"message": "again?"})

    assert response.status_code == 429
    assert "limit" in response.json()["detail"]


def test_an_empty_message_is_refused_before_anything_runs():
    concierge = FakeConcierge()

    response = client_for(concierge).post("/api/v1/chat", json={"message": "   "})

    assert response.status_code == 422
    assert concierge.calls == []


def test_an_over_long_message_is_refused_before_anything_runs():
    """The expensive request to refuse cheaply. 2000 characters matches the
    check constraint on the column, so the two cannot disagree."""
    concierge = FakeConcierge()

    response = client_for(concierge).post("/api/v1/chat", json={"message": "a" * 2001})

    assert response.status_code == 422
    assert concierge.calls == []


def test_a_refusal_from_deeper_down_is_still_not_a_500():
    concierge = FakeConcierge(raises=TurnRefused(TOO_LONG, "too long"))

    response = client_for(concierge).post("/api/v1/chat", json={"message": "hello"})

    assert response.status_code == 422


def test_a_missing_message_is_a_422():
    assert client_for(FakeConcierge()).post("/api/v1/chat", json={}).status_code == 422


def test_the_response_does_not_leak_internal_flags():
    """`guardrail_flags` is an operator's signal, and on a screen it would
    invite the user to ask why their answer was replaced -- which is a
    conversation to have in the product's words, not in a debug field."""
    concierge = FakeConcierge(Turn(
        asked="should I take magnesium?",
        answered="I can describe how your readings changed...",
        route="guardrail_replaced",
        flags=["medication"],
    ))

    body = client_for(concierge).post("/api/v1/chat", json={"message": "should I take magnesium?"}).json()

    assert "medication" not in str(body)
    assert "flags" not in body
