# Gateway + Queue + Trivial Worker — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove the entire event-trigger path end-to-end — mobile insert →
Supabase webhook → gateway → Redis queue → worker → write-back → Realtime —
with a worker that does nothing intelligent yet. This is Build Order step 2.

**Architecture:** A thin FastAPI gateway verifies and enqueues webhook events
onto a Redis list; a separate worker process dequeues and writes a debug row
back to Supabase. Gateway and worker share nothing but a `common/` package
(config, logging, queue, Supabase client) — no coupling beyond that. A
one-page HTML harness (Start/Stop buttons + a Realtime subscription) is the
manual proof that the loop closes.

**Tech Stack:** Python 3.12, FastAPI, Redis (raw lists, no queue framework),
supabase-py, pytest, fakeredis (for tests — no real Redis needed to test).

**Spec:**
[Platform HLD](../../specs/2026-09-12-platform-hld.md) §3 (entry points), §4
(data model), §6 (topology) — this plan implements Build Order step 2 from
that document and from [CLAUDE.md](../../../CLAUDE.md).

## Global Constraints

- Webhook requests are rejected before any field is read if the shared secret
  does not match (Platform HLD NFR-3.1 / CLAUDE.md Security).
- No worker holds state between jobs — every job is self-contained (P3).
- Logs carry `user_id` and `event_id` on every line (CLAUDE.md Conventions).
- This is the *trivial* worker milestone — it must not import or reference
  LangGraph, memory, or any agent logic. That is Build Order step 5.
- The `debug_log` table created here is temporary, scoped to this milestone
  only, and is superseded by the real `predictions` table in step 5.

---

## File Structure

```
healthagent/
├── app/
│   ├── common/
│   │   ├── config.py           # env-driven settings
│   │   ├── logging_config.py   # logger setup + structured field helper
│   │   ├── queue.py            # JobQueue: thin Redis list wrapper
│   │   └── supabase_client.py  # cached Supabase client factory
│   ├── gateway/
│   │   ├── main.py             # FastAPI app
│   │   ├── schemas.py          # webhook payload models
│   │   ├── security.py         # secret verification
│   │   ├── queue_provider.py   # DI-friendly JobQueue accessor
│   │   └── webhooks.py         # POST /webhooks/events
│   └── worker/
│       ├── handlers.py         # process_event_job()
│       └── main.py             # process_one() + run() loop
├── tests/
│   ├── test_queue.py
│   ├── test_security.py
│   ├── test_schemas.py
│   ├── test_webhooks.py
│   └── test_worker.py
├── db/
│   └── schema.sql
├── docker/
│   ├── Dockerfile.gateway
│   └── Dockerfile.worker
├── test_ui/
│   └── index.html
├── docker-compose.yml
├── .env.example
└── requirements.txt
```

Each file owns exactly one responsibility. `common/` has no dependency on
`gateway/` or `worker/` — it is imported by both, never the reverse.

---

### Task 1: Config and Logging

**Files:**
- Create: `app/common/config.py`
- Create: `app/common/logging_config.py`
- Create: `app/__init__.py`, `app/common/__init__.py` (empty)
- Test: `tests/test_config.py`, `tests/test_logging_config.py`

**Interfaces:**
- Produces: `Settings` (attrs: `supabase_url`, `supabase_service_key`,
  `webhook_secret`, `redis_url`, `queue_name`), `get_settings() -> Settings`
- Produces: `configure_logging() -> None`, `get_logger(name: str) -> logging.Logger`,
  `log_context(**fields) -> str`

- [ ] **Step 1: Write the failing test for settings**

```python
# tests/test_config.py
import pytest
from app.common.config import get_settings


def test_get_settings_reads_env(monkeypatch):
    monkeypatch.setenv("SUPABASE_URL", "https://x.supabase.co")
    monkeypatch.setenv("SUPABASE_SERVICE_KEY", "service-key")
    monkeypatch.setenv("WEBHOOK_SECRET", "shh")
    monkeypatch.setenv("REDIS_URL", "redis://localhost:6379/0")
    monkeypatch.setenv("QUEUE_NAME", "events:realtime")

    settings = get_settings()

    assert settings.supabase_url == "https://x.supabase.co"
    assert settings.supabase_service_key == "service-key"
    assert settings.webhook_secret == "shh"
    assert settings.redis_url == "redis://localhost:6379/0"
    assert settings.queue_name == "events:realtime"


def test_get_settings_missing_var_raises(monkeypatch):
    monkeypatch.delenv("SUPABASE_URL", raising=False)
    with pytest.raises(KeyError):
        get_settings()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest tests/test_config.py -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'app.common.config'`

