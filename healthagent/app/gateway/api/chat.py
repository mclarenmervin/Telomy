"""The concierge's one endpoint.

Thin, like the other routers: the caller comes from the verified token, the
turn is run by `app/concierge`, and the handler's only real work is turning a
refusal into the right status code.

**There is no endpoint for reading the conversation back.** The app reads
`chat_turns` through Supabase exactly as it reads scores and lab uploads, and
that table's RLS policy admits precisely its owner. A read endpoint would be a
second path to the same rows, enforced by our code remembering to filter
instead of by the database.

**And no streaming.** `turn.py` says why at length: the guardrails are the last
deterministic thing between a model and a user and they work on the finished
text. Nothing can un-say a token already on somebody's screen.
"""

from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field, field_validator

from app.common.logging_config import get_logger, log_context
from app.concierge.turn import RATE_LIMITED, TurnRefused
from app.gateway.auth import current_user_id
from app.gateway.concierge_provider import get_concierge
from app.concierge.turn import MAX_MESSAGE_CHARS

router = APIRouter(prefix="/api/v1/chat", tags=["chat"])
logger = get_logger(__name__)

# A refused turn maps to a status code here and nowhere else. 429 is the only
# one a well-behaved client can provoke; the rest mean it did not validate
# before asking.
_STATUS = {RATE_LIMITED: 429}
_DEFAULT_REFUSAL_STATUS = 422


class Question(BaseModel):
    """What the user typed, and nothing else.

    No `user_id`: it comes from the token, exactly as the agent's tools take it
    from state, so there is nothing in the request to tamper with. An extra
    field in the body is ignored rather than honoured.

    The length bound matches the check constraint on `chat_turns.asked`, so the
    gateway and the database cannot disagree about what is too long — and the
    expensive request is refused before a model is reached.
    """

    message: str = Field(min_length=1, max_length=MAX_MESSAGE_CHARS)

    @field_validator("message")
    @classmethod
    def _is_a_question(cls, value: str) -> str:
        """Whitespace passes `min_length` and is still not a question.

        Refused here rather than deeper down so that nothing is entered for it:
        no context read, no model, and no row. The turn refuses it too — this
        is the boundary doing its job, not the only check.
        """
        stripped = value.strip()
        if not stripped:
            raise ValueError("there is no question here")
        return stripped


class Answer(BaseModel):
    """What the user reads, and where it came from.

    `guardrail_flags` is deliberately absent. It is an operator's signal, and
    on a screen it would invite the user to ask why their answer was replaced —
    a conversation worth having in the product's own words rather than in a
    debug field.
    """

    answer: str
    #: answered | guardrail_replaced | emergency | unavailable. The app styles
    #: an emergency differently and does not offer a follow-up under it.
    route: str
    #: Signed findings this reply repeated word for word, so the app can link
    #: the sentence to the finding rather than asking the user to take the
    #: product's word for it.
    quoted_insight_ids: list[str] = []


@router.post("", response_model=Answer)
def ask(
    question: Question,
    user_id: Annotated[str, Depends(current_user_id)],
    concierge: Annotated[object, Depends(get_concierge)],
) -> Answer:
    try:
        turn = concierge.answer(user_id=user_id, message=question.message)
    except TurnRefused as refused:
        logger.info(f"chat refused {log_context(user_id=user_id)} reason={refused.reason}")
        raise HTTPException(
            status_code=_STATUS.get(refused.reason, _DEFAULT_REFUSAL_STATUS),
            detail=refused.message,
        ) from None
    return Answer(
        answer=turn.answered,
        route=turn.route,
        quoted_insight_ids=turn.quoted_insight_ids,
    )
