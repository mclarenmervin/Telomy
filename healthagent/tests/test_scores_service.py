"""Computing and storing a user's scores.

This is the "one implementation, two callers" seam: the REST endpoint the app
reads and the agent tool both land here, so a chart and a sentence can never
disagree about the same number.
"""

from datetime import date, datetime, timedelta, timezone

from app.analytics.score_snapshot import FULL, NONE
from app.analytics.scores import compute_readiness, persist_snapshot
from tests.fakes import FakeSupabase

UTC = timezone.utc
ALICE = "00000000-0000-0000-0000-00000000000a"
AS_OF = date(2026, 10, 1)


def reading(kind, value, at, ended_at=None, user_id=ALICE):
    row = {
        "user_id": user_id,
        "measurement_type": kind,
        "value": value,
        "recorded_at": at.isoformat(),
    }
    if ended_at:
        row["ended_at"] = ended_at.isoformat()
    return row


def rows_for_a_scorable_day(tz_hours=0):
    """Readings stored in UTC that make a scorable day once localised."""
    out = []
    day = datetime(2026, 10, 1, tzinfo=UTC) - timedelta(hours=tz_hours)
    for offset in range(1, 31):
        at = day - timedelta(days=offset)
        out += [reading("hrv", 55, at), reading("restingHeartRate", 60, at)]
    out += [
        reading("hrv", 60, day + timedelta(hours=7)),
        reading("restingHeartRate", 58, day + timedelta(hours=7)),
        reading("stress", 30, day + timedelta(hours=10)),
    ]
    return out


def make_db(rows=None, profile=None):
    return FakeSupabase({
        "health_measurements": rows if rows is not None else rows_for_a_scorable_day(),
        "user_preferences": [{"user_id": ALICE, "profile": profile or {}}],
    })


def test_a_scorable_day_produces_a_snapshot():
    snapshot = compute_readiness(make_db(), ALICE, AS_OF)

    assert snapshot["score_kind"] == "readiness"
    assert snapshot["value"] is not None
    assert snapshot["user_id"] == ALICE
    assert snapshot["as_of_date"] == "2026-10-01"


def test_a_day_with_nothing_recorded_scores_none_rather_than_zero():
    snapshot = compute_readiness(make_db(rows=[]), ALICE, AS_OF)

    assert snapshot["value"] is None
    assert snapshot["data_quality"] == NONE


def test_the_users_timezone_defines_their_day():
    """A reading at 20:00 UTC on the 1st is still the 1st in London and already
    01:30 on the 2nd in Kolkata. The same stored row therefore belongs to
    different days for different users — the bug the timezone layer prevents,
    and a 5.5-hour error for every Indian user if it is ignored."""
    rows = rows_for_a_scorable_day()
    boundary = datetime(2026, 10, 1, 20, 0, tzinfo=UTC)
    rows = [r for r in rows if "stress" not in r["measurement_type"]]
    rows.append(reading("stress", 30, boundary))

    kolkata = compute_readiness(
        make_db(rows, {"timezone": "Asia/Kolkata"}), ALICE, AS_OF)
    utc = compute_readiness(make_db(rows, {"timezone": "UTC"}), ALICE, AS_OF)

    assert "Stress" not in [d["name"] for d in kolkata["drivers"]]
    assert "Stress" in [d["name"] for d in utc["drivers"]]
    assert "Stress" in kolkata["missing_inputs"]


def test_the_snapshot_records_which_timezone_defined_the_day():
    snapshot = compute_readiness(make_db(profile={"timezone": "Asia/Kolkata"}), ALICE, AS_OF)

    assert snapshot["timezone"] == "Asia/Kolkata"


def test_recomputing_the_same_day_from_the_same_data_is_identical():
    """Reproducibility: a stored number must be explainable later."""
    db = make_db()

    first = compute_readiness(db, ALICE, AS_OF)
    second = compute_readiness(db, ALICE, AS_OF)

    assert first["value"] == second["value"]
    assert first["inputs_hash"] == second["inputs_hash"]
    assert first["drivers"] == second["drivers"]


def test_persisting_a_snapshot_writes_one_row_per_day():
    db = make_db()
    snapshot = compute_readiness(db, ALICE, AS_OF)

    persist_snapshot(db, snapshot)
    persist_snapshot(db, snapshot)

    rows = db.tables["score_snapshots"]
    assert len(rows) == 1
    assert rows[0]["score_kind"] == "readiness"


def test_another_users_readings_are_never_scored():
    db = FakeSupabase({
        "health_measurements": [
            {**r, "user_id": "someone-else"} for r in rows_for_a_scorable_day()
        ],
        "user_preferences": [{"user_id": ALICE, "profile": {}}],
    })

    snapshot = compute_readiness(db, ALICE, AS_OF)

    assert snapshot["data_quality"] == NONE


def test_a_complete_day_is_marked_full():
    db = make_db()
    rows = rows_for_a_scorable_day()
    day = datetime(2026, 10, 1, tzinfo=UTC)
    # Add the remaining drivers so nothing is missing.
    for offset in range(1, 31):
        rows.append(reading("temperature", 36.5, day - timedelta(days=offset)))
    rows += [
        reading("temperature", 36.5, day + timedelta(hours=7)),
        reading("activity", 20, day - timedelta(days=1) + timedelta(hours=10)),
    ]
    start = (day - timedelta(days=1)).replace(hour=23)
    for offset in range(0, 6):
        night_start = start - timedelta(days=offset)
        rows.append(reading("sleep", 7.5, night_start,
                            night_start + timedelta(hours=7, minutes=30)))
    db = FakeSupabase({
        "health_measurements": rows,
        "user_preferences": [{"user_id": ALICE, "profile": {}}],
    })

    snapshot = compute_readiness(db, ALICE, AS_OF)

    assert snapshot["missing_inputs"] == []
    assert snapshot["data_quality"] == FULL