- [ ] **Step 3: Implement `config.py`**

```python
# app/common/config.py
import os
from dataclasses import dataclass


@dataclass(frozen=True)
class Settings:
    supabase_url: str
    supabase_service_key: str
    webhook_secret: str
    redis_url: str
    queue_name: str


def get_settings() -> Settings:
    return Settings(
        supabase_url=os.environ["SUPABASE_URL"],
        supabase_service_key=os.environ["SUPABASE_SERVICE_KEY"],
        webhook_secret=os.environ["WEBHOOK_SECRET"],
        redis_url=os.environ.get("REDIS_URL", "redis://localhost:6379/0"),
        queue_name=os.environ.get("QUEUE_NAME", "events:realtime"),
    )
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest tests/test_config.py -v`
Expected: PASS (2 tests)

- [ ] **Step 5: Write the failing test for logging**

```python
# tests/test_logging_config.py
import logging
from app.common.logging_config import get_logger, log_context


def test_get_logger_returns_named_logger():
    logger = get_logger("app.test")
    assert isinstance(logger, logging.Logger)
    assert logger.name == "app.test"


def test_log_context_formats_fields():
    result = log_context(user_id="u1", event_id="e1")
    assert result == "user_id=u1 event_id=e1"


def test_log_context_skips_none_values():
    result = log_context(user_id="u1", event_id=None)
    assert result == "user_id=u1"
```

- [ ] **Step 6: Run test to verify it fails**

Run: `pytest tests/test_logging_config.py -v`
Expected: FAIL with `ModuleNotFoundError`

- [ ] **Step 7: Implement `logging_config.py`**

```python
# app/common/logging_config.py
import logging
import sys


def configure_logging() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
        stream=sys.stdout,
    )


def get_logger(name: str) -> logging.Logger:
    return logging.getLogger(name)


def log_context(**fields: object) -> str:
    return " ".join(f"{k}={v}" for k, v in fields.items() if v is not None)
```

- [ ] **Step 8: Run test to verify it passes**

Run: `pytest tests/test_logging_config.py -v`
Expected: PASS (3 tests)

- [ ] **Step 9: Commit**

```bash
git add app/__init__.py app/common/__init__.py app/common/config.py app/common/logging_config.py tests/test_config.py tests/test_logging_config.py
git commit -m "feat: add settings and logging helpers"
```

---

### Task 2: Job Queue

**Files:**
- Create: `app/common/queue.py`
- Test: `tests/test_queue.py`

**Interfaces:**
- Consumes: nothing from Task 1 directly (takes a raw redis client)
- Produces: `JobQueue(redis_client, queue_name)` with
  `.enqueue(job: dict) -> None` and `.dequeue(timeout: int = 5) -> dict | None`

This is a **thin wrapper over Redis lists** — `LPUSH` to enqueue, blocking
`BRPOP` to dequeue. No queue framework. Both gateway and worker import this
same class so there is exactly one definition of "how a job looks on the wire."

- [ ] **Step 1: Write the failing tests**

```python
# tests/test_queue.py
import fakeredis
from app.common.queue import JobQueue


def make_queue() -> JobQueue:
    redis_client = fakeredis.FakeStrictRedis()
    return JobQueue(redis_client, "events:realtime")


def test_enqueue_then_dequeue_returns_same_job():
    queue = make_queue()
    job = {"event_id": "e1", "user_id": "u1", "event_type": "alcohol"}

    queue.enqueue(job)
    result = queue.dequeue(timeout=1)

    assert result == job


def test_dequeue_empty_queue_returns_none():
    queue = make_queue()
    result = queue.dequeue(timeout=1)
    assert result is None


def test_enqueue_is_fifo():
    queue = make_queue()
    queue.enqueue({"event_id": "first"})
    queue.enqueue({"event_id": "second"})

    assert queue.dequeue(timeout=1) == {"event_id": "first"}
    assert queue.dequeue(timeout=1) == {"event_id": "second"}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest tests/test_queue.py -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'app.common.queue'`

- [ ] **Step 3: Implement `queue.py`**

```python
# app/common/queue.py
import json
from typing import Any


class JobQueue:
    """Thin wrapper over a Redis list. FIFO via LPUSH + BRPOP."""

    def __init__(self, redis_client: Any, queue_name: str):
        self._redis = redis_client
        self._queue_name = queue_name

    def enqueue(self, job: dict) -> None:
        self._redis.lpush(self._queue_name, json.dumps(job))

    def dequeue(self, timeout: int = 5) -> dict | None:
        result = self._redis.brpop(self._queue_name, timeout=timeout)
        if result is None:
            return None
        _, raw_job = result
        return json.loads(raw_job)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest tests/test_queue.py -v`
