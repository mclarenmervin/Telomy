"""Getting a genetics export in, and keeping almost none of it.

The webhook and the worker are clones of the lab ones in shape, so most of
what is asserted here is the shape being the same. The substance is the last
section: what reaches the database, and what provably does not.
"""

from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.extraction_worker.genetics_handler import (
    FAILED,
    GENETICS_JOB_KIND,
    IMPORTED,
    UNREADABLE,
    process_genetics_job,
)
from app.gateway.genetic_webhooks import router
from app.gateway.queue_provider import get_genetics_queue
from tests.fakes import FakeSupabase

SECRET = "s"
ALICE = "00000000-0000-0000-0000-00000000000a"
BOB = "00000000-0000-0000-0000-00000000000b"


class FakeQueue:
    def __init__(self):
        self.jobs = []

    def enqueue(self, job):
        self.jobs.append(job)


def client_with(queue, monkeypatch):
    monkeypatch.setenv("SUPABASE_URL", "https://x.supabase.co")
    monkeypatch.setenv("SUPABASE_SERVICE_KEY", "k")
    monkeypatch.setenv("WEBHOOK_SECRET", SECRET)
    monkeypatch.setenv("REDIS_URL", "redis://localhost:6379/0")

    app = FastAPI()
    app.include_router(router)
    app.dependency_overrides[get_genetics_queue] = lambda: queue
    return TestClient(app)


def payload(status="uploaded", kind="INSERT", user_id=ALICE):
    return {
        "type": kind,
        "table": "genetic_uploads",
        "record": {"id": "u1", "user_id": user_id, "status": status},
    }


# ── The webhook ──────────────────────────────────────────────────────────────

def test_an_upload_becomes_a_job(monkeypatch):
    queue = FakeQueue()
    response = client_with(queue, monkeypatch).post(
        "/webhooks/genetic-uploads", json=payload(), headers={"x-webhook-secret": SECRET}
    )

    assert response.status_code == 202
    assert queue.jobs == [
        {"kind": GENETICS_JOB_KIND, "upload_id": "u1", "user_id": ALICE}
    ]


def test_a_request_without_the_secret_is_refused_before_any_field_is_read(monkeypatch):
    """The gateway is a public URL. An unverified request could supply an
    arbitrary user_id."""
    queue = FakeQueue()
    response = client_with(queue, monkeypatch).post(
        "/webhooks/genetic-uploads", json=payload()
    )

    assert response.status_code == 401
    assert queue.jobs == []


def test_a_wrong_secret_is_refused(monkeypatch):
    queue = FakeQueue()
    response = client_with(queue, monkeypatch).post(
        "/webhooks/genetic-uploads", json=payload(),
        headers={"x-webhook-secret": "nope"},
    )

    assert response.status_code == 401
    assert queue.jobs == []


def test_the_workers_own_update_does_not_start_a_second_import(monkeypatch):
    """Supabase retries webhooks and the worker UPDATEs this row when it
    finishes. Re-importing is harmless to the table and is still a second
    download of somebody's genome."""
    queue = FakeQueue()
    client = client_with(queue, monkeypatch)

    client.post("/webhooks/genetic-uploads", json=payload(kind="UPDATE"),
                headers={"x-webhook-secret": SECRET})
    client.post("/webhooks/genetic-uploads", json=payload(status="imported"),
                headers={"x-webhook-secret": SECRET})

    assert queue.jobs == []


def test_the_job_carries_no_path(monkeypatch):
    """So a replayed webhook cannot pin an import to a stale location, and a
    forged payload has nothing useful to forge."""
    queue = FakeQueue()
    client_with(queue, monkeypatch).post(
        "/webhooks/genetic-uploads", json=payload(), headers={"x-webhook-secret": SECRET}
    )

    assert set(queue.jobs[0]) == {"kind", "upload_id", "user_id"}


# ── The worker ───────────────────────────────────────────────────────────────

RAW = (
    "# rsid\tchromosome\tposition\tgenotype\n"
    "rs429358\t19\t45411941\tCT\n"
    "rs7412\t19\t45412079\tCC\n"
    "rs7903146\t10\t114758349\tTT\n"
    "rs1801133\t1\t11856378\tTT\n"
    "rs2282679\t4\t72618334\tGG\n"
)


class FakeStorage:
    def __init__(self, files):
        self.files = files
        self.asked = []

    def from_(self, bucket):
        self.asked.append(bucket)
        return self

    def download(self, path):
        if path not in self.files:
            raise LookupError(path)
        return self.files[path].encode()


def db_with_upload(user_id=ALICE, status="uploaded", body=RAW, path=None):
    path = path or f"{user_id}/2026/u1/raw.txt"
    db = FakeSupabase({
        "genetic_uploads": [{
            "id": "u1", "user_id": user_id, "status": status,
            "storage_provider": "supabase", "storage_path": path,
            "content_sha256": "abc",
        }],
        "genetic_variants": [],
    })
    db.storage = FakeStorage({path: body})
    return db


def stored(db):
    return {r["rsid"]: r["genotype"] for r in db.tables["genetic_variants"]}


def upload_row(db):
    return db.tables["genetic_uploads"][0]


