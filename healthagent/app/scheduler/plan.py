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


LAB_STALL_MINUTES = 30

# Reasons a swept upload failed, written to lab_uploads.error so the app can say
# something true rather than "something went wrong".
STALLED_REASON = (
    "We started reading this report but did not finish. Please try uploading it again."
)
NO_FILES_REASON = (
    "The upload did not complete, so there is no file to read. Please try again."
)


def stalled_upload_ids(uploads, now: datetime | None = None) -> list[str]:
    """Uploads left in `extracting` past the stall window.

    A worker killed mid-report leaves the row claimed forever: the status guard
    that stops a webhook retry re-extracting also stops anything ever picking it
    up again. Without this sweep the upload is invisibly stuck, and the user is
    looking at a spinner that will never resolve.
    """
    now = now or datetime.now(timezone.utc)
    cutoff = now - timedelta(minutes=LAB_STALL_MINUTES)
    stalled = []
    for upload in uploads:
        if upload.get("status") != "extracting":
            continue
        changed = _parsed(upload.get("updated_at") or upload.get("created_at"))
        if changed is not None and changed < cutoff:
            stalled.append(upload["id"])
    return stalled


def orphaned_upload_ids(uploads, file_owner_ids) -> list[str]:
    """Uploads with no file rows at all.

    The phone uploads to Storage and then inserts the row, so a crash between
    the two leaves a report with nothing to read. It must fail with a reason
    rather than sit at `uploaded` waiting for a webhook that already fired.
    """
    owners = set(file_owner_ids)
    return [
        upload["id"]
        for upload in uploads
        if upload.get("status") == "uploaded" and upload["id"] not in owners
    ]


def _parsed(value) -> datetime | None:
    if isinstance(value, datetime):
        return value if value.tzinfo else value.replace(tzinfo=timezone.utc)
    if not value:
        return None
    try:
        parsed = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError:
        return None
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)


def next_nightly_run(now: datetime | None = None) -> datetime:
    """The next nightly sweep. On the hour exactly means tomorrow, not now —
    otherwise the scheduler spins."""
    now = now or datetime.now(timezone.utc)
    today = now.replace(hour=NIGHTLY_HOUR_UTC, minute=0, second=0, microsecond=0)
    return today if now < today else today + timedelta(days=1)