Expected: PASS (3 tests)

- [ ] **Step 5: Commit**

```bash
git add app/common/queue.py tests/test_queue.py
git commit -m "feat: add Redis-backed job queue"
```

---

### Task 3: Webhook Secret Verification

**Files:**
- Create: `app/gateway/security.py`
- Create: `app/gateway/__init__.py` (empty)
- Test: `tests/test_security.py`

**Interfaces:**
- Produces: `verify_webhook_signature(received: str | None, expected: str) -> bool`

This is the gate from Platform HLD NFR-3.1 — no field of the payload is
trusted until this returns `True`.

- [ ] **Step 1: Write the failing tests**

```python
# tests/test_security.py
from app.gateway.security import verify_webhook_signature


def test_matching_secret_returns_true():
    assert verify_webhook_signature("shh", "shh") is True


def test_wrong_secret_returns_false():
    assert verify_webhook_signature("wrong", "shh") is False


def test_missing_secret_returns_false():
    assert verify_webhook_signature(None, "shh") is False


def test_empty_secret_returns_false():
    assert verify_webhook_signature("", "shh") is False
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest tests/test_security.py -v`
Expected: FAIL with `ModuleNotFoundError`

- [ ] **Step 3: Implement `security.py`**

```python
# app/gateway/security.py
import hmac


def verify_webhook_signature(received: str | None, expected: str) -> bool:
    if not received:
        return False
    return hmac.compare_digest(received, expected)
```

`hmac.compare_digest` is used instead of `==` to avoid a timing side-channel
on the secret comparison.

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest tests/test_security.py -v`
Expected: PASS (4 tests)

- [ ] **Step 5: Commit**

```bash
git add app/gateway/__init__.py app/gateway/security.py tests/test_security.py
git commit -m "feat: add webhook secret verification"
```

---

### Task 4: Webhook Payload Schema

**Files:**
- Create: `app/gateway/schemas.py`
- Test: `tests/test_schemas.py`

**Interfaces:**
- Produces: `EventRecord` (pydantic model: `id`, `user_id`, `event_type`,
  `status`, `source`, `started_at`, `ended_at: str | None`,
  `metadata: dict`), `SupabaseWebhookPayload` (`type`, `table`,
  `record: EventRecord`, `old_record: EventRecord | None`)

This mirrors the payload shape Supabase Database Webhooks actually send
(Platform HLD §3.1).

- [ ] **Step 1: Write the failing tests**

```python
# tests/test_schemas.py
import pytest
from pydantic import ValidationError
from app.gateway.schemas import SupabaseWebhookPayload


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
        "metadata": {"declared_qty": 1},
    },
    "old_record": None,
}


def test_valid_payload_parses():
    payload = SupabaseWebhookPayload(**VALID_PAYLOAD)
    assert payload.record.user_id == "u1"
    assert payload.record.event_type == "alcohol"


def test_missing_user_id_rejected():
    bad = dict(VALID_PAYLOAD)
    bad["record"] = dict(VALID_PAYLOAD["record"])
    del bad["record"]["user_id"]

    with pytest.raises(ValidationError):
        SupabaseWebhookPayload(**bad)


def test_metadata_defaults_to_empty_dict():
    bad = dict(VALID_PAYLOAD)
    bad["record"] = dict(VALID_PAYLOAD["record"])
    del bad["record"]["metadata"]

    payload = SupabaseWebhookPayload(**bad)
    assert payload.record.metadata == {}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest tests/test_schemas.py -v`
Expected: FAIL with `ModuleNotFoundError`

- [ ] **Step 3: Implement `schemas.py`**

```python
# app/gateway/schemas.py
from typing import Any, Literal
from pydantic import BaseModel


class EventRecord(BaseModel):
    id: str
    user_id: str
    event_type: str
    status: str
    source: str
    started_at: str
    ended_at: str | None = None
    metadata: dict[str, Any] = {}


