from datetime import datetime, timezone
from typing import Any

from app.common.logging_config import get_logger, log_context
from app.worker.check_in_schedule import next_check_in_due, retry_check_in_due

logger = get_logger(__name__)


def _schedule(delayed: Any, job: dict, due_at: datetime, context: str, why: str) -> None:
    try:
        delayed.schedule(job, due_at)
        logger.info(f"check-in scheduled ({why}) {context} due_at={due_at.isoformat()}")
    except Exception:
        # A timer we failed to set is a missed check-in, not a failed job.
        logger.exception(f"scheduling the next check-in failed {context}")


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
    schedulable = delayed is not None and settings is not None
    now = now or datetime.now(timezone.utc)

    try:
        result = agent.invoke(
            {"user_id": user_id, "event_id": event_id, "status": job.get("status")}
        )
        logger.info(f"job processed {context}")
    except Exception:
        logger.exception(f"job failed {context}")
        # A promoted check-in has no webhook behind it — nothing else would
        # re-enter the chain — so the failure path reschedules, bounded by the
        # consecutive-failure cap and the event's duration cap. A `started` job
        # carries no started_at and is covered by the webhook's own retry.
        if schedulable:
            due_at = retry_check_in_due(job, now, settings)
            if due_at is not None:
                retry = {**job, "failures": int(job.get("failures") or 0) + 1}
                _schedule(delayed, retry, due_at, context, "retry")
        return

    if not schedulable:
        return
    event = (result or {}).get("event") or {}
    due_at = next_check_in_due(event, job.get("status") or "", now, settings)
    if due_at is None:
        return
    # started_at travels with the job so the retry path can honour the duration
    # cap without a database read; the failure count resets on every good run.
    _schedule(
        delayed,
        {
            "event_id": event_id,
            "user_id": user_id,
            "status": "in_progress",
            "started_at": event.get("started_at"),
        },
        due_at,
        context,
        "next",
    )
