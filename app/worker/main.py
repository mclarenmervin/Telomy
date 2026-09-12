import redis
from typing import Any
from app.common.config import get_settings
from app.common.logging_config import configure_logging, get_logger
from app.common.queue import JobQueue
from app.common.supabase_client import get_supabase_client
from app.worker.handlers import process_event_job

logger = get_logger(__name__)


def process_one(queue: Any, supabase: Any, timeout: int = 5) -> bool:
    job = queue.dequeue(timeout=timeout)
    if job is None:
        return False
    process_event_job(job, supabase)
    return True


def run() -> None:
    configure_logging()
    settings = get_settings()
    redis_client = redis.Redis.from_url(settings.redis_url)
    queue = JobQueue(redis_client, settings.queue_name)
    supabase = get_supabase_client()
    logger.info("worker started")
    while True:
        process_one(queue, supabase)


if __name__ == "__main__":
    run()
