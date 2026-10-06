import pytest

from app.common.context_loader import LOG_KINDS, ContextLoader
from tests.fakes import FakeSupabase

USER, OTHER = "user-1", "user-2"


def test_unconfigured_is_not_the_same_as_empty():
    """Review Focus 2: 'we could not look' must never read as 'you have none'.

    Lab reports have a backend as of F3, so the distinction is now carried by a
    document class that does not: genetics exports have no bucket yet. The
    property is the same and it still has to hold somewhere real.
    """
    loader = ContextLoader(FakeSupabase({"meals": [], "lab_uploads": []}))
    empty = loader.logs(USER, "meals", days=30, limit=10)
    assert empty["status"] == "empty"
    assert empty["items"] == []

    unconfigured = loader.documents(USER, kind="genetic_record", limit=5)
    assert unconfigured["status"] == "unconfigured"
    assert "reason" in unconfigured
    assert unconfigured["status"] != "empty"


# ── Lab reports ──────────────────────────────────────────────────────────────

UPLOAD = {
    "id": "upload-1",
    "user_id": USER,
    "storage_provider": "supabase",
    "status": "extracted",
    "collected_at": "2026-09-28T07:30:00+00:00",
    "reported_at": "2026-09-29T11:00:00+00:00",
    "lab_name": "Dr Lal PathLabs",
    "patient_name": "A Patient",
    "page_count": 3,
    "is_history": False,
    "created_at": "2026-10-01T09:00:00+00:00",
}


def test_lab_reports_are_no_longer_unconfigured():
    """The storage backend exists now, so 'we cannot look' would be a lie."""
    loader = ContextLoader(FakeSupabase({"lab_uploads": [UPLOAD]}))

    result = loader.documents(USER, kind="lab_report", limit=5)

    assert result["status"] == "ok"
    assert result["items"][0]["lab_name"] == "Dr Lal PathLabs"


def test_a_user_with_no_uploads_is_empty_not_unconfigured():
    loader = ContextLoader(FakeSupabase({"lab_uploads": []}))

    assert loader.documents(USER)["status"] == "empty"


def test_documents_are_scoped_to_the_caller():
    """The worker holds service-role credentials, so this filter is the only
    thing between one user's reports and another's."""
    other = dict(UPLOAD, id="upload-2", user_id=OTHER, lab_name="Thyrocare")
    loader = ContextLoader(FakeSupabase({"lab_uploads": [UPLOAD, other]}))

    items = loader.documents(OTHER)["items"]

    assert [i["lab_name"] for i in items] == ["Thyrocare"]


def test_a_document_we_have_no_adapter_for_reads_as_unreadable():
    """Imaging lands on R2 later. Until that adapter exists, a report stored
    there is one we cannot open — which is not the same as one that is empty,
    and must not be narrated as 'you have no reports'."""
    on_r2 = dict(UPLOAD, storage_provider="r2")
    loader = ContextLoader(FakeSupabase({"lab_uploads": [on_r2]}))

    result = loader.documents(USER)

    assert result["status"] == "unconfigured"
    assert "r2" in result["reason"]


def test_an_upload_still_being_read_says_so():
    """A report mid-extraction is neither absent nor ready. The agent needs to
    be able to say 'that is still processing' rather than 'you have none'."""
    pending = dict(UPLOAD, status="extracting")
    loader = ContextLoader(FakeSupabase({"lab_uploads": [pending]}))

    assert loader.documents(USER)["items"][0]["status"] == "extracting"


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


def test_past_sessions_can_exclude_the_session_being_analysed():
    """A session must never appear in its own baseline: it would dampen its own delta."""
    rows = [
        {"id": "cur", "user_id": USER, "activity_type": "running",
         "started_at": "2026-09-29T10:00:00+00:00", "duration_seconds": 1800,
         "summary": {"heartRate": 142}},
        {"id": "old", "user_id": USER, "activity_type": "running",
         "started_at": "2026-09-28T10:00:00+00:00", "duration_seconds": 1800,
         "summary": {"heartRate": 150}},
    ]
    loader = ContextLoader(FakeSupabase({"activity_sessions": rows}))
    out = loader.past_activity_sessions(
        USER, "running", limit=10, window_days=36500, exclude_id="cur"
    )
    assert [r["id"] for r in out["items"]] == ["old"]
