from datetime import datetime, timedelta, timezone

from app.analytics.event_analysis import Reading, analyze_event
from app.dev.synthetic import generate_readings, to_readings

UTC = timezone.utc
NOW = datetime(2026, 9, 21, 12, 0, tzinfo=UTC)
USER = "00000000-0000-0000-0000-0000000000aa"


def test_generation_is_deterministic_for_a_seed():
    a = generate_readings(USER, NOW, days=3, seed=7)
    b = generate_readings(USER, NOW, days=3, seed=7)

    assert [(r["measurement_type"], r["value"], r["recorded_at"]) for r in a] == [
        (r["measurement_type"], r["value"], r["recorded_at"]) for r in b
    ]


def test_rows_match_health_measurements_shape():
    row = generate_readings(USER, NOW, days=1, seed=1)[0]

    assert set(row) >= {
        "id", "user_id", "measurement_type", "value", "unit",
        "recorded_at", "source", "device_id", "quality",
    }
    assert row["user_id"] == USER
    assert row["source"] == "wearable"


def test_covers_all_tracked_metrics():
    rows = generate_readings(USER, NOW, days=2, seed=1)

    assert {r["measurement_type"] for r in rows} == {"heartRate", "hrv", "temperature", "spo2"}


def test_event_effect_is_visible_to_the_analytics():
    start = NOW - timedelta(hours=3)
    end = NOW - timedelta(hours=2)
    rows = generate_readings(
        USER, NOW, days=14, seed=3, events=[("alcohol", start, end)]
    )

    result = analyze_event(to_readings(rows), start, end)

    assert result["data_quality"] == "full"
    assert result["metrics"]["heartRate"]["delta_during"] > 8
    assert result["metrics"]["hrv"]["delta_during"] < -5
    assert result["metrics"]["temperature"]["delta_during"] > 0.2


def test_to_readings_parses_rows():
    rows = generate_readings(USER, NOW, days=1, seed=1)

    readings = to_readings(rows)

    assert all(isinstance(r, Reading) for r in readings)
    assert readings[0].recorded_at.tzinfo is not None
