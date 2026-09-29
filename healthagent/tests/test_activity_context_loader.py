import pytest

from app.common.context_loader import LOG_KINDS, ContextLoader
from tests.fakes import FakeSupabase

USER, OTHER = "user-1", "user-2"


def test_unconfigured_is_not_the_same_as_empty():
    """Review Focus 2: 'we could not look' must never read as 'you have none'."""
    loader = ContextLoader(FakeSupabase({"meals": []}))
    empty = loader.logs(USER, "meals", days=30, limit=10)
    assert empty["status"] == "empty"
    assert empty["items"] == []

    unconfigured = loader.documents(USER, kind="lab_report", limit=5)
    assert unconfigured["status"] == "unconfigured"
    assert "reason" in unconfigured
    assert unconfigured["status"] != "empty"


def test_logs_reject_a_kind_outside_the_allowlist():
    loader = ContextLoader(FakeSupabase({}))
    with pytest.raises(ValueError):
        loader.logs(USER, "predictions", days=30, limit=10)
    assert "medications" not in LOG_KINDS
    assert "lab_results" in LOG_KINDS


def test_activity_session_is_scoped_to_the_user():
    db = FakeSupabase(
        {
            "activity_sessions": [
                {"id": "s1", "user_id": USER, "activity_type": "running",
                 "duration_seconds": 1800}
            ]
        }
    )
    loader = ContextLoader(db)
    assert loader.activity_session(USER, "s1")["id"] == "s1"
    assert loader.activity_session(OTHER, "s1") is None


def test_past_sessions_exclude_other_users_and_filter_by_type():
    db = FakeSupabase(
        {
            "activity_sessions": [
                {"id": "s1", "user_id": USER, "activity_type": "running",
                 "started_at": "2026-09-20T10:00:00+00:00", "duration_seconds": 1800,
                 "summary": {}},
                {"id": "s2", "user_id": USER, "activity_type": "yoga",
                 "started_at": "2026-09-21T10:00:00+00:00", "duration_seconds": 1800,
                 "summary": {}},
                {"id": "s3", "user_id": OTHER, "activity_type": "running",
                 "started_at": "2026-09-22T10:00:00+00:00", "duration_seconds": 1800,
                 "summary": {}},
            ]
        }
    )
    out = ContextLoader(db).past_activity_sessions(USER, "running", limit=10, window_days=36500)
    assert [r["id"] for r in out["items"]] == ["s1"]
    assert out["status"] == "ok"


def test_past_sessions_never_return_raw_samples():
    db = FakeSupabase(
        {
            "activity_sessions": [
                {"id": "s1", "user_id": USER, "activity_type": "running",
                 "started_at": "2026-09-20T10:00:00+00:00", "duration_seconds": 1800,
                 "summary": {"heartRate": 150}, "samples": [{"heartRate": 1}] * 500},
            ]
        }
    )
    out = ContextLoader(db).past_activity_sessions(USER, "running", limit=10, window_days=36500)
    assert "samples" not in out["items"][0]


def test_safety_facts_are_returned_for_the_user_only():
    db = FakeSupabase(
        {
            "medications": [
                {"id": "m1", "user_id": USER, "title": "Metformin",
                 "recorded_at": "2026-09-01T00:00:00+00:00", "notes": "", "fields": {}},
                {"id": "m2", "user_id": OTHER, "title": "Warfarin",
                 "recorded_at": "2026-09-01T00:00:00+00:00", "notes": "", "fields": {}},
            ]
        }
    )
    out = ContextLoader(db).safety_facts(USER)
    assert [i["title"] for i in out["items"]] == ["Metformin"]


def test_user_profile_returns_empty_envelope_when_absent():
    out = ContextLoader(FakeSupabase({"user_preferences": []})).user_profile(USER)
    assert out["status"] == "empty"
