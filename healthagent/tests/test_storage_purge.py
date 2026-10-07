"""Reclaiming objects whose owner is gone.

Deleting a `storage.objects` row removes every route to a file but leaves the
bytes in the store behind it. Postgres cannot reach that store, so account
deletion records the work and this sweep is the thing that finishes it, through
the Storage API — the only interface that removes the object as well as the row.

Under DPDP, "deleted" has to mean the bytes are gone. Between the deletion and
this sweep the files are already unreachable, because the policies key on
`auth.uid()` and that account no longer exists, but unreachable is not deleted.
"""

from app.scheduler.storage_purge import purge_storage
from tests.fakes import FakeSupabase

GONE = "00000000-0000-4000-8000-00000000dead"
OTHER = "00000000-0000-4000-8000-00000000beef"


def make_db(purges=None, objects=None):
    return FakeSupabase(
        tables={"storage_purges": purges if purges is not None else [{
            "id": "p1", "bucket_id": "lab-reports", "path_prefix": f"{GONE}/",
            "reason": "account_deleted", "requested_for": GONE,
            "attempts": 0, "purged_at": None,
            "created_at": "2026-10-01T09:00:00+00:00",
        }]},
        objects=objects if objects is not None else {
            f"{GONE}/2026/report-a/0.pdf": b"deleted user's report",
            f"{GONE}/2026/report-b/0.jpg": b"and another page",
            f"{OTHER}/2026/report-c/0.pdf": b"somebody still using the product",
        },
    )


# ── What it removes ──────────────────────────────────────────────────────────

def test_the_bytes_of_a_deleted_account_are_removed():
    db = make_db()

    result = purge_storage(db)

    assert result["objects"] == 2
    assert f"{GONE}/2026/report-a/0.pdf" not in db.storage.objects


def test_it_removes_every_file_under_the_prefix():
    """An account is a folder of reports and a report is a folder of files, so
    one queued prefix has to retire all of them."""
    db = make_db()

    purge_storage(db)

    assert not [path for path in db.storage.objects if path.startswith(f"{GONE}/")]


def test_it_does_not_touch_another_users_files():
    """The prefix is the boundary here exactly as it is everywhere else. A sweep
    that over-matched would delete live users' reports, which is unrecoverable."""
    db = make_db()

    purge_storage(db)

    assert f"{OTHER}/2026/report-c/0.pdf" in db.storage.objects


def test_a_prefix_that_merely_shares_a_leading_string_is_safe():
    """`{uid}` and `{uid}-old` are different folders. Matching on the string
    rather than the path segment would take both."""
    db = make_db(objects={
        f"{GONE}/2026/a/0.pdf": b"theirs",
        f"{GONE}-archive/2026/a/0.pdf": b"not theirs",
    })

    purge_storage(db)

    assert f"{GONE}-archive/2026/a/0.pdf" in db.storage.objects


# ── Bookkeeping ──────────────────────────────────────────────────────────────

def test_a_completed_purge_is_marked_and_not_repeated():
    db = make_db()

    purge_storage(db)

    assert db.tables["storage_purges"][0]["purged_at"] is not None

    # A second pass has nothing to do.
    assert purge_storage(db)["prefixes"] == 0


def test_an_already_purged_row_is_skipped():
    db = make_db(purges=[{
        "id": "p1", "bucket_id": "lab-reports", "path_prefix": f"{GONE}/",
        "reason": "account_deleted", "attempts": 1,
        "purged_at": "2026-10-02T09:00:00+00:00",
        "created_at": "2026-10-01T09:00:00+00:00",
    }])

    assert purge_storage(db)["prefixes"] == 0


def test_a_prefix_with_nothing_under_it_is_still_completed():
    """A user who never uploaded anything still has a purge row. Leaving it open
    forever would make the queue grow without bound and hide real failures."""
    db = make_db(objects={})

    result = purge_storage(db)

    assert result["objects"] == 0
    assert db.tables["storage_purges"][0]["purged_at"] is not None


# ── When it goes wrong ───────────────────────────────────────────────────────

def test_a_failed_removal_is_recorded_and_retried_not_marked_done():
    """The worst outcome is a row marked purged whose bytes are still there: it
    looks compliant and is not."""
    db = make_db()

    class Unreachable:
        def __init__(self, real):
            self._real = real

        # Listing still works, so the sweep knows what it should delete and
        # fails on the delete itself — the realistic shape of this failure.
        def list_under(self, prefix):
            return self._real.list_under(prefix)

        def from_(self, bucket):
            raise RuntimeError("storage is unreachable")

    db.storage = Unreachable(db.storage)

    purge_storage(db)

    row = db.tables["storage_purges"][0]
    assert row["purged_at"] is None, "it must stay on the queue"
    assert row["attempts"] == 1
    assert "unreachable" in (row["last_error"] or "")


def test_the_sweep_never_raises():
    """It runs inside the scheduler tick, and a sweep that dies takes every
    other scheduled thing with it."""
    class Broken:
        def table(self, name):
            raise RuntimeError("database is on fire")

    assert purge_storage(Broken()) == {"prefixes": 0, "objects": 0}


def test_one_failing_prefix_does_not_stop_the_others():
    db = make_db(purges=[
        {"id": "p1", "bucket_id": "lab-reports", "path_prefix": "../escape/",
         "reason": "manual", "attempts": 0, "purged_at": None,
         "created_at": "2026-10-01T09:00:00+00:00"},
        {"id": "p2", "bucket_id": "lab-reports", "path_prefix": f"{GONE}/",
         "reason": "account_deleted", "attempts": 0, "purged_at": None,
         "created_at": "2026-10-01T09:00:00+00:00"},
    ])

    purge_storage(db)

    rows = {row["id"]: row for row in db.tables["storage_purges"]}
    assert rows["p1"]["purged_at"] is None, "a malformed prefix is refused"
    assert rows["p2"]["purged_at"] is not None, "and the valid one still ran"


def test_a_prefix_that_is_not_in_normal_form_is_refused():
    """`a/../b` resolves outside the folder it names. Refused rather than
    normalised, because a purge is not something to be clever about."""
    db = make_db(
        purges=[{"id": "p1", "bucket_id": "lab-reports",
                 "path_prefix": f"{GONE}/../{OTHER}/", "reason": "manual",
                 "attempts": 0, "purged_at": None,
                 "created_at": "2026-10-01T09:00:00+00:00"}],
    )

    purge_storage(db)

    assert f"{OTHER}/2026/report-c/0.pdf" in db.storage.objects
    assert db.tables["storage_purges"][0]["purged_at"] is None


def test_an_empty_prefix_is_refused():
    """An empty prefix matches every object in the bucket."""
    db = make_db(purges=[{
        "id": "p1", "bucket_id": "lab-reports", "path_prefix": "",
        "reason": "manual", "attempts": 0, "purged_at": None,
        "created_at": "2026-10-01T09:00:00+00:00",
    }])

    purge_storage(db)

    assert len(db.storage.objects) == 3
    assert db.tables["storage_purges"][0]["purged_at"] is None
