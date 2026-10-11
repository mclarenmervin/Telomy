"""Writing a turn down.

One row per turn, holding what the person asked and what they actually read —
the text after the guardrails ran, never the raw model output. If a user ever
reports that the app told them something, the answer has to be a row and not a
reconstruction.
"""

from app.common.logging_config import get_logger, log_context

logger = get_logger(__name__)


def save_turn(supabase, user_id: str, turn) -> None:
    """Insert the turn. Failing to record it must not hide the answer.

    The person is holding a phone waiting for a reply, and the reply is already
    guarded and safe to show. Losing the audit row is bad and worth shouting
    about; swallowing the answer because of it would be worse, and would turn
    every transient database blip into an outage of the whole feature.
    """
    row = {
        "user_id": user_id,
        "asked": turn.asked,
        "answered": turn.answered,
        "route": turn.route,
        "guardrail_flags": turn.flags,
        "quoted_insight_ids": turn.quoted_insight_ids,
        "model": turn.model,
    }
    try:
        supabase.table("chat_turns").insert(row).execute()
    except Exception:
        logger.exception(f"could not record a chat turn {log_context(user_id=user_id)}")
