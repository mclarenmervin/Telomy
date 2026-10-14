from datetime import UTC, datetime, timedelta

from app.analytics.centre_metrics import calculate_centre_metrics


NOW = datetime(2026, 3, 1, 0, 0, tzinfo=UTC)


def booking(
    booking_id,
    *,
    patient="patient-active",
    service="service-a",
    status="booked",
    start="2026-03-01T04:30:00+00:00",
    completed_at=None,
    price=0,
    minutes=30,
):
    start_at = datetime.fromisoformat(start)
    return {
        "id": booking_id,
        "patient_id": patient,
        "service_id": service,
        "room_id": "room-a",
        "status": status,
        "scheduled_start": start,
        "scheduled_end": (start_at + timedelta(minutes=minutes)).isoformat(),
        "completed_at": completed_at,
        "duration_minutes_snapshot": minutes,
        "indicative_price_minor_snapshot": price,
        "currency_code_snapshot": "INR",
    }


def trend_rows():
    def row(value, days_ago):
        return {
            "biomarker_id": "hba1c",
            "context": "standard",
            "result_type": "quantitative",
            "operator": "=",
            "value_canonical": value,
            "unit_canonical": "%",
            "collected_at": (NOW.date() - timedelta(days=days_ago)).isoformat(),
        }

    return [row(5.0, 200), row(5.4, 100), row(5.8, 10)]


def fixture():
    at_boundary = (NOW - timedelta(minutes=15)).isoformat()
    before_boundary = (NOW - timedelta(minutes=14, seconds=59)).isoformat()
    bookings = [
        booking(
            "completed-current",
            status="completed",
            start="2026-02-28T19:30:00+00:00",
            completed_at="2026-02-28T20:00:00+00:00",
            price=10000,
        ),
        booking(
            "completed-previous",
            status="completed",
            start="2026-02-28T09:30:00+00:00",
            completed_at="2026-02-28T10:00:00+00:00",
            price=7000,
        ),
        booking("cancelled", status="cancelled", price=99999),
        booking("future", start="2026-03-01T04:30:00+00:00"),
        booking("inside-grace", start=before_boundary),
        booking("no-show-before", status="no_show", start=before_boundary),
        booking("no-show-boundary", status="no_show", start=at_boundary),
    ]
    members = [
        {
            "id": "patient-active",
            "display_name": "Active Member",
            "bookings": bookings,
            "severity_evidence": [{
                "severity": "urgent",
                "date": "2026-02-28",
                "value": 999,
                "diagnosis": "must not leak",
                "treatment": "must not leak",
            }],
        },
        {
            "id": "patient-never",
            "display_name": "Never Seen",
            "bookings": [],
            "biomarker_rows": trend_rows(),
        },
    ]
    return {
        "bookings": bookings,
        "services": [
            {"id": "service-a", "name": "Session A"},
            {"id": "service-b", "name": "Session B"},
        ],
        "rooms": [
            {"id": "room-a", "name": "Room A", "status": "active"},
            {"id": "room-b", "name": "Room B", "status": "active"},
        ],
        "room_hours": [{
            "room_id": "room-a",
            "weekday": 0,
            "opens_at": "09:00:00",
            "closes_at": "10:00:00",
            "valid_from": "2026-01-01",
            "valid_until": None,
        }],
        "room_services": [
            {"room_id": "room-a", "service_id": "service-a", "linked_at": "2026-01-01T00:00:00+00:00", "unlinked_at": None},
            {"room_id": "room-b", "service_id": "service-b", "linked_at": "2026-01-01T00:00:00+00:00", "unlinked_at": None},
        ],
        "members": members,
    }


def metrics():
    return calculate_centre_metrics(
        **fixture(),
        timezone_name="Asia/Kolkata",
        now=NOW,
    )


def test_calendar_month_value_and_sessions_use_centre_timezone():
    result = metrics()

    assert result["indicative_booking_value"] == {
        "currency_code": "INR",
        "current_month_minor": 10000,
        "previous_month_minor": 7000,
    }
    assert result["sessions"] == {"current_month": 1, "previous_month": 1}
    assert result["periods"] == {
        "current_month": "2026-03",
        "previous_month": "2026-02",
    }


def test_member_activity_not_seen_and_today_are_exact():
    result = metrics()

    assert result["members"]["total"] == 2
    assert result["members"]["active_30_days"] == ["patient-active"]
    assert result["members"]["not_seen_30_days"] == ["patient-never"]
    assert [row["id"] for row in result["today_bookings"]] == [
        "completed-current",
        "no-show-boundary",
        "inside-grace",
        "no-show-before",
        "future",
    ]


def test_no_show_rate_uses_the_exact_fifteen_minute_boundary():
    result = metrics()["no_show"]

    assert result == {"numerator": 1, "denominator": 2, "rate": 0.5}


def test_no_show_zero_denominator_is_none_not_a_fabricated_zero():
    inputs = fixture()
    inputs["bookings"] = [
        booking("future-only", start="2026-03-01T04:30:00+00:00"),
        booking("cancelled-only", status="cancelled"),
    ]

    result = calculate_centre_metrics(
        **inputs,
        timezone_name="Asia/Kolkata",
        now=NOW,
    )["no_show"]

    assert result == {"numerator": 0, "denominator": 0, "rate": None}


def test_utilisation_uses_configured_room_capacity_and_zero_is_none():
    by_service = {row["service_id"]: row for row in metrics()["utilisation"]}

    assert by_service["service-a"] == {
        "service_id": "service-a",
        "service_name": "Session A",
        "capacity_minutes": 300,
        "utilised_minutes": 30,
        "rate": 0.1,
        "inconsistent_over_capacity": False,
    }
    assert by_service["service-b"] == {
        "service_id": "service-b",
        "service_name": "Session B",
        "capacity_minutes": 0,
        "utilised_minutes": 0,
        "rate": None,
        "inconsistent_over_capacity": False,
    }


def test_inactive_rooms_do_not_contribute_capacity():
    inputs = fixture()
    inputs["rooms"][0]["status"] = "inactive"

    result = calculate_centre_metrics(
        **inputs, timezone_name="Asia/Kolkata", now=NOW
    )

    assert result["utilisation"][0]["capacity_minutes"] == 0


def test_booking_value_uses_centre_currency_and_excludes_mixed_snapshots():
    inputs = fixture()
    inputs["bookings"][0]["currency_code_snapshot"] = "USD"

    result = calculate_centre_metrics(
        **inputs, timezone_name="Asia/Kolkata", now=NOW, currency_code="INR"
    )

    assert result["indicative_booking_value"] == {
        "currency_code": "INR",
        "current_month_minor": 0,
        "previous_month_minor": 7000,
    }


def test_risk_projection_reuses_rules_and_never_leaks_clinical_values():
    risks = metrics()["members_at_risk"]

    assert risks == [
        {
            "id": "patient-active",
            "display_name": "Active Member",
            "follow_up_recommended": True,
            "evidence_class": "urgent_reading",
            "date": "2026-02-28",
            "action": "Suggest a doctor consultation or retest.",
        },
        {
            "id": "patient-never",
            "display_name": "Never Seen",
            "follow_up_recommended": True,
            "evidence_class": "marker_trend",
            "date": "2026-02-19",
            "action": "Suggest a doctor consultation or retest.",
        },
    ]
    serialized = repr(risks).lower()
    for forbidden in ("999", "5.8", "diagnosis", "treatment", "hba1c"):
        assert forbidden not in serialized
