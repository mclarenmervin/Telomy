"""A new lab upload becomes an extraction job.

Deliberately a copy of `activity_webhooks.py` in shape: the secret is verified
before any field of the payload is read, two identifiers go on a durable queue,
and the gateway returns in milliseconds.

The file itself never comes near this endpoint. The phone uploads to Storage
directly and then inserts the row that fires this webhook, because a 20MB
photographed panel passing through here would block a worker and couple ingest
to compute (P4). The job carries no path and no content either — the worker
re-reads the authoritative row, so a replayed webhook cannot pin extraction to a
stale location, and a forged payload has nothing useful to forge.
"""

from fastapi import APIRouter, Depends, Header, HTTPException

from app.common.config import get_settings
from app.common.logging_config import get_logger, log_context
from app.common.queue import JobQueue
from app.gateway.queue_provider import get_lab_queue
from app.gateway.schemas import LabUploadWebhookPayload
from app.gateway.security import verify_webhook_signature

router = APIRouter()
logger = get_logger(__name__)

# Only a freshly uploaded row starts work. Anything further along already has a
# worker on it, and `confirmed` is the user finishing — not a reason to read the
# report again.
EXTRACTABLE_STATUS = "uploaded"


@router.post("/webhooks/lab-uploads", status_code=202)
def handle_lab_upload_webhook(
    payload: LabUploadWebhookPayload,
    x_webhook_secret: str | None = Header(default=None),
    queue: JobQueue = Depends(get_lab_queue),
):
    settings = get_settings()
    # The secret is checked before any field of the payload is used.
    if not verify_webhook_signature(x_webhook_secret, settings.webhook_secret):
        logger.warning("rejected lab upload webhook: bad or missing secret")
        raise HTTPException(status_code=401, detail="invalid webhook secret")

    record = payload.record
    context = log_context(user_id=record.user_id)

    # Supabase retries webhooks, and confirming a panel UPDATEs this row. Both
    # would otherwise re-extract a report we have already read.
    if payload.type != "INSERT" or record.status != EXTRACTABLE_STATUS:
        logger.info(
            f"lab upload webhook ignored: {payload.type} status={record.status} "
            f"upload={record.id} {context}"
        )
        return {"queued": False}

    queue.enqueue({"upload_id": record.id, "user_id": record.user_id})
    logger.info(f"lab upload enqueued upload={record.id} {context}")
    return {"queued": True}
