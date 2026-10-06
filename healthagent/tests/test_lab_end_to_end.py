"""Upload to confirmed value, through every real piece.

Each stage is tested on its own elsewhere. This asserts they compose, which is a
different claim: a scanner that returns the right candidate and an ingest step
that expects a slightly different shape both pass their own tests and produce
nothing together.

The route is the real one throughout — the webhook enqueues, the worker dequeues
and reads from storage, the API confirms, and the projection lands with
`origin='server'`. Only the queue, the clock and object storage are fakes, and
object storage is a dict keyed by the same path the policies key on.
"""

from datetime import datetime, timezone

from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.common.supabase_client import get_supabase_client
from app.gateway.api.labs import router as labs_router
from app.gateway.auth import current_user_id
from app.gateway.lab_webhooks import router as webhook_router
from app.gateway.queue_provider import get_lab_queue, get_score_queue
from app.extraction_worker.handlers import process_lab_job
from tests.fakes import FakeSupabase
from tests.lab_fixtures import lab_report_pdf

USER = "00000000-0000-0000-0000-00000000000a"
UPLOAD = "11111111-1111-4111-8111-111111111111"
PREFIX = f"{USER}/2026/{UPLOAD}/"
PATH = f"{PREFIX}0.pdf"
SECRET = "test-secret"


class SpyQueue:
    def __init__(self):
        self.jobs = []

    def enqueue(self, job):
        self.jobs.append(job)


def build(monkeypatch, rows=None):
    monkeypatch.setenv("SUPABASE_URL", "https://x.supabase.co")
    monkeypatch.setenv("SUPABASE_SERVICE_KEY", "k")
    monkeypatch.setenv("WEBHOOK_SECRET", SECRET)

    db = FakeSupabase(
        tables={
            "lab_uploads": [],
            "lab_upload_files": [],
            "biomarker_results": [],
            "lab_escalations": [],
            "health_measurements": [],
        },
        objects={PATH: lab_report_pdf(rows=rows)},
    )
    lab_queue, score_queue = SpyQueue(), SpyQueue()

    app = FastAPI()
    app.include_router(webhook_router)
    app.include_router(labs_router)
    app.dependency_overrides[current_user_id] = lambda: USER
    app.dependency_overrides[get_supabase_client] = lambda: db
    app.dependency_overrides[get_lab_queue] = lambda: lab_queue
    app.dependency_overrides[get_score_queue] = lambda: score_queue
    return TestClient(app), db, lab_queue, score_queue


def phone_uploads(db):
    """What the app does: write the object, then insert the rows."""
    db.tables["lab_uploads"].append({
        "id": UPLOAD, "user_id": USER, "status": "uploaded",
        "storage_provider": "supabase", "storage_prefix": PREFIX,
        "content_sha256": "report-digest-1",
        "created_at": datetime(2026, 10, 1, tzinfo=timezone.utc).isoformat(),
    })
    db.tables["lab_upload_files"].append({
        "id": "f1", "upload_id": UPLOAD, "storage_path": PATH,
        "content_sha256": "file-a", "page_index": 0, "kind": "pdf",
    })


def test_a_pdf_becomes_a_confirmed_value_a_score_can_read(monkeypatch):
    client, db, lab_queue, score_queue = build(monkeypatch)

    # 1. The phone uploads straight to Storage and inserts the rows.
    phone_uploads(db)

    # 2. The insert fires the webhook, which enqueues two identifiers.
    accepted = client.post(
        "/webhooks/lab-uploads",
        json={"type": "INSERT", "table": "lab_uploads",
              "record": {"id": UPLOAD, "user_id": USER, "status": "uploaded"}},
        headers={"X-Webhook-Secret": SECRET},
    )
    assert accepted.status_code == 202
    assert lab_queue.jobs == [{"upload_id": UPLOAD, "user_id": USER}]

    # 3. The worker reads the document and writes extracted rows.
    process_lab_job(lab_queue.jobs[0], db)
    assert db.tables["lab_uploads"][0]["status"] == "extracted"
    assert {r["status"] for r in db.tables["biomarker_results"]} == {"extracted"}

    # Nothing a score reads has moved yet.
    assert db.tables["health_measurements"] == []

    # 4. The user opens the confirmation screen.
    review = client.get(f"/api/v1/labs/uploads/{UPLOAD}").json()
    assert "SUNITA" in review["upload"]["patient_name"]
    assert {r["grade"] for r in review["results"]} == {"ungraded"}

    hba1c = next(r for r in review["results"] if r["biomarker_id"] == "hba1c")
    assert hba1c["raw_value"] == "7.8"
    assert hba1c["value_canonical"] == 7.8

    # 5. They confirm it is their report and the values are right.
    confirmed = client.post(
        f"/api/v1/labs/uploads/{UPLOAD}/confirm",
        json={
            "patient_is_me": True,
            "decisions": [{"result_id": r["id"], "action": "confirm"}
                          for r in review["results"]],
        },
    )
    assert confirmed.status_code == 200

    # 6. The values are now readable by a score, and survive a phone sync.
    projected = db.tables["health_measurements"]
    assert "hba1c" in {m["measurement_type"] for m in projected}
    assert {m["origin"] for m in projected} == {"server"}

    # 7. And a recompute was queued rather than run inside the request.
    assert score_queue.jobs and score_queue.jobs[0]["user_id"] == USER


