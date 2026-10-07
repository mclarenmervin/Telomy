"""The scheduler: decides when work happens, never does the work.

One tick promotes anything already due onto the work queue, then — once a night
— enqueues a score recompute per active user. It computes nothing itself, holds
no state between ticks, and keeps every due time in Redis, so a crash loses
nothing and a restart resumes exactly where it left off (P3).

Deliberately not a cron: the delayed queue already exists and already handles
the concurrency, so a second replica cannot double-enqueue.
"""

import time
from datetime import datetime, timedelta, timezone
from typing import Any

import redis

from app.common.config import get_settings
from app.common.logging_config import configure_logging, get_logger
from app.common.queue import DelayedQueue, JobQueue
from app.common.supabase_client import get_supabase_client
from app.scheduler.lab_sweep import sweep_uploads
from app.scheduler.plan import (
    NIGHTLY_HOUR_UTC,
    active_user_ids,
    due_score_jobs,
    next_nightly_run,
)
from app.scheduler.storage_purge import purge_storage

logger = get_logger(__name__)

TICK_SECONDS = 60

# The sweep fires on the first tick inside this window, so a tick that lands a
# few seconds late still runs it.
SWEEP_WINDOW = timedelta(minutes=5)


# Stuck uploads are reconciled far more often than once a night: the stall
# window is half an hour, and someone watching a spinner should not wait until
# 03:00 UTC for it to resolve into an error they can act on.
LAB_SWEEP_EVERY_MINUTES = 10


def _inside_sweep_window(now: datetime) -> bool:
    start = now.replace(hour=NIGHTLY_HOUR_UTC, minute=0, second=0, microsecond=0)
    return start <= now < start + SWEEP_WINDOW


def _due_for_lab_sweep(now: datetime) -> bool:
    """Stateless, like everything else here: the clock decides, not a stored
    last-run. With a 60s tick this fires once per interval, and a missed tick
    costs one cycle of reconciliation rather than correctness."""
    return now.minute % LAB_SWEEP_EVERY_MINUTES == 0


def tick(supabase, delayed, work_queue, now: datetime | None = None) -> None:
    """One pass. Never raises: a scheduler that dies on a transient Redis error
    stops every scheduled thing in the product."""
    now = now or datetime.now(timezone.utc)
    try:
        if work_queue is not None:
            promoted = delayed.promote_due(work_queue, now)
            if promoted:
                logger.info(f"promoted {promoted} due job(s)")

        if _due_for_lab_sweep(now):
            sweep_uploads(supabase, now)
            # Same cadence: the queue is a partial-index lookup that returns
            # nothing almost always, and it makes "deleted" mean the bytes are
            # gone within minutes rather than by tomorrow morning.
            purge_storage(supabase, now)

        if not _inside_sweep_window(now):
            return

        users = active_user_ids(supabase, now=now)
        jobs = due_score_jobs(users, now=now)
        for job in jobs:
            # Due immediately; the delayed queue is the handoff, not a timer.
            delayed.schedule(job, now)
        logger.info(
            f"nightly sweep enqueued {len(jobs)} score recompute(s); "
            f"next run {next_nightly_run(now).isoformat()}"
        )
    except Exception:
        logger.exception("scheduler tick failed, will retry next tick")


def run() -> None:
    configure_logging()
    settings = get_settings()
    redis_client = redis.Redis.from_url(settings.redis_url, socket_timeout=30)
    delayed = DelayedQueue(redis_client, settings.score_delayed_queue_name)
    work_queue = JobQueue(redis_client, settings.score_queue_name)
    supabase = get_supabase_client()

    logger.info(
        f"scheduler started tick={TICK_SECONDS}s nightly_hour={NIGHTLY_HOUR_UTC}:00 UTC "
        f"lane={settings.score_queue_name}"
    )
    while True:
        tick(supabase, delayed, work_queue)
        time.sleep(TICK_SECONDS)


if __name__ == "__main__":
    run()
