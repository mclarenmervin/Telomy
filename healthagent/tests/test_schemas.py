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
