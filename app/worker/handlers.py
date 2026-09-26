from typing import Any

from app.common.logging_config import get_logger, log_context

logger = get_logger(__name__)


def process_event_job(job: dict, agent: Any) -> None:
    user_id = job.get("user_id")
    event_id = job.get("event_id")
    try:
        agent.invoke({"user_id": user_id, "event_id": event_id, "status": job.get("status")})
        logger.info(f"job processed {log_context(user_id=user_id, event_id=event_id)}")
    except Exception:
        logger.exception(f"job failed {log_context(user_id=user_id, event_id=event_id)}")
