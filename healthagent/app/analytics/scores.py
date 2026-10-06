"""Computing and storing a user's scores.

This module is the "one implementation, two callers" seam the architecture
depends on: the REST endpoint the app reads and the agent's tool both land
here, so a chart and a sentence can never disagree about the same number.

Everything is deterministic — no LLM is involved in producing a value, only in
describing one later (P2).
"""

from datetime import date, datetime, timedelta, timezone

import os

from app.analytics import readiness as readiness_model
from app.analytics import readiness_v2
from app.analytics.score_snapshot import build_snapshot
from app.analytics.sleep import Reading
from app.common.logging_config import get_logger
from app.common.timeparse import parse_ts
from app.common.usertime import localise, resolve_timezone

logger = get_logger(__name__)

READINESS = "readiness"

# Which readiness model runs. v1 is the faithful port of the phone's model and
# stays the default until the shadow period proves the two identical; only then
# is READINESS_MODEL set to v2, so a divergence has exactly one cause.
READINESS_MODEL_ENV = "READINESS_MODEL"
DEFAULT_READINESS_MODEL = "v1"

# Readiness compares against a 30-day baseline, plus the preceding night and the
# previous day's activity. Two extra days of slack keeps boundary readings in.
LOOKBACK_DAYS = 33


def _selected_readiness_model() -> str:
    """v1 or v2, with a loud fallback. A typo here would silently change every
    user's score, which is exactly the class of change that must not be quiet."""
    choice = (os.environ.get(READINESS_MODEL_ENV) or DEFAULT_READINESS_MODEL).strip().lower()
    if choice not in ("v1", "v2"):
        logger.error(
            f"{READINESS_MODEL_ENV}={choice!r} is not a known model; using "
            f"{DEFAULT_READINESS_MODEL}"
        )
        return DEFAULT_READINESS_MODEL
    return choice


def _age_from(profile: dict) -> float | None:
    """Years from a date of birth, or None. Tanaka needs an age; nothing else
    in the model does, so an absent one costs one driver rather than a score."""
    raw = (profile or {}).get("dob") or (profile or {}).get("dateOfBirth")
    if not raw:
        return None
    born = parse_ts(str(raw)[:10])
    if born is None:
        return None
    today = datetime.now(timezone.utc)
    return (today - born.replace(tzinfo=timezone.utc)).days / 365.25


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

    sleep_goal = float(profile.get("sleepGoal") or 8)
    activity_goal = float(profile.get("activityGoal") or 30)
    model = _selected_readiness_model()
    day = datetime.combine(as_of, datetime.min.time())

    if model == "v2":
        result = readiness_v2.calculate_v2(
            readings,
            day,
            age=_age_from(profile),
            sex=(profile.get("sex") or None),
            sleep_need=sleep_goal,
        )
    else:
        result = readiness_model.calculate(
            readings, day, sleep_goal=sleep_goal, activity_goal=activity_goal
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
