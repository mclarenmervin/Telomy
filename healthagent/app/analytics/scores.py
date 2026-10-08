"""Computing and storing a user's scores.

This module is the "one implementation, two callers" seam the architecture
depends on: the REST endpoint the app reads and the agent's tool both land
here, so a chart and a sentence can never disagree about the same number.

Everything is deterministic — no LLM is involved in producing a value, only in
describing one later (P2).
"""

from datetime import date, datetime, timedelta, timezone

import os

from app.analytics import catalog
from app.analytics import readiness as readiness_model
from app.analytics import readiness_v2
from app.analytics.biological_age import MODEL_VERSION as BIO_AGE_MODEL_VERSION
from app.analytics.biological_age import biological_age_for_display
from app.analytics.biomarker_selection import select_panel
from app.analytics.score_snapshot import build_snapshot
from app.analytics.sleep import Reading
from app.analytics.subject import Subject, resolve_sex, resolve_subject
from app.common.context_loader import ContextLoader
from app.common.logging_config import get_logger
from app.common.timeparse import parse_ts
from app.common.usertime import localise, resolve_timezone

logger = get_logger(__name__)

READINESS = "readiness"
BIOLOGICAL_AGE = "biological_age"

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
            # resolve_sex, not profile['sex']: the editor offers a `gender`
            # box too and this read saw None for everyone who used it.
            sex=resolve_sex(profile),
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


# ── Biological age ───────────────────────────────────────────────────────────
#
# The same seam as readiness, with one difference worth stating plainly: a
# readiness score is about a *day*, and a biological age is about a *blood
# draw*. So `as_of` here is an upper bound on which results may be considered,
# and the snapshot is dated to the panel the number actually came from. Dating
# it to the day the sweep ran would put a June panel on October's chart and
# write a fresh identical row every night.
#
# Computation is split in two on purpose. `biological_age_inputs` touches the
# database; `snapshot_from_inputs` is pure. That is what makes the plan's
# reproducibility requirement real -- a stored number recomputes from its own
# inputs without the rows it came from, so correcting a result tomorrow cannot
# retroactively change what an old snapshot claims.

# Two years of history, so the most recent complete panel is findable even for
# someone who uploads a report a year apart. Selection narrows from here.
BIO_AGE_LOOKBACK_DAYS = 730

# Nine markers across a few panels is a few dozen rows; the headroom is for a
# user who has uploaded years of reports in one sitting.
BIO_AGE_ROW_LIMIT = 500


def _results_up_to(rows, as_of: date) -> list[dict]:
    """Results collected on or before `as_of`.

    Asking what someone's biological age was in June must not reach for a panel
    drawn in September. The loader cannot express an upper bound, so this is the
    one place it is applied.
    """
    kept = []
    for row in rows or []:
        collected = parse_ts(row.get("collected_at"))
        if collected is not None and collected.date() <= as_of:
            kept.append(row)
    return kept


def biological_age_inputs(supabase, user_id: str, as_of: date) -> dict:
    """Everything the number depends on, and nothing else.

    Self-describing by design: the nine values with their units, collection
    dates and contexts, the resolved subject, and both version strings. A
    snapshot built from this is explicable without the database.

    Read through `ContextLoader`, which already filters to `confirmed` and
    `corrected` -- a value a machine read and nobody checked must not reach a
    score, or the confirmation step is decorative.
    """
    loader = ContextLoader(supabase)
    rows = loader.biomarker_results(
        user_id, days=BIO_AGE_LOOKBACK_DAYS, limit=BIO_AGE_ROW_LIMIT
    )["items"]
    panel = select_panel(_results_up_to(rows, as_of))

    profile = _profile(supabase, user_id)
    # The subject is resolved at the draw date, not today: a 2019 panel belongs
    # to the age its owner was in 2019.
    subject = resolve_subject(profile, as_of=panel.as_of or as_of)

    return {
        "as_of": (panel.as_of or as_of).isoformat(),
        "panel": panel.fingerprint(),
        "notes": dict(sorted(panel.notes.items())),
        "subject": {
            "age_years": subject.age_years,
            "sex": subject.sex,
            "refusals": list(subject.refusals),
        },
        "model_version": BIO_AGE_MODEL_VERSION,
        "ranges_version": catalog.catalog_version(),
        "timezone": str(resolve_timezone(profile)),
    }


def snapshot_from_inputs(
    user_id: str, inputs: dict, computed_at: datetime | None = None
) -> dict:
    """The snapshot an inputs dict produces. Pure -- no database, no clock.

    `computed_at` is passed rather than taken from the clock so that recomputing
    a snapshot from its own inputs is byte-identical rather than merely equal
    apart from a timestamp.
    """
    panel = inputs["panel"]
    canonical = {marker: value[0] for marker, value in panel["values"].items()}
    subject = Subject(
        age_years=inputs["subject"]["age_years"],
        sex=inputs["subject"]["sex"],
        refusals=tuple(inputs["subject"]["refusals"]),
    )

    result = biological_age_for_display(canonical, subject, inputs["notes"])

    return build_snapshot(
        result,
        user_id=user_id,
        kind=BIOLOGICAL_AGE,
        as_of=date.fromisoformat(inputs["as_of"]),
        timezone=inputs["timezone"],
        inputs=inputs,
        computed_at=computed_at,
        # Stamped because the catalog decides both halves of our guard: the
        # critical bounds that refuse an implausible value, and the optimal
        # midpoints each driver's contribution is measured against.
        ranges_version=inputs["ranges_version"],
    )


def compute_biological_age(supabase, user_id: str, as_of: date) -> dict:
    """Biological age for one user, from their most recent complete panel.

    One implementation, three callers: the REST endpoint the app recomputes
    with, the score worker a confirmation enqueues to, and the agent's tool.
    """
    return snapshot_from_inputs(
        user_id, biological_age_inputs(supabase, user_id, as_of)
    )
