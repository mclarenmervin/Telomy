"""Yesterday's air and sun, for the people who asked for it.

Runs once a night beside the score recompute, and takes the same shape: it
decides who is due and does one small thing per person, keeping no state
between ticks.

**Consent is checked here by calling `environment.location_for`**, which is
the one function in the system that decides whether a location may be used.
This sweep does not read the consent key itself and must not learn how — a
second place that knows the rule is a second place that can disagree with it.

**Yesterday, not today.** A day's air quality is only complete once the day
has ended, and the provider's hourly series for today is partly forecast.
Storing a forecast as an observation would have the number change under the
user for no reason they could see.

**One request per distinct cell, not per user.** Two people in the same city
round to the same coordinate, which is the point of rounding: the provider is
asked once and both rows are written from the one answer. It saves requests,
and it means the provider cannot count our users even approximately.
"""

from datetime import date, datetime, timedelta, timezone

from app.analytics.environment import (
    EnvironmentUnavailable,
    location_for,
    parse_open_meteo,
    request_for,
)
from app.common.logging_config import get_logger, log_context

logger = get_logger(__name__)

#: How many users one sweep will fetch for. A cap rather than a page: the
#: provider is a free public service and a nightly burst of thousands of
#: requests is how an integration gets blocked for everybody.
MAX_USERS_PER_SWEEP = 200


def _yesterday(now: datetime | None = None) -> date:
    return ((now or datetime.now(timezone.utc)) - timedelta(days=1)).date()


def due_locations(profiles, now: datetime | None = None) -> dict:
    """{(lat, lon): [user_id]} for everybody we may fetch for.

    Grouped by cell rather than listed by user, so the caller cannot
    accidentally make one request per person. A profile without consent or
    without a coordinate is simply absent.
    """
    cells: dict[tuple[float, float], list[str]] = {}
    for row in profiles:
        user_id = row.get("user_id")
        if not user_id:
            continue
        location = location_for(row.get("profile"))
        if location is None:
            continue
        cells.setdefault(location, []).append(user_id)
    return cells


def sweep_environment(supabase, fetch, now: datetime | None = None) -> dict:
    """Fetch yesterday for each distinct cell and store a row per user.

    `fetch(url, params) -> dict` is injected. Nothing in this module opens a
    socket, which is what lets the whole sweep be tested without one, and
    what makes the single outbound call in this product easy to find.

    Never raises. A provider outage is a night without snapshots, not a
    scheduler that stops running everything else.
    """
    observed_on = _yesterday(now)

    rows = (
        supabase.table("user_preferences")
        .select("user_id,profile")
        .limit(MAX_USERS_PER_SWEEP)
        .execute()
        .data
    )
    cells = due_locations(rows)

    stored, failed = 0, 0
    for (latitude, longitude), user_ids in cells.items():
        url, params = request_for(latitude, longitude, observed_on)
        try:
            payload = fetch(url, params)
            snapshot = parse_open_meteo(payload, observed_on, latitude, longitude)
        except EnvironmentUnavailable as error:
            logger.info(f"no environment for {latitude},{longitude}: {error}")
            failed += 1
            continue
        except Exception:
            logger.exception(f"fetching environment for {latitude},{longitude} failed")
            failed += 1
            continue

        for user_id in user_ids:
            try:
                supabase.table("environment_snapshots").upsert(
                    snapshot.as_row(user_id), on_conflict="user_id,observed_on"
                ).execute()
                stored += 1
            except Exception:
                logger.exception(
                    f"storing environment failed {log_context(user_id=user_id)}"
                )
                failed += 1

    logger.info(
        f"environment sweep day={observed_on} cells={len(cells)} "
        f"stored={stored} failed={failed}"
    )
    return {"day": observed_on.isoformat(), "cells": len(cells),
            "stored": stored, "failed": failed}
