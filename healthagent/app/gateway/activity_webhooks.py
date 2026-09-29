from fastapi import APIRouter, Depends, Header, HTTPException

from app.common.config import get_settings
from app.common.logging_config import get_logger, log_context
from app.common.queue import JobQueue
from app.gateway.queue_provider import get_activity_queue
from app.gateway.schemas import ActivityWebhookPayload
from app.gateway.security import verify_webhook_signature

router = APIRouter()
logger = get_logger(__name__)


@router.post("/webhooks/activity-sessions", status_code=202)
def handle_activity_webhook(
    payload: ActivityWebhookPayload,
    x_webhook_secret: str | None = Header(default=None),
    queue: JobQueue = Depends(get_activity_queue),
):
    settings = get_settings()
    # The secret is checked before any field of the payload is used.
    if not verify_webhook_signature(x_webhook_secret, settings.webhook_secret):
        logger.warning("rejected activity webhook: bad or missing secret")
        raise HTTPException(status_code=401, detail="invalid webhook secret")

    record = payload.record
    queue.enqueue(
        {
            "session_id": record.id,
            "user_id": record.user_id,
            "activity_type": record.activity_type,
        }
    )
    logger.info(
        "activity session enqueued "
        f"{log_context(user_id=record.user_id, session_id=record.id)}"
    )
    return {"queued": True}
