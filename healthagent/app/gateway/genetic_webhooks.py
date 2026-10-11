"""A new genetics upload becomes an import job.

A copy of `lab_webhooks.py` in shape, for the same reasons: the secret is
verified before any field of the payload is read, two identifiers go on a
durable queue, and the gateway returns in milliseconds.

The file never comes near this endpoint. A 23andMe export is tens of megabytes
of text; the phone writes it to Storage directly and then inserts the row that
fires this webhook (P4). The job carries no path, because the worker re-reads
the authoritative row.
"""

from fastapi import APIRouter, Depends, Header, HTTPException

from app.common.config import get_settings
from app.common.logging_config import get_logger, log_context
from app.common.queue import JobQueue
from app.extraction_worker.genetics_handler import GENETICS_JOB_KIND
from app.gateway.queue_provider import get_genetics_queue
from app.gateway.schemas import GeneticUploadWebhookPayload
from app.gateway.security import verify_webhook_signature

router = APIRouter()
logger = get_logger(__name__)

#: Only a freshly uploaded row starts work.
IMPORTABLE_STATUS = "uploaded"


@router.post("/webhooks/genetic-uploads", status_code=202)
def handle_genetic_upload_webhook(
    payload: GeneticUploadWebhookPayload,
    x_webhook_secret: str | None = Header(default=None),
    queue: JobQueue = Depends(get_genetics_queue),
):
    settings = get_settings()
    # The secret is checked before any field of the payload is used.
    if not verify_webhook_signature(x_webhook_secret, settings.webhook_secret):
        logger.warning("rejected genetic upload webhook: bad or missing secret")
        raise HTTPException(status_code=401, detail="invalid webhook secret")

    record = payload.record
    context = log_context(user_id=record.user_id)

    # Supabase retries webhooks, and the worker UPDATEs this row when it
    # finishes. Both would otherwise re-import a file we have already read --
    # which is harmless for `genetic_variants`, whose unique constraint
    # absorbs it, and a waste of a download of somebody's genome.
    if payload.type != "INSERT" or record.status != IMPORTABLE_STATUS:
        logger.info(
            f"genetic upload webhook ignored: {payload.type} "
            f"status={record.status} upload={record.id} {context}"
        )
        return {"queued": False}

    queue.enqueue({
        "kind": GENETICS_JOB_KIND,
        "upload_id": record.id,
        "user_id": record.user_id,
    })
    logger.info(f"genetic upload enqueued upload={record.id} {context}")
    return {"queued": True}
