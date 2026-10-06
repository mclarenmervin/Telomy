from functools import lru_cache
import redis
from app.common.config import get_settings
from app.common.queue import JobQueue


@lru_cache
def get_job_queue() -> JobQueue:
    settings = get_settings()
    redis_client = redis.Redis.from_url(settings.redis_url)
    return JobQueue(redis_client, settings.queue_name)


@lru_cache
def get_activity_queue() -> JobQueue:
    settings = get_settings()
    redis_client = redis.Redis.from_url(settings.redis_url)
    return JobQueue(redis_client, settings.activity_queue_name)


@lru_cache
def get_lab_queue() -> JobQueue:
    settings = get_settings()
    redis_client = redis.Redis.from_url(settings.redis_url)
    return JobQueue(redis_client, settings.lab_queue_name)
