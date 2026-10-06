"""Computing and storing a user's scores.

This module is the "one implementation, two callers" seam the architecture
depends on: the REST endpoint the app reads and the agent's tool both land
here, so a chart and a sentence can never disagree about the same number.

Everything is deterministic — no LLM is involved in producing a value, only in
describing one later (P2).
"""

from datetime import date, datetime, timedelta, timezone

from app.analytics import readiness as readiness_model
from app.analytics.score_snapshot import build_snapshot
from app.analytics.sleep import Reading
from app.common.logging_config import get_logger
from app.common.timeparse import parse_ts
from app.common.usertime import localise, resolve_timezone

logger = get_logger(__name__)

READINESS = "readiness"

# Readiness compares against a 30-day baseline, plus the preceding night and the
# previous day's activity. Two extra days of slack keeps boundary readings in.
LOOKBACK_DAYS = 33


def _profile(supabase, user_id: str) -> dict:
    rows = (
        supabase.table("user_preferences")
        .select("profile")
        .eq("user_id", user_id)
        .execute()
        .data
    )
    return (rows[0].get("profile") if rows else None) or {}


def _readings(supabase, user_id: str, since: datetime, until: datetime) -> list[Reading]:
    rows = (
        supabase.table("health_measurements")
        .select("measurement_type,value,recorded_at,ended_at")
        .eq("user_id", user_id)
        .gte("recorded_at", since.isoformat())
        .lt("recorded_at", until.isoformat())
        .order("recorded_at")
        .execute()
        .data
    )
    readings = []
    for row in rows:
        recorded_at = parse_ts(row.get("recorded_at"))
        if recorded_at is None:
            continue
        readings.append(
            Reading(
                measurement_type=row.get("measurement_type") or "",
                value=float(row.get("value") or 0),
                recorded_at=recorded_at,
                ended_at=parse_ts(row.get("ended_at")),
            )
        )
    return readings


def compute_readiness(supabase, user_id: str, as_of: date) -> dict:
    """Readiness for one user on one of their local days.

    The day is theirs, not the server's: readings are moved onto their wall
    clock before the model sees them, so a user in Kolkata is scored on the day
    their phone would have scored.
    """
    profile = _profile(supabase, user_id)
    tz = resolve_timezone(profile)

    # Fetch in UTC with slack, then localise. Narrowing in UTC first keeps the
    # query on the existing (user_id, recorded_at) index.
    day_start_utc = datetime.combine(as_of, datetime.min.time(), tzinfo=timezone.utc)
    rows = _readings(
        supabase,
        user_id,
        day_start_utc - timedelta(days=LOOKBACK_DAYS),
        day_start_utc + timedelta(days=2),
    )
    readings = localise(rows, tz)

    result = readiness_model.calculate(
        readings,
        datetime.combine(as_of, datetime.min.time()),
        sleep_goal=float(profile.get("sleepGoal") or 8),
        activity_goal=float(profile.get("activityGoal") or 30),
    )

    return build_snapshot(
        result,
        user_id=user_id,
        kind=READINESS,
        as_of=as_of,
        timezone=str(tz),
        # The hash covers what actually went into the number, so recomputing it
        # from the same data gives the same fingerprint.
        inputs={
            "readings": len(readings),
            "sleep_goal": float(profile.get("sleepGoal") or 8),
            "activity_goal": float(profile.get("activityGoal") or 30),
            "timezone": str(tz),
            "model_version": result.model_version,
        },
    )


def persist_snapshot(supabase, snapshot: dict) -> None:
    """One row per user per score per day; recomputing replaces."""
    supabase.table("score_snapshots").upsert(
        snapshot, on_conflict="user_id,score_kind,as_of_date"
    ).execute()
    logger.info(
        f"score stored user_id={snapshot['user_id']} kind={snapshot['score_kind']} "
        f"as_of={snapshot['as_of_date']} quality={snapshot['data_quality']}"
    )