class SupabaseWebhookPayload(BaseModel):
    type: Literal["INSERT", "UPDATE", "DELETE"]
    table: str
    record: EventRecord
    old_record: EventRecord | None = None
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest tests/test_schemas.py -v`
Expected: PASS (3 tests)

- [ ] **Step 5: Commit**

```bash
git add app/gateway/schemas.py tests/test_schemas.py
git commit -m "feat: add webhook payload schema"
```

---

### Task 5: Gateway App and Webhook Route

**Files:**
- Create: `app/gateway/queue_provider.py`
- Create: `app/gateway/webhooks.py`
- Create: `app/gateway/main.py`
- Test: `tests/test_webhooks.py`

**Interfaces:**
- Consumes: `Settings`/`get_settings` (Task 1), `JobQueue` (Task 2),
  `verify_webhook_signature` (Task 3), `SupabaseWebhookPayload` (Task 4)
- Produces: `get_job_queue() -> JobQueue`, FastAPI `router` (webhooks.py),
  FastAPI `app` (main.py) exposing `POST /webhooks/events` and `GET /health`

This is the entire gateway (P4 — thin ingest, never coupled to compute time):
verify, read `user_id`, enqueue, return `202` immediately.

- [ ] **Step 1: Implement `queue_provider.py`** (no test — thin wiring, exercised via Task 5 Step 3's tests)

```python
# app/gateway/queue_provider.py
from functools import lru_cache
import redis
from app.common.config import get_settings
from app.common.queue import JobQueue


@lru_cache
def get_job_queue() -> JobQueue:
    settings = get_settings()
    redis_client = redis.Redis.from_url(settings.redis_url)
    return JobQueue(redis_client, settings.queue_name)
```

- [ ] **Step 2: Write the failing tests for the webhook route**

```python
# tests/test_webhooks.py
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
```

- [ ] **Step 3: Run test to verify it fails**

Run: `pytest tests/test_webhooks.py -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'app.gateway.webhooks'`

- [ ] **Step 4: Implement `webhooks.py`**

```python
# app/gateway/webhooks.py
from fastapi import APIRouter, Depends, Header, HTTPException
from app.common.config import get_settings
from app.common.logging_config import get_logger, log_context
from app.common.queue import JobQueue
from app.gateway.queue_provider import get_job_queue
from app.gateway.schemas import SupabaseWebhookPayload
from app.gateway.security import verify_webhook_signature

router = APIRouter()
logger = get_logger(__name__)


@router.post("/webhooks/events", status_code=202)
def handle_event_webhook(
    payload: SupabaseWebhookPayload,
    x_webhook_secret: str | None = Header(default=None),
    queue: JobQueue = Depends(get_job_queue),
):
    settings = get_settings()
    if not verify_webhook_signature(x_webhook_secret, settings.webhook_secret):
        logger.warning("rejected webhook: bad or missing secret")
        raise HTTPException(status_code=401, detail="invalid webhook secret")

    record = payload.record
    job = {
        "event_id": record.id,
        "user_id": record.user_id,
        "event_type": record.event_type,
        "status": record.status,
    }
    queue.enqueue(job)
    logger.info(f"event enqueued {log_context(user_id=record.user_id, event_id=record.id)}")
    return {"queued": True}
```

- [ ] **Step 5: Implement `main.py`**

```python
# app/gateway/main.py
from fastapi import FastAPI
from app.common.logging_config import configure_logging
from app.gateway.webhooks import router as webhooks_router

configure_logging()
app = FastAPI(title="healthagent-gateway")
app.include_router(webhooks_router)


@app.get("/health")
def health():
    return {"status": "ok"}
```

- [ ] **Step 6: Run test to verify it passes**

Run: `pytest tests/test_webhooks.py -v`
Expected: PASS (5 tests)

- [ ] **Step 7: Commit**

```bash
git add app/gateway/queue_provider.py app/gateway/webhooks.py app/gateway/main.py tests/test_webhooks.py
git commit -m "feat: add gateway webhook endpoint"
```

---

### Task 6: Supabase Client Factory

**Files:**
- Create: `app/common/supabase_client.py`
- Test: `tests/test_supabase_client.py`

**Interfaces:**
- Consumes: `get_settings` (Task 1)
- Produces: `get_supabase_client() -> Client`

- [ ] **Step 1: Write the failing test**

```python
# tests/test_supabase_client.py
import os
from unittest.mock import patch
from app.common import supabase_client

os.environ.setdefault("SUPABASE_URL", "https://x.supabase.co")
os.environ.setdefault("SUPABASE_SERVICE_KEY", "service-key")
os.environ.setdefault("WEBHOOK_SECRET", "shh")
os.environ.setdefault("REDIS_URL", "redis://localhost:6379/0")
os.environ.setdefault("QUEUE_NAME", "events:realtime")


def test_get_supabase_client_uses_settings():
    supabase_client.get_supabase_client.cache_clear()
    with patch.object(supabase_client, "create_client") as mock_create:
        supabase_client.get_supabase_client()
        mock_create.assert_called_once_with("https://x.supabase.co", "service-key")
    supabase_client.get_supabase_client.cache_clear()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest tests/test_supabase_client.py -v`
Expected: FAIL with `ModuleNotFoundError`

- [ ] **Step 3: Implement `supabase_client.py`**

```python
# app/common/supabase_client.py
from functools import lru_cache
from supabase import Client, create_client
from app.common.config import get_settings


