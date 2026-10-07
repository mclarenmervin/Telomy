"""Queue consumer for lab extraction. Same shape as the other workers."""

import redis

from app.common.config import get_settings
from app.common.llm import LABEL_MAPPING, get_model
from app.common.logging_config import configure_logging, get_logger
from app.common.queue import JobQueue
from app.common.supabase_client import get_supabase_client
from app.extraction.ocr import get_engine
from app.extraction_worker.handlers import process_lab_job

logger = get_logger(__name__)


def process_one(queue, supabase, engine=None, llm=None, timeout: int = 5) -> bool:
    try:
        job = queue.dequeue(timeout=timeout)
    except Exception:
        logger.exception("dequeue failed, will retry next tick")
        return False
    if job is None:
        return False
    process_lab_job(job, supabase, engine=engine, llm=llm)
    return True


def run() -> None:
    configure_logging()
    settings = get_settings()
    # socket_timeout must exceed BRPOP's blocking timeout, as in the other workers.
    redis_client = redis.Redis.from_url(settings.redis_url, socket_timeout=30)
    queue = JobQueue(redis_client, settings.lab_queue_name)
    supabase = get_supabase_client()
    # Resolved once: an unknown OCR_ENGINE should stop the worker at startup
    # rather than fail every photographed report with nothing saying why.
    engine = get_engine(settings.ocr_engine)
    # Only ever asked which marker a label names, never what a value is. None
    # when no key is configured, which leaves the catalog's alias table to do
    # the whole job -- it extracts a full panel on its own.
    llm = get_model(settings, LABEL_MAPPING)
    logger.info(
        f"extraction worker started lane={settings.lab_queue_name} "
        f"ocr={engine.name if engine else 'off'} "
        f"label_mapping_llm={'on' if llm else 'off (alias table only)'}"
    )
    while True:
        process_one(queue, supabase, engine=engine, llm=llm)


if __name__ == "__main__":
    run()
