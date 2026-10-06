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


class ActivitySessionRecord(BaseModel):
    """Only the identifiers are read. `samples` may be megabytes and is deliberately
    not modelled — the worker re-reads the authoritative row instead."""

    id: str
    user_id: str
    activity_type: str


class ActivityWebhookPayload(BaseModel):
    type: Literal["INSERT", "UPDATE", "DELETE"]
    table: str
    record: ActivitySessionRecord


class LabUploadRecord(BaseModel):
    """Only what decides whether to enqueue. The paths and digests are
    deliberately not modelled: the worker re-reads the authoritative row, so a
    replayed webhook cannot pin extraction to a stale location."""

    id: str
    user_id: str
    status: str


class LabUploadWebhookPayload(BaseModel):
    type: Literal["INSERT", "UPDATE", "DELETE"]
    table: str
    record: LabUploadRecord