@lru_cache
def get_supabase_client() -> Client:
    settings = get_settings()
    return create_client(settings.supabase_url, settings.supabase_service_key)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest tests/test_supabase_client.py -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add app/common/supabase_client.py tests/test_supabase_client.py
git commit -m "feat: add cached Supabase client factory"
```

---

### Task 7: Worker Job Handler

**Files:**
- Create: `app/worker/handlers.py`
- Create: `app/worker/__init__.py` (empty)
- Test: `tests/test_worker.py` (handler tests — loop tests added in Task 8)

**Interfaces:**
- Consumes: nothing from earlier tasks directly (takes a Supabase client as a
  parameter — never imports `get_supabase_client` itself, so it stays testable
  with a fake)
- Produces: `process_event_job(job: dict, supabase: Any) -> None`

This is the **entire "intelligence" of the trivial worker**: write one row
proving the job arrived. No LangGraph, no memory — that is Build Order step 5.

- [ ] **Step 1: Write the failing tests**

```python
# tests/test_worker.py
from app.worker.handlers import process_event_job


class FakeTable:
    def __init__(self, store: list):
        self._store = store
        self._pending_row = None

    def insert(self, row: dict):
        self._pending_row = row
        return self

    def execute(self):
        self._store.append(self._pending_row)


class FakeSupabase:
    def __init__(self):
        self.rows: list = []

    def table(self, name: str):
        assert name == "debug_log"
        return FakeTable(self.rows)


class FailingSupabase:
    def table(self, name: str):
        raise RuntimeError("connection refused")


def test_process_event_job_writes_debug_row():
    supabase = FakeSupabase()
    job = {"event_id": "e1", "user_id": "u1", "event_type": "alcohol"}

    process_event_job(job, supabase)

    assert supabase.rows == [
        {
            "event_id": "e1",
            "user_id": "u1",
            "event_type": "alcohol",
            "note": "worker received this event",
        }
    ]


def test_process_event_job_does_not_raise_on_supabase_failure():
    supabase = FailingSupabase()
    job = {"event_id": "e1", "user_id": "u1", "event_type": "alcohol"}

    process_event_job(job, supabase)  # must not raise
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest tests/test_worker.py -v`
Expected: FAIL with `ModuleNotFoundError`

- [ ] **Step 3: Implement `handlers.py`**

```python
# app/worker/handlers.py
from typing import Any
from app.common.logging_config import get_logger, log_context

logger = get_logger(__name__)


def process_event_job(job: dict, supabase: Any) -> None:
    user_id = job.get("user_id")
    event_id = job.get("event_id")
    try:
        supabase.table("debug_log").insert(
            {
                "event_id": event_id,
                "user_id": user_id,
                "event_type": job.get("event_type"),
                "note": "worker received this event",
            }
        ).execute()
        logger.info(f"job processed {log_context(user_id=user_id, event_id=event_id)}")
    except Exception:
        logger.exception(f"job failed {log_context(user_id=user_id, event_id=event_id)}")
```

A failed write is logged, not raised — one bad job must never crash the
worker loop. There is deliberately no retry/dead-letter logic here; that is
listed as a Non-Goal for this milestone (see Global Constraints) and belongs
to the real agent worker in step 5.

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest tests/test_worker.py -v`
Expected: PASS (2 tests)

- [ ] **Step 5: Commit**

```bash
git add app/worker/__init__.py app/worker/handlers.py tests/test_worker.py
git commit -m "feat: add trivial worker job handler"
```

---

### Task 8: Worker Loop

**Files:**
- Create: `app/worker/main.py`
- Modify: `tests/test_worker.py` (append loop tests)

**Interfaces:**
- Consumes: `JobQueue` (Task 2), `process_event_job` (Task 7),
  `get_supabase_client` (Task 6), `get_settings` (Task 1)
- Produces: `process_one(queue, supabase, timeout: int = 5) -> bool`,
  `run() -> None`

`process_one` is extracted specifically so the loop body is testable without
an actual infinite loop or a real Redis instance.

- [ ] **Step 1: Write the failing tests (append to `tests/test_worker.py`)**

