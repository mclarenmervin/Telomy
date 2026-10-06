"""The trigger that turns an uploaded report into an extraction job.

Same shape as the activity webhook, for the same reasons. The gateway is a
public URL, so the secret is verified before any field of the payload is read —
an unverified request could otherwise supply an arbitrary `user_id` and have us
extract, and later show, somebody else's report.

And the gateway stays out of the file's way entirely. It enqueues two
identifiers and returns; a 20MB photographed panel must never pass through here,
because that blocks a worker and couples ingest to compute (P4). The worker
re-reads the authoritative row, exactly as the activity worker does.
"""

from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.gateway.lab_webhooks import router
from app.gateway.queue_provider import get_lab_queue

SECRET = "test-secret"
BODY = {
    "type": "INSERT",
    "table": "lab_uploads",
    "record": {
        "id": "upload-1",
        "user_id": "u1",
        "status": "uploaded",
        "storage_provider": "supabase",
        "storage_prefix": "u1/2026/upload-1/",
        "content_sha256": "sha256:abc",
    },
}


class SpyQueue:
    def __init__(self):
        self.jobs = []

    def enqueue(self, job):
        self.jobs.append(job)


def _client(monkeypatch):
    monkeypatch.setenv("SUPABASE_URL", "https://x.supabase.co")
    monkeypatch.setenv("SUPABASE_SERVICE_KEY", "k")
    monkeypatch.setenv("WEBHOOK_SECRET", SECRET)
    app = FastAPI()
    app.include_router(router)
    queue = SpyQueue()
    app.dependency_overrides[get_lab_queue] = lambda: queue
    return TestClient(app), queue


def test_missing_secret_is_rejected_and_nothing_is_enqueued(monkeypatch):
    client, queue = _client(monkeypatch)

    response = client.post("/webhooks/lab-uploads", json=BODY)

    assert response.status_code == 401
    assert queue.jobs == []


def test_a_wrong_secret_is_rejected_and_nothing_is_enqueued(monkeypatch):
    client, queue = _client(monkeypatch)

    response = client.post(
        "/webhooks/lab-uploads", json=BODY, headers={"X-Webhook-Secret": "nope"}
    )

    assert response.status_code == 401
    assert queue.jobs == []


def test_a_verified_upload_is_enqueued(monkeypatch):
    client, queue = _client(monkeypatch)

    response = client.post(
        "/webhooks/lab-uploads", json=BODY, headers={"X-Webhook-Secret": SECRET}
    )

    assert response.status_code == 202
    assert queue.jobs == [{"upload_id": "upload-1", "user_id": "u1"}]


def test_only_identifiers_are_enqueued(monkeypatch):
    """The job carries no path and no content. The worker re-reads the row, so a
    webhook replay cannot pin extraction to a stale location, and a forged
    payload has nothing useful to forge."""
    client, queue = _client(monkeypatch)

    client.post("/webhooks/lab-uploads", json=BODY, headers={"X-Webhook-Secret": SECRET})

    assert set(queue.jobs[0]) == {"upload_id", "user_id"}


def test_an_update_to_an_existing_upload_is_not_re_extracted(monkeypatch):
    """Confirming a panel UPDATEs lab_uploads. Re-running the extractor on that
    would reprocess the report every time the user touched it."""
    client, queue = _client(monkeypatch)

    response = client.post(
        "/webhooks/lab-uploads",
        json={**BODY, "type": "UPDATE", "record": {**BODY["record"], "status": "confirmed"}},
        headers={"X-Webhook-Secret": SECRET},
    )

    assert response.status_code == 202
    assert queue.jobs == []


def test_a_row_that_is_already_being_read_is_not_enqueued_twice(monkeypatch):
    """Supabase retries webhooks, so this endpoint must be idempotent by shape.
    A row already past `uploaded` has a worker on it."""
    client, queue = _client(monkeypatch)

    client.post(
        "/webhooks/lab-uploads",
        json={**BODY, "record": {**BODY["record"], "status": "extracting"}},
        headers={"X-Webhook-Secret": SECRET},
    )

    assert queue.jobs == []
