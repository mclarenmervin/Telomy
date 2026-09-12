from fastapi import APIRouter, Depends, Header, HTTPException
from app.common.config import get_settings
from app.common.logging_config import get_logger, log_context
from app.common.queue import JobQueue
from app.gateway.queue_provider import get_job_queue
from app.gateway.schemas import SupabaseWebhookPayload
from app.gateway.security import verify_webhook_signature

router = APIRouter()
logger = get_logger(__name__)


@router.post("/webhooks/events", status_code=202)
def handle_event_webhook(
    payload: SupabaseWebhookPayload,
    x_webhook_secret: str | None = Header(default=None),
    queue: JobQueue = Depends(get_job_queue),
):
    settings = get_settings()
    if not verify_webhook_signature(x_webhook_secret, settings.webhook_secret):
        logger.warning("rejected webhook: bad or missing secret")
        raise HTTPException(status_code=401, detail="invalid webhook secret")

    record = payload.record
    job = {
        "event_id": record.id,
        "user_id": record.user_id,
        "event_type": record.event_type,
        "status": record.status,
    }
    queue.enqueue(job)
    logger.info(f"event enqueued {log_context(user_id=record.user_id, event_id=record.id)}")
    return {"queued": True}