```python
# append to tests/test_worker.py
from app.worker.main import process_one


class StubQueue:
    def __init__(self, jobs: list):
        self._jobs = jobs

    def dequeue(self, timeout: int = 5):
        if not self._jobs:
            return None
        return self._jobs.pop(0)


def test_process_one_returns_true_and_processes_job_when_present():
    supabase = FakeSupabase()
    queue = StubQueue([{"event_id": "e1", "user_id": "u1", "event_type": "alcohol"}])

    handled = process_one(queue, supabase, timeout=1)

    assert handled is True
    assert supabase.rows[0]["event_id"] == "e1"


def test_process_one_returns_false_when_queue_empty():
    supabase = FakeSupabase()
    queue = StubQueue([])

    handled = process_one(queue, supabase, timeout=1)

    assert handled is False
    assert supabase.rows == []
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest tests/test_worker.py -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'app.worker.main'`

- [ ] **Step 3: Implement `main.py`**

```python
# app/worker/main.py
import redis
from typing import Any
from app.common.config import get_settings
from app.common.logging_config import configure_logging, get_logger
from app.common.queue import JobQueue
from app.common.supabase_client import get_supabase_client
from app.worker.handlers import process_event_job

logger = get_logger(__name__)


def process_one(queue: Any, supabase: Any, timeout: int = 5) -> bool:
    job = queue.dequeue(timeout=timeout)
    if job is None:
        return False
    process_event_job(job, supabase)
    return True


def run() -> None:
    configure_logging()
    settings = get_settings()
    redis_client = redis.Redis.from_url(settings.redis_url)
    queue = JobQueue(redis_client, settings.queue_name)
    supabase = get_supabase_client()
    logger.info("worker started")
    while True:
        process_one(queue, supabase)


if __name__ == "__main__":
    run()
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest tests/test_worker.py -v`
Expected: PASS (4 tests total)

- [ ] **Step 5: Commit**

```bash
git add app/worker/main.py tests/test_worker.py
git commit -m "feat: add worker dequeue loop"
```

---

### Task 9: Requirements and Test Config

**Files:**
- Create: `requirements.txt`
- Create: `pytest.ini`

**Interfaces:** none (project configuration)

- [ ] **Step 1: Create `requirements.txt`**

```
fastapi==0.115.0
uvicorn==0.30.6
pydantic==2.9.2
redis==5.0.8
supabase==2.7.4
httpx==0.27.2
python-dotenv==1.0.1
pytest==8.3.3
fakeredis==2.25.1
```

- [ ] **Step 2: Create `pytest.ini`**

```ini
[pytest]
pythonpath = .
```

This lets `pytest` resolve `app.*` imports from the project root without an
installed package.

- [ ] **Step 3: Install and run the full suite**

Run:
```bash
pip install -r requirements.txt
pytest -v
```
Expected: all tests from Tasks 1–8 PASS.

- [ ] **Step 4: Commit**

```bash
git add requirements.txt pytest.ini
git commit -m "chore: add dependencies and pytest config"
```

---

### Task 10: Supabase Schema

**Files:**
- Create: `db/schema.sql`

**Interfaces:** none (SQL, applied manually via Supabase SQL editor or CLI)

- [ ] **Step 1: Write `schema.sql`**

```sql
-- events: the single trigger table for the whole platform (Platform HLD P1).
-- A button press, a voice command, and (later) the detector all write this
-- same shape. Downstream code never knows which one fired.
create table if not exists events (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  event_type text not null,
  status text not null
    check (status in ('started', 'candidate', 'confirmed', 'rejected', 'ended', 'expired')),
  source text not null
    check (source in ('manual', 'voice', 'auto')),
  confidence numeric,
  started_at timestamptz not null default now(),
  ended_at timestamptz,
  expected_max_duration interval,
  metadata jsonb not null default '{}'::jsonb
);

alter table events enable row level security;

create policy "users manage their own events"
  on events
  for all
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

-- debug_log: TEMPORARY, this-milestone-only. Proves the webhook -> queue ->
-- worker -> write-back loop closes before the real `predictions` table
-- exists (Build Order step 5). Delete this table once step 5 lands.
create table if not exists debug_log (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null,
  user_id uuid not null,
  event_type text,
  note text,
  created_at timestamptz not null default now()
);

alter table debug_log enable row level security;

create policy "users read their own debug log"
  on debug_log
  for select
  using (auth.uid() = user_id);
```

- [ ] **Step 2: Apply the schema**

In the Supabase dashboard: SQL Editor → paste the contents of `db/schema.sql`
→ Run. Verify in Table Editor that `events` and `debug_log` both appear with
RLS enabled (a shield icon next to the table name).

- [ ] **Step 3: Configure the Database Webhook**

In the Supabase dashboard: Database → Webhooks → Create a new webhook.

