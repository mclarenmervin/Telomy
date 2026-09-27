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
