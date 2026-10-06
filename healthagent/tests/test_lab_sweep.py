"""Uploads that never finished.

Both cases are routine rather than exceptional, and both are invisible without
a sweep: the user is looking at a spinner that will never resolve, and nothing
in the system is going to resolve it, because the guard that stops a webhook
retry re-extracting a report also stops anything picking up a stalled one.
"""

from datetime import datetime, timedelta, timezone

from app.scheduler.lab_sweep import sweep_uploads
from app.scheduler.plan import (
    LAB_STALL_MINUTES,
    orphaned_upload_ids,
    stalled_upload_ids,
)
from tests.fakes import FakeSupabase

NOW = datetime(2026, 10, 6, 12, 0, tzinfo=timezone.utc)
USER = "00000000-0000-0000-0000-00000000000a"


def upload(upload_id, status, minutes_ago=0):
    return {
        "id": upload_id, "user_id": USER, "status": status,
        "created_at": (NOW - timedelta(minutes=minutes_ago)).isoformat(),
        "updated_at": (NOW - timedelta(minutes=minutes_ago)).isoformat(),
    }


# ── The decisions, as pure functions ─────────────────────────────────────────

def test_an_upload_stuck_extracting_past_the_window_is_stalled():
    uploads = [upload("u1", "extracting", minutes_ago=LAB_STALL_MINUTES + 1)]

    assert stalled_upload_ids(uploads, NOW) == ["u1"]


def test_an_upload_still_inside_the_window_is_left_alone():
    """Extraction of a multi-page photographed panel legitimately takes a while.
    Failing it early is worse than waiting."""
    uploads = [upload("u1", "extracting", minutes_ago=LAB_STALL_MINUTES - 1)]

    assert stalled_upload_ids(uploads, NOW) == []


def test_an_upload_that_is_merely_waiting_is_not_stalled():
    assert stalled_upload_ids([upload("u1", "uploaded", minutes_ago=600)], NOW) == []


def test_an_upload_with_an_unreadable_timestamp_is_left_alone():
    """Better a stuck row than a sweep that fails healthy uploads because it
    could not parse a date."""
    broken = {**upload("u1", "extracting", minutes_ago=600), "updated_at": "not a date",
              "created_at": None}

    assert stalled_upload_ids([broken], NOW) == []


def test_an_upload_with_no_files_is_orphaned():
    """The phone writes to Storage then inserts the row; a crash between the two
    leaves a report with nothing to read."""
    uploads = [upload("u1", "uploaded"), upload("u2", "uploaded")]

    assert orphaned_upload_ids(uploads, ["u2"]) == ["u1"]


def test_an_upload_already_being_read_is_not_orphaned():
    assert orphaned_upload_ids([upload("u1", "extracting")], []) == []


# ── Applying them ────────────────────────────────────────────────────────────

def test_the_sweep_fails_a_stalled_upload_with_a_usable_reason():
    db = FakeSupabase({
        "lab_uploads": [upload("u1", "extracting", minutes_ago=120)],
        "lab_upload_files": [{"upload_id": "u1"}],
    })

    result = sweep_uploads(db, NOW)

    assert result["stalled"] == 1
    row = db.tables["lab_uploads"][0]
    assert row["status"] == "failed"
    assert "again" in row["error"], "the user needs to be told what to do"


def test_the_sweep_fails_an_orphaned_upload():
    db = FakeSupabase({
        "lab_uploads": [upload("u1", "uploaded")],
        "lab_upload_files": [],
    })

    assert sweep_uploads(db, NOW)["orphaned"] == 1
    assert db.tables["lab_uploads"][0]["status"] == "failed"


def test_the_sweep_leaves_healthy_uploads_untouched():
    db = FakeSupabase({
        "lab_uploads": [upload("u1", "uploaded"), upload("u2", "extracting")],
        "lab_upload_files": [{"upload_id": "u1"}, {"upload_id": "u2"}],
    })

    assert sweep_uploads(db, NOW) == {"stalled": 0, "orphaned": 0}
    assert {r["status"] for r in db.tables["lab_uploads"]} == {"uploaded", "extracting"}


def test_the_sweep_ignores_reports_already_finished():
    db = FakeSupabase({
        "lab_uploads": [upload("u1", "confirmed"), upload("u2", "failed")],
        "lab_upload_files": [],
    })

    assert sweep_uploads(db, NOW) == {"stalled": 0, "orphaned": 0}


def test_a_failed_file_query_does_not_fail_every_upload_in_flight():
    """Treating "we could not read the files table" as "there are no files"
    would mark every in-flight upload failed on one transient error."""
    class Broken(FakeSupabase):
        def table(self, name):
            if name == "lab_upload_files":
                raise RuntimeError("connection reset")
            return super().table(name)

    db = Broken({"lab_uploads": [upload("u1", "uploaded")]})

    assert sweep_uploads(db, NOW)["orphaned"] == 0
    assert db.tables["lab_uploads"][0]["status"] == "uploaded"


def test_the_sweep_never_raises():
    """A reconciliation sweep that dies takes the scheduler tick with it, and
    that stops every scheduled thing in the product."""
    class Broken:
        def table(self, name):
            raise RuntimeError("database is on fire")

    assert sweep_uploads(Broken(), NOW) == {"stalled": 0, "orphaned": 0}
