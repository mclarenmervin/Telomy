"""Pure, reconciled Centre Owner dashboard calculations.

Calendar periods and "today" use the centre timezone. Activity uses a trailing
30 × 24-hour window. Booking value is an immutable indicative snapshot, never
payment revenue. Capacity is configured room availability, not staff or device
availability.
"""

from __future__ import annotations

import logging
from datetime import UTC, date, datetime, time, timedelta
from typing import Any
from zoneinfo import ZoneInfo

from app.analytics.marker_trends import find_trends
from app.analytics.severity import ATTENTION, URGENT, roll_up


logger = logging.getLogger(__name__)
FOLLOW_UP_ACTION = "Suggest a doctor consultation or retest."
NO_SHOW_GRACE = timedelta(minutes=15)


def _datetime(value: Any) -> datetime | None:
    if not value:
        return None
    try:
        parsed = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except (TypeError, ValueError):
        return None
    return parsed.replace(tzinfo=UTC) if parsed.tzinfo is None else parsed


def _date(value: Any) -> date | None:
    if not value:
        return None
    try:
        return date.fromisoformat(str(value)[:10])
    except (TypeError, ValueError):
        return None


def _time(value: Any) -> time | None:
    if not value:
        return None
    try:
        return time.fromisoformat(str(value))
    except (TypeError, ValueError):
        return None