def test_the_value_that_lands_is_the_one_printed_on_the_page(monkeypatch):
    """The whole point, end to end: 142 and not 70.

    A naive scanner returns the bottom of the reference interval here, which is
    a plausible fasting glucose that nothing downstream could flag.
    """
    client, db, lab_queue, _ = build(monkeypatch)
    phone_uploads(db)

    process_lab_job({"upload_id": UPLOAD, "user_id": USER}, db)

    glucose = [r for r in db.tables["biomarker_results"]
               if r["biomarker_id"] == "glucose_fasting"]
    assert {r["raw_value"] for r in glucose} == {"142", "198"}
    assert {r["context"] for r in glucose} == {"fasting", "post_prandial"}


def test_a_censored_value_reaches_the_user_but_not_a_score(monkeypatch):
    """It may be displayed and it may escalate. It must not reach biological
    age, and the way that is guaranteed is by never projecting it."""
    client, db, lab_queue, _ = build(monkeypatch)
    phone_uploads(db)
    process_lab_job({"upload_id": UPLOAD, "user_id": USER}, db)

    review = client.get(f"/api/v1/labs/uploads/{UPLOAD}").json()
    vitamin_d = next(r for r in review["results"] if r["biomarker_id"] == "vitamin_d_25oh")
    assert vitamin_d["operator"] == "<"

    client.post(
        f"/api/v1/labs/uploads/{UPLOAD}/confirm",
        json={"patient_is_me": True,
              "decisions": [{"result_id": r["id"], "action": "confirm"}
                            for r in review["results"]]},
    )

    assert "vitamin_d_25oh" not in {
        m["measurement_type"] for m in db.tables["health_measurements"]
    }


def test_a_critical_value_escalates_before_the_user_confirms_anything(monkeypatch):
    client, db, lab_queue, _ = build(
        monkeypatch, rows=[("Haemoglobin", "4.1", "g/dL", "13.0 - 17.0")]
    )
    phone_uploads(db)

    process_lab_job({"upload_id": UPLOAD, "user_id": USER}, db)

    assert len(db.tables["lab_escalations"]) == 1
    message = db.tables["lab_escalations"][0]["message"]
    assert "4.1" in message and "doctor" in message.lower()
    # Still unconfirmed, and still invisible to every score.
    assert db.tables["lab_uploads"][0]["status"] == "extracted"
    assert db.tables["health_measurements"] == []


def test_a_report_naming_someone_else_never_reaches_the_record(monkeypatch):
    client, db, lab_queue, _ = build(monkeypatch)
    phone_uploads(db)
    process_lab_job({"upload_id": UPLOAD, "user_id": USER}, db)

    review = client.get(f"/api/v1/labs/uploads/{UPLOAD}").json()
    refused = client.post(
        f"/api/v1/labs/uploads/{UPLOAD}/confirm",
        json={"patient_is_me": False,
              "decisions": [{"result_id": r["id"], "action": "confirm"}
                            for r in review["results"]]},
    )

    assert refused.status_code == 409
    assert db.tables["health_measurements"] == []
    assert db.tables["lab_uploads"][0]["status"] == "extracted"


def test_a_redelivered_webhook_does_not_double_the_panel(monkeypatch):
    """Supabase retries. Two deliveries must not produce two of every value."""
    client, db, lab_queue, _ = build(monkeypatch)
    phone_uploads(db)

    process_lab_job({"upload_id": UPLOAD, "user_id": USER}, db)
    first = len(db.tables["biomarker_results"])
    process_lab_job({"upload_id": UPLOAD, "user_id": USER}, db)

    assert len(db.tables["biomarker_results"]) == first
