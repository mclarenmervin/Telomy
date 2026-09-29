from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.gateway.activity_webhooks import router
from app.gateway.queue_provider import get_activity_queue

SECRET = "test-secret"
BODY = {
    "type": "INSERT",
    "table": "activity_sessions",
    "record": {
        "id": "s1",
        "user_id": "u1",
        "activity_type": "running",
        "samples": [{"heartRate": 1}] * 500,
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
    app.dependency_overrides[get_activity_queue] = lambda: queue
    return TestClient(app), queue


def test_missing_secret_is_rejected_and_nothing_is_enqueued(monkeypatch):
    client, queue = _client(monkeypatch)
    assert client.post("/webhooks/activity-sessions", json=BODY).status_code == 401
    assert queue.jobs == []


def test_wrong_secret_is_rejected(monkeypatch):
    client, queue = _client(monkeypatch)
    response = client.post(
        "/webhooks/activity-sessions", json=BODY, headers={"x-webhook-secret": "nope"}
    )
    assert response.status_code == 401
    assert queue.jobs == []


def test_valid_request_enqueues_ids_only_and_returns_202(monkeypatch):
    client, queue = _client(monkeypatch)
    response = client.post(
        "/webhooks/activity-sessions", json=BODY, headers={"x-webhook-secret": SECRET}
    )
    assert response.status_code == 202
    assert queue.jobs == [
        {"session_id": "s1", "user_id": "u1", "activity_type": "running"}
    ]
    assert "samples" not in queue.jobs[0]


def test_the_gateway_app_actually_mounts_the_activity_route(monkeypatch):
    """Without this, the endpoint exists but is unreachable in the running service."""
    monkeypatch.setenv("SUPABASE_URL", "https://x.supabase.co")
    monkeypatch.setenv("SUPABASE_SERVICE_KEY", "k")
    monkeypatch.setenv("WEBHOOK_SECRET", SECRET)
    from app.gateway.main import app

    client = TestClient(app)
    # 401 proves the route is mounted and reached the secret check; 404 would mean
    # the router was never included in the running app.
    assert client.post("/webhooks/activity-sessions", json=BODY).status_code == 401
    assert client.get("/health").status_code == 200
