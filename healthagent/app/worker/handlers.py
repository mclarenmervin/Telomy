from datetime import datetime, timezone
from typing import Any

from app.common.logging_config import get_logger, log_context
from app.worker.check_in_schedule import next_check_in_due

logger = get_logger(__name__)


def process_event_job(
    job: dict,
    agent: Any,
    delayed: Any = None,
    settings: Any = None,
    now: datetime | None = None,
) -> None:
    user_id = job.get("user_id")
    event_id = job.get("event_id")
    context = log_context(user_id=user_id, event_id=event_id)
    try:
        result = agent.invoke(
            {"user_id": user_id, "event_id": event_id, "status": job.get("status")}
        )
        logger.info(f"job processed {context}")
    except Exception:
        # No follow-up is scheduled on failure: a webhook retry re-enters the
        # chain, and rescheduling off a failed run would compound the error.
        logger.exception(f"job failed {context}")
        return

    if delayed is None or settings is None:
        return
    try:
        now = now or datetime.now(timezone.utc)
        due_at = next_check_in_due(
            (result or {}).get("event"), job.get("status") or "", now, settings
        )
        if due_at is None:
            return
        delayed.schedule(
            {"event_id": event_id, "user_id": user_id, "status": "in_progress"}, due_at
        )
        logger.info(f"check-in scheduled {context} due_at={due_at.isoformat()}")
    except Exception:
        # A timer we failed to set is a missed check-in, not a failed job.
        logger.exception(f"scheduling the next check-in failed {context}")