def test_an_import_keeps_only_the_allowlisted_variants():
    db = db_with_upload()

    process_genetics_job({"upload_id": "u1", "user_id": ALICE}, db)

    assert stored(db) == {"rs1801133": "TT", "rs2282679": "GG"}


def test_apoe_in_the_file_reaches_no_row_and_no_column():
    """The hazard, end to end. Both APOE SNPs and a diabetes risk variant are
    in the file; nothing about any of them exists afterwards -- not in the
    variants table, not in the upload row's failure reason, not anywhere."""
    db = db_with_upload()

    process_genetics_job({"upload_id": "u1", "user_id": ALICE}, db)

    everything = repr(db.tables)
    for refused in ("rs429358", "rs7412", "rs7903146"):
        assert refused not in everything


def test_the_upload_records_counts_and_no_identities():
    db = db_with_upload()

    process_genetics_job({"upload_id": "u1", "user_id": ALICE}, db)

    row = upload_row(db)
    assert row["status"] == IMPORTED
    assert row["rows_read"] == 5
    assert row["rows_kept"] == 2
    assert row["source_format"] == "23andme"


def test_the_genetics_bucket_is_the_one_read():
    db = db_with_upload()

    process_genetics_job({"upload_id": "u1", "user_id": ALICE}, db)

    assert db.storage.asked == ["genetics"]


def test_another_users_upload_is_not_imported():
    """This process holds service-role credentials and bypasses RLS by
    design, so a job naming someone else's upload is refused here or nowhere."""
    db = db_with_upload(user_id=BOB)

    process_genetics_job({"upload_id": "u1", "user_id": ALICE}, db)

    assert stored(db) == {}
    assert upload_row(db)["status"] == "uploaded"


def test_an_upload_already_imported_is_left_alone():
    db = db_with_upload(status="imported")

    process_genetics_job({"upload_id": "u1", "user_id": ALICE}, db)

    assert stored(db) == {}


def test_a_file_in_no_recognised_format_is_terminal_and_says_so():
    """`unreadable` and not `failed`: there is nothing to retry, and the user
    needs to be told to upload a different file rather than to wait."""
    db = db_with_upload(body="this is a photograph of a cat")

    process_genetics_job({"upload_id": "u1", "user_id": ALICE}, db)

    row = upload_row(db)
    assert row["status"] == UNREADABLE
    assert row["failure_reason"]


def test_a_missing_object_fails_with_a_reason_rather_than_a_spinner():
    db = db_with_upload()
    db.storage.files = {}

    process_genetics_job({"upload_id": "u1", "user_id": ALICE}, db)

    assert upload_row(db)["status"] == FAILED
    assert upload_row(db)["failure_reason"]


def test_a_malformed_job_is_ignored_rather_than_taking_the_worker_down():
    """The next job in the lane belongs to somebody else."""
    db = db_with_upload()

    process_genetics_job({}, db)

    assert stored(db) == {}


def test_an_import_stamps_the_catalog_version_it_filtered_against():
    """If the allowlist is narrowed later, this says which rows predate it."""
    db = db_with_upload()

    process_genetics_job({"upload_id": "u1", "user_id": ALICE}, db)

    assert db.tables["genetic_variants"][0]["variants_version"]


# ── The sweep that makes the webhook optional ────────────────────────────────

def test_the_sweep_imports_an_upload_no_webhook_reached():
    """`genetic_uploads` has no webhook trigger. The lab one was created in
    the Supabase dashboard because it embeds the shared secret and a
    migration cannot make it, so this feature would otherwise have shipped
    depending on somebody remembering to click something -- and the failure
    mode is a person watching "Reading your file..." forever with nothing in
    any log to say why."""
    from app.scheduler.genetics_sweep import sweep_genetics

    db = db_with_upload()

    result = sweep_genetics(db)

    assert result["imported"] == 1
    assert stored(db) == {"rs1801133": "TT", "rs2282679": "GG"}
    assert upload_row(db)["status"] == IMPORTED


def test_the_sweep_leaves_an_upload_already_imported_alone():
    """Safe to run beside a webhook, if one is ever configured: the handler
    re-reads the row and skips anything not still `uploaded`, the same guard
    that makes a webhook retry harmless."""
    from app.scheduler.genetics_sweep import sweep_genetics

    db = db_with_upload(status="imported")

    assert sweep_genetics(db)["imported"] == 0
    assert stored(db) == {}


def test_the_sweep_survives_a_database_that_will_not_answer():
    """A scheduler that dies on a transient error stops every scheduled
    thing in the product."""
    from app.scheduler.genetics_sweep import sweep_genetics

    class Broken:
        def table(self, name):
            raise RuntimeError("no")

    assert sweep_genetics(Broken()) == {"imported": 0}


def test_the_scheduler_runs_the_genetics_sweep_every_tick():
    """Not on the ten-minute lab cadence. With no webhook this IS the import
    path, and a person is watching a spinner on the other side of it."""
    import inspect

    from app.scheduler import main

    source = inspect.getsource(main.tick)
    before_lab_gate = source.split("if _due_for_lab_sweep")[0]
    assert "sweep_genetics(supabase)" in before_lab_gate
