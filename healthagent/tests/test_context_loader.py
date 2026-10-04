from datetime import datetime, timedelta, timezone

from app.common.context_loader import ContextLoader
from tests.fakes import FakeSupabase

UTC = timezone.utc
START = datetime(2026, 9, 20, 20, 0, tzinfo=UTC)
END = datetime(2026, 9, 20, 21, 0, tzinfo=UTC)
ALICE = "00000000-0000-0000-0000-00000000000a"
BOB = "00000000-0000-0000-0000-00000000000b"


def reading(user, mtype, value, at):
    return {
        "user_id": user, "measurement_type": mtype, "value": value,
        "recorded_at": at.isoformat(),
    }


def test_load_event_returns_the_users_event():
    db = FakeSupabase({"events": [{"id": "e1", "user_id": ALICE, "event_type": "alcohol"}]})

    event = ContextLoader(db).load_event(ALICE, "e1")

    assert event["event_type"] == "alcohol"


def test_load_event_never_returns_another_users_event():
    db = FakeSupabase({"events": [{"id": "e1", "user_id": BOB, "event_type": "alcohol"}]})

    assert ContextLoader(db).load_event(ALICE, "e1") is None


def test_load_readings_only_returns_this_users_tracked_metrics_in_range():
    db = FakeSupabase({"health_measurements": [
        reading(ALICE, "heartRate", 70, START),
        reading(BOB, "heartRate", 99, START),
        reading(ALICE, "steps", 1000, START),
        reading(ALICE, "heartRate", 55, START - timedelta(days=30)),
    ]})

    readings = ContextLoader(db).load_readings(ALICE, START, END)

    assert [(r.measurement_type, r.value) for r in readings] == [("heartRate", 70.0)]


def test_load_readings_reads_every_page():
    rows = [reading(ALICE, "heartRate", 60 + i, START + timedelta(minutes=i)) for i in range(25)]
    db = FakeSupabase({"health_measurements": rows})

    readings = ContextLoader(db, page_size=10).load_readings(ALICE, START, END)

    assert len(readings) == 25


def test_load_other_events_returns_only_this_users_finished_events():
    db = FakeSupabase({"events": [
        {"id": "e1", "user_id": ALICE, "started_at": "2026-09-19T20:00:00+00:00",
         "ended_at": "2026-09-19T21:00:00+00:00"},
        {"id": "e2", "user_id": ALICE, "started_at": "2026-09-20T20:00:00+00:00",
         "ended_at": None},
        {"id": "e3", "user_id": BOB, "started_at": "2026-09-19T20:00:00+00:00",
         "ended_at": "2026-09-19T21:00:00+00:00"},
        {"id": "current", "user_id": ALICE, "started_at": "2026-09-18T20:00:00+00:00",
         "ended_at": "2026-09-18T21:00:00+00:00"},
    ]})

    others = ContextLoader(db).load_other_events(ALICE, "current", START - timedelta(days=14))

    assert len(others) == 1
    assert others[0][0] == datetime(2026, 9, 19, 20, 0, tzinfo=UTC)


EVENT_ID = "22222222-2222-2222-2222-222222222222"


def test_sent_check_in_reasons_returns_bare_reasons():
    db = FakeSupabase({"predictions": [
        {"user_id": ALICE, "event_id": EVENT_ID, "kind": "ack"},
        {"user_id": ALICE, "event_id": EVENT_ID, "kind": "check_in:hr_elevated"},
        {"user_id": ALICE, "event_id": EVENT_ID, "kind": "check_in:spo2_low"},
    ]})

    reasons = ContextLoader(db).sent_check_in_reasons(ALICE, EVENT_ID)

    assert reasons == {"hr_elevated", "spo2_low"}


def test_sent_check_in_reasons_is_empty_when_nothing_was_sent():
    db = FakeSupabase({"predictions": [
        {"user_id": ALICE, "event_id": EVENT_ID, "kind": "ack"},
    ]})

    assert ContextLoader(db).sent_check_in_reasons(ALICE, EVENT_ID) == set()


def test_sent_check_in_reasons_ignores_another_users_rows():
    db = FakeSupabase({"predictions": [
        {"user_id": BOB, "event_id": EVENT_ID, "kind": "check_in:hr_elevated"},
    ]})

    assert ContextLoader(db).sent_check_in_reasons(ALICE, EVENT_ID) == set()


def test_sent_check_in_reasons_ignores_other_events():
    db = FakeSupabase({"predictions": [
        {"user_id": ALICE, "event_id": "other", "kind": "check_in:hr_elevated"},
    ]})

    assert ContextLoader(db).sent_check_in_reasons(ALICE, EVENT_ID) == set()
