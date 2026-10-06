"""What the scheduler should enqueue, as pure functions.

The scheduler decides *when* work happens and never does the work. Keeping the
decisions here, free of Redis and Supabase, is what makes the cadence testable
without a clock — and keeps the service itself stateless, so a crash loses
nothing and a second replica cannot double-enqueue.
"""

from datetime import date, datetime, timedelta, timezone

SCORE_RECOMPUTE = "score_recompute"

# Early morning UTC: late enough that most users' previous day has ended
# wherever they are, early enough that a score is waiting when they wake.
NIGHTLY_HOUR_UTC = 3

# Scoring every account that ever existed is how a nightly sweep becomes the
# most expensive thing in the system.
ACTIVE_WINDOW_DAYS = 14


def active_user_ids(supabase, now: datetime | None = None) -> list[str]:
    """Users with a reading in the recent past, in first-seen order."""
    now = now or datetime.now(timezone.utc)
    since = (now - timedelta(days=ACTIVE_WINDOW_DAYS)).isoformat()
    rows = (
        supabase.table("health_measurements")
        .select("user_id")
        .gte("recorded_at", since)
        .execute()
        .data
    )
    seen: list[str] = []
    for row in rows:
        user_id = row.get("user_id")
        if user_id and user_id not in seen:
            seen.append(user_id)
    return seen


def due_score_jobs(user_ids, now: datetime | None = None) -> list[dict]:
    """One recompute per user for yesterday.

    Yesterday rather than today: a day is only complete once it has ended, and
    scoring a day still in progress produces a number that changes under the
    user for no reason they can see.
    """
    now = now or datetime.now(timezone.utc)
    as_of: date = (now - timedelta(days=1)).date()
    return [
        {"kind": SCORE_RECOMPUTE, "user_id": user_id, "as_of": as_of.isoformat()}
        for user_id in user_ids
    ]


def next_nightly_run(now: datetime | None = None) -> datetime:
    """The next nightly sweep. On the hour exactly means tomorrow, not now —
    otherwise the scheduler spins."""
    now = now or datetime.now(timezone.utc)
    today = now.replace(hour=NIGHTLY_HOUR_UTC, minute=0, second=0, microsecond=0)
    return today if now < today else today + timedelta(days=1)