- Table: `events`
- Events: `Insert`, `Update`
- Type: `HTTP Request`
- URL: (filled in during Task 12, once the ngrok tunnel is running)
- HTTP Headers: `x-webhook-secret: <same value as WEBHOOK_SECRET in .env>`

Leave the URL field as a placeholder for now — Task 12 fills it in once the
gateway is reachable from the internet.

- [ ] **Step 4: Commit**

```bash
git add db/schema.sql
git commit -m "feat: add events and debug_log schema"
```

---

### Task 11: Docker Compose and Dockerfiles

**Files:**
- Create: `docker/Dockerfile.gateway`
- Create: `docker/Dockerfile.worker`
- Create: `docker-compose.yml`
- Create: `.env.example`

**Interfaces:** none (deployment configuration)

- [ ] **Step 1: Create `docker/Dockerfile.gateway`**

```dockerfile
FROM python:3.12-slim
WORKDIR /code
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app ./app
CMD ["uvicorn", "app.gateway.main:app", "--host", "0.0.0.0", "--port", "8000"]
```

- [ ] **Step 2: Create `docker/Dockerfile.worker`**

```dockerfile
FROM python:3.12-slim
WORKDIR /code
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app ./app
CMD ["python", "-m", "app.worker.main"]
```

- [ ] **Step 3: Create `docker-compose.yml`**

```yaml
version: "3.9"
services:
  redis:
    image: redis:7-alpine
    ports:
      - "6379:6379"

  gateway:
    build:
      context: .
      dockerfile: docker/Dockerfile.gateway
    ports:
      - "8090:8000"
    env_file: .env
    depends_on:
      - redis

  worker:
    build:
      context: .
      dockerfile: docker/Dockerfile.worker
    env_file: .env
    depends_on:
      - redis
```

- [ ] **Step 4: Create `.env.example`**

```
SUPABASE_URL=https://xxxx.supabase.co
SUPABASE_SERVICE_KEY=your-service-role-key
WEBHOOK_SECRET=choose-a-long-random-string
REDIS_URL=redis://redis:6379/0
QUEUE_NAME=events:realtime
```

`REDIS_URL` uses the Compose service name `redis` as the host — that only
resolves inside the Compose network. Copy this file to `.env` and fill in
real values; `.env` itself must never be committed.

- [ ] **Step 5: Verify the stack builds and starts**

Run:
```bash
cp .env.example .env   # then fill in real Supabase values
docker compose build
docker compose up -d
curl http://localhost:8090/health
```
Expected: `{"status":"ok"}`

Run: `docker compose logs worker`
Expected: log line containing `worker started`

- [ ] **Step 6: Commit**

```bash
git add docker/ docker-compose.yml .env.example
git commit -m "feat: add Docker Compose setup for gateway, worker, redis"
```

Note: `.env` is real secrets and must be in `.gitignore` — add it there if a
`.gitignore` doesn't already exclude it before running `git add`.

---

### Task 12: Local Test Harness

**Files:**
- Create: `test_ui/index.html`

**Interfaces:** none (standalone HTML page, no build step)

This page is the throwaway proof that the whole loop closes: it inserts into
`events` directly (standing in for the mobile app) and subscribes to
`debug_log` via Supabase Realtime (standing in for the mobile app receiving
results). It is deliberately unstyled — it gets deleted once the real mobile
app exists.

- [ ] **Step 1: Create `test_ui/index.html`**