def _month_shift(value: datetime, months: int) -> datetime:
    index = value.year * 12 + value.month - 1 + months
    return datetime(index // 12, index % 12 + 1, 1, tzinfo=value.tzinfo)


def _in_period(value: Any, start: datetime, end: datetime, zone: ZoneInfo) -> bool:
    parsed = _datetime(value)
    if parsed is None:
        return False
    local = parsed.astimezone(zone)
    return start <= local < end


def _completed_in(
    bookings: list[dict],
    start: datetime,
    end: datetime,
    zone: ZoneInfo,
) -> list[dict]:
    return [
        row
        for row in bookings
        if row.get("status") == "completed"
        and _in_period(row.get("completed_at"), start, end, zone)
    ]


def _postgres_weekday(value: date) -> int:
    return (value.weekday() + 1) % 7


def _link_includes_day(link: dict, day: date, zone: ZoneInfo) -> bool:
    linked = _datetime(link.get("linked_at"))
    unlinked = _datetime(link.get("unlinked_at"))
    linked_day = linked.astimezone(zone).date() if linked else None
    unlinked_day = unlinked.astimezone(zone).date() if unlinked else None
    return (linked_day is None or linked_day <= day) and (
        unlinked_day is None or day < unlinked_day
    )


def _capacity_minutes(
    service_id: str,
    room_hours: list[dict],
    room_services: list[dict],
    period_start: datetime,
    period_end: datetime,
    zone: ZoneInfo,
    active_room_ids: set[str],
) -> int:
    day = period_start.date()
    final_day = period_end.date()
    total = 0
    while day < final_day:
        room_ids = {
            link.get("room_id")
            for link in room_services
            if link.get("service_id") == service_id
            and str(link.get("room_id")) in active_room_ids
            and _link_includes_day(link, day, zone)
        }
        for hours in room_hours:
            valid_from = _date(hours.get("valid_from"))
            valid_until = _date(hours.get("valid_until"))
            opens = _time(hours.get("opens_at"))
            closes = _time(hours.get("closes_at"))
            if (
                hours.get("room_id") not in room_ids
                or hours.get("weekday") != _postgres_weekday(day)
                or (valid_from is not None and day < valid_from)
                or (valid_until is not None and day > valid_until)
                or opens is None
                or closes is None
            ):
                continue
            opened = datetime.combine(day, opens, tzinfo=zone)
            closed = datetime.combine(day, closes, tzinfo=zone)
            total += max(0, int((closed - opened).total_seconds() // 60))
        day += timedelta(days=1)
    return total


def _utilisation(
    services: list[dict],
    bookings: list[dict],
    room_hours: list[dict],
    room_services: list[dict],
    period_start: datetime,
    period_end: datetime,
    zone: ZoneInfo,
    rooms: list[dict],
) -> list[dict]:
    completed = _completed_in(bookings, period_start, period_end, zone)
    active_room_ids = {
        str(room["id"])
        for room in rooms
        if room.get("status", "active") == "active"
    }
    output = []
    for service in services:
        service_id = str(service["id"])
        capacity = _capacity_minutes(
            service_id,
            room_hours,
            room_services,
            period_start,
            period_end,
            zone,
            active_room_ids,
        )
        utilised = sum(
            int(row.get("duration_minutes_snapshot") or 0)
            for row in completed
            if str(row.get("service_id")) == service_id
        )
        over_capacity = capacity > 0 and utilised > capacity
        if over_capacity:
            logger.warning(
                "centre service utilisation exceeds configured capacity",
                extra={
                    "service_id": service_id,
                    "utilised_minutes": utilised,
                    "capacity_minutes": capacity,
                },
            )
        rate = None if capacity == 0 else min(utilised / capacity, 1.0)
        output.append({
            "service_id": service_id,
            "service_name": service.get("name") or "Service",
            "capacity_minutes": capacity,
            "utilised_minutes": utilised,
            "rate": rate,
            "inconsistent_over_capacity": over_capacity,
        })
    return output


def _safe_risk(member: dict, *, as_of: date) -> dict | None:
    severity_rows = member.get("severity_evidence") or []
    severity = roll_up(row.get("severity") for row in severity_rows)
    if severity in {URGENT, ATTENTION}:
        matching = [row for row in severity_rows if row.get("severity") == severity]
        evidence_date = max(
            (str(row.get("date")) for row in matching if row.get("date")),
            default=as_of.isoformat(),
        )
        evidence_class = "urgent_reading" if severity == URGENT else "attention_reading"
    else:
        trends = find_trends(member.get("biomarker_rows") or [], as_of=as_of)
        if trends:
            evidence_date = max(trend.as_of for trend in trends).isoformat()
            evidence_class = "marker_trend"
        elif member.get("risk_evidence"):
            evidence = member["risk_evidence"][0]
            evidence_date = str(evidence.get("date") or as_of.isoformat())
            evidence_class = str(evidence.get("evidence_class") or "clinical_follow_up")
        else:
            return None
    return {
        "id": member["id"],
        "display_name": member.get("display_name") or "Member",
        "follow_up_recommended": True,
        "evidence_class": evidence_class,
        "date": evidence_date,
        "action": FOLLOW_UP_ACTION,
    }


def calculate_centre_metrics(
    *,
    timezone_name: str,
    now: datetime,
    bookings: list[dict],
    services: list[dict],
    rooms: list[dict],
    room_hours: list[dict],
    room_services: list[dict],
    members: list[dict],
    currency_code: str = "INR",
) -> dict:
    """Calculate one deterministic dashboard projection from scoped rows."""
    zone = ZoneInfo(timezone_name)
    instant = now if now.tzinfo is not None else now.replace(tzinfo=UTC)
    local_now = instant.astimezone(zone)
    current_start = local_now.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
    next_start = _month_shift(current_start, 1)
    previous_start = _month_shift(current_start, -1)

    current_completed = _completed_in(bookings, current_start, next_start, zone)
    previous_completed = _completed_in(
        bookings, previous_start, current_start, zone
    )
    currency = currency_code.upper()
    current_value_rows = [
        row for row in current_completed
        if str(row.get("currency_code_snapshot") or "").upper() == currency
    ]
    previous_value_rows = [
        row for row in previous_completed
        if str(row.get("currency_code_snapshot") or "").upper() == currency
    ]
    excluded = len(current_completed) + len(previous_completed) - len(current_value_rows) - len(previous_value_rows)
    if excluded:
        logger.warning(
            "centre metrics excluded mixed-currency booking snapshots",
            extra={"currency_code": currency, "excluded_booking_count": excluded},
        )

    current_period_bookings = [
        row
        for row in bookings
        if _in_period(row.get("scheduled_start"), current_start, next_start, zone)
    ]
    eligible = [
        row
        for row in current_period_bookings
        if row.get("status") in {"completed", "no_show"}
        and (start := _datetime(row.get("scheduled_start"))) is not None
        and instant >= start + NO_SHOW_GRACE
    ]
    no_show_numerator = sum(row.get("status") == "no_show" for row in eligible)
    no_show_denominator = len(eligible)

    trailing_start = instant - timedelta(days=30)
    active_ids = []
    not_seen_ids = []
    for member in members:
        seen = any(
            booking.get("status") == "completed"
            and (completed := _datetime(booking.get("completed_at"))) is not None
            and trailing_start <= completed <= instant
            for booking in member.get("bookings") or []
        )
        (active_ids if seen else not_seen_ids).append(member["id"])

    today = local_now.date()
    today_bookings = [
        row
        for row in bookings
        if row.get("status") != "cancelled"
        and (start := _datetime(row.get("scheduled_start"))) is not None
        and start.astimezone(zone).date() == today
    ]
    today_bookings.sort(
        key=lambda row: (_datetime(row.get("scheduled_start")) or instant, row.get("id", ""))
    )
    risks = [risk for member in members if (risk := _safe_risk(member, as_of=today))]

    return {
        "periods": {
            "current_month": current_start.strftime("%Y-%m"),
            "previous_month": previous_start.strftime("%Y-%m"),
        },
        "indicative_booking_value": {
            "currency_code": currency,
            "current_month_minor": sum(
                int(row.get("indicative_price_minor_snapshot") or 0)
                for row in current_value_rows
            ),
            "previous_month_minor": sum(
                int(row.get("indicative_price_minor_snapshot") or 0)
                for row in previous_value_rows
            ),
        },
        "sessions": {
            "current_month": len(current_completed),
            "previous_month": len(previous_completed),
        },
        "members": {
            "total": len(members),
            "active_30_days": active_ids,
            "not_seen_30_days": not_seen_ids,
        },
        "today_bookings": today_bookings,
        "no_show": {
            "numerator": no_show_numerator,
            "denominator": no_show_denominator,
            "rate": (
                no_show_numerator / no_show_denominator
                if no_show_denominator
                else None
            ),
        },
        "utilisation": _utilisation(
            services,
            bookings,
            room_hours,
            room_services,
            current_start,
            next_start,
            zone,
            rooms,
        ),
        "members_at_risk": risks,
    }
