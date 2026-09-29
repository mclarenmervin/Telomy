import os
from fastapi.testclient import TestClient

os.environ.setdefault("SUPABASE_URL", "https://x.supabase.co")
os.environ.setdefault("SUPABASE_SERVICE_KEY", "service-key")
os.environ.setdefault("WEBHOOK_SECRET", "shh")
os.environ.setdefault("REDIS_URL", "redis://localhost:6379/0")
os.environ.setdefault("QUEUE_NAME", "events:realtime")

from app.gateway.main import app
from app.gateway.queue_provider import get_job_queue


class FakeQueue:
    def __init__(self):
        self.jobs = []

    def enqueue(self, job):
        self.jobs.append(job)


VALID_PAYLOAD = {
    "type": "INSERT",
    "table": "events",
    "record": {
        "id": "evt_1",
        "user_id": "u1",
        "event_type": "alcohol",
        "status": "started",
        "source": "manual",
        "started_at": "2026-09-12T18:42:10Z",
        "metadata": {},
    },
    "old_record": None,
}


def test_valid_webhook_enqueues_job_and_returns_202():
    fake_queue = FakeQueue()
    app.dependency_overrides[get_job_queue] = lambda: fake_queue
    client = TestClient(app)

    response = client.post(
        "/webhooks/events",
        json=VALID_PAYLOAD,
        headers={"x-webhook-secret": "shh"},
    )

    assert response.status_code == 202
    assert fake_queue.jobs == [
        {"event_id": "evt_1", "user_id": "u1", "event_type": "alcohol", "status": "started"}
    ]
    app.dependency_overrides.clear()


def test_wrong_secret_returns_401_and_does_not_enqueue():
    fake_queue = FakeQueue()
    app.dependency_overrides[get_job_queue] = lambda: fake_queue
    client = TestClient(app)

    response = client.post(
        "/webhooks/events",
        json=VALID_PAYLOAD,
        headers={"x-webhook-secret": "wrong"},
    )

    assert response.status_code == 401
    assert fake_queue.jobs == []
    app.dependency_overrides.clear()


def test_missing_secret_header_returns_401():
    fake_queue = FakeQueue()
    app.dependency_overrides[get_job_queue] = lambda: fake_queue
    client = TestClient(app)

    response = client.post("/webhooks/events", json=VALID_PAYLOAD)

    assert response.status_code == 401
    app.dependency_overrides.clear()


def test_malformed_payload_returns_422():
    client = TestClient(app)
    response = client.post(
        "/webhooks/events",
        json={"type": "INSERT", "table": "events"},
        headers={"x-webhook-secret": "shh"},
    )
    assert response.status_code == 422


def test_health_endpoint():
    client = TestClient(app)
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}