```html
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8" />
  <title>healthagent local test harness</title>
  <script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2"></script>
</head>
<body>
  <!--
    LOCAL DEV ONLY. This page uses a Supabase key directly in client-side
    JS and a hardcoded test user_id with no login flow. Never ship this
    pattern to a real client — it exists only to prove the gateway/queue/
    worker loop closes end-to-end before the real mobile app is wired up.
  -->
  <h1>healthagent test harness</h1>

  <label>Supabase URL: <input id="url" size="40" /></label><br />
  <label>Supabase Key (anon or service): <input id="key" size="40" /></label><br />
  <label>Test user_id (any UUID): <input id="uid" value="00000000-0000-0000-0000-000000000001" size="40" /></label><br />
  <button id="connect">Connect</button>

  <hr />

  <select id="event_type">
    <option value="alcohol">alcohol</option>
    <option value="eating">eating</option>
    <option value="exercise">exercise</option>
    <option value="sauna">sauna</option>
  </select>
  <button id="start" disabled>Start</button>
  <button id="stop" disabled>Stop</button>

  <h3>Log</h3>
  <pre id="log"></pre>

  <script>
    let supabase;
    let currentEventId = null;

    function log(line) {
      document.getElementById("log").textContent += line + "\n";
    }

    document.getElementById("connect").onclick = () => {
      const url = document.getElementById("url").value;
      const key = document.getElementById("key").value;
      supabase = window.supabase.createClient(url, key);

      const userId = document.getElementById("uid").value;
      supabase
        .channel("debug_log_changes")
        .on(
          "postgres_changes",
          { event: "INSERT", schema: "public", table: "debug_log", filter: `user_id=eq.${userId}` },
          (payload) => log("worker wrote back: " + JSON.stringify(payload.new))
        )
        .subscribe();

      log("connected, subscribed to debug_log for user " + userId);
      document.getElementById("start").disabled = false;
      document.getElementById("stop").disabled = false;
    };

    document.getElementById("start").onclick = async () => {
      const userId = document.getElementById("uid").value;
      const eventType = document.getElementById("event_type").value;

      const { data, error } = await supabase
        .from("events")
        .insert({ user_id: userId, event_type: eventType, status: "started", source: "manual" })
        .select()
        .single();

      if (error) {
        log("insert failed: " + error.message);
        return;
      }
      currentEventId = data.id;
      log("started event " + currentEventId + " (" + eventType + ")");
    };

    document.getElementById("stop").onclick = async () => {
      if (!currentEventId) {
        log("no active event to stop");
        return;
      }
      const { error } = await supabase
        .from("events")
        .update({ status: "ended", ended_at: new Date().toISOString() })
        .eq("id", currentEventId);

      if (error) {
        log("update failed: " + error.message);
        return;
      }
      log("stopped event " + currentEventId);
      currentEventId = null;
    };
  </script>
</body>
</html>
```

- [ ] **Step 2: Open the harness**

Open `test_ui/index.html` directly in a browser (no server needed — it's a
static file). Enter the Supabase project URL and a key, click Connect.

- [ ] **Step 3: Commit**

```bash
git add test_ui/index.html
git commit -m "feat: add local test harness for event trigger loop"
```

---

### Task 13: End-to-End Verification

**Files:** none — this task wires together everything built in Tasks 1–12
and produces no new code.

- [ ] **Step 1: Start the local stack**

```bash
docker compose up -d
```

- [ ] **Step 2: Start an ngrok tunnel to the gateway**

```bash
ngrok http 8090
```

Copy the resulting `https://....ngrok-free.app` URL.

- [ ] **Step 3: Point the Supabase webhook at the tunnel**

In the Supabase dashboard, edit the webhook created in Task 10 Step 3: set
its URL to `https://<ngrok-url>/webhooks/events`.

- [ ] **Step 4: Run the full loop**

1. Open `test_ui/index.html`, fill in the Supabase URL + key, click Connect.
2. Click **Start** with `event_type = alcohol`.
3. Watch `docker compose logs -f gateway worker` — expect to see:
   - Gateway: `event enqueued user_id=... event_id=...`
   - Worker: `job processed user_id=... event_id=...`
4. Watch the harness's Log panel — expect a line:
   `worker wrote back: {...note: "worker received this event"...}`
5. Click **Stop** — expect a second full round-trip through the same log
   lines (the webhook also fires on `UPDATE`).

- [ ] **Step 5: Confirm rejection path**

Temporarily change the webhook's header value in the Supabase dashboard to a
wrong secret, click Start again in the harness, and confirm:
- Gateway log shows `rejected webhook: bad or missing secret`
- No new row appears in the harness's Log panel

Revert the header back to the correct secret afterward.

This task has no commit — it is a verification checklist confirming Tasks
1–12 integrate correctly. If any step fails, the bug is isolated to exactly
one of: schema/RLS (Task 10), webhook config (Task 10/12), gateway (Task 5),
queue (Task 2), or worker (Tasks 7–8) — each of which has its own passing
unit tests to rule in or out independently.

---

## Plan Self-Review Notes

- **Spec coverage:** Platform HLD §3.1 (event flow + webhook payload shape) →
  Tasks 4–5. §4.2 (`events` table) → Task 10. §6 (topology: gateway, worker,
  redis) → Tasks 1–2, 5, 7–8, 11. NFR-3.1 (verify before trusting any field) →
  Task 3, enforced in Task 5 Step 4. P3 (stateless workers) → Task 8's
  `process_one` takes all state as parameters, holds none between calls.
- **Deferred by design, not forgotten:** LangGraph/agent logic (step 5),
  detector (step 9), voice (step 8), retry/dead-letter queues, analytics
  layer, memory. These are explicitly out of scope per Global Constraints and
  belong to later Build Order steps.
