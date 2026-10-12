"""Fail-closed audit wrapper for every cross-user clinical read."""

from __future__ import annotations

import uuid
from collections.abc import Callable
from typing import Any, TypeVar

from fastapi import HTTPException

T = TypeVar("T")


def audited_read(
    supabase: Any,
    *,
    actor_id: str,
    actor_role: str,
    patient_id: str,
    centre_id: str | None,
    resource_type: str,
    resource_id: str,
    read: Callable[[], T],
    reason: str = "authorized clinical read",
    request_id: str | None = None,
) -> T:
    """Record the authorized read before loading or returning sensitive data."""
    try:
        supabase.rpc(
            "record_access_event",
            {
                "p_actor": actor_id,
                "p_action": "read",
                "p_patient": patient_id,
                "p_centre": centre_id,
                "p_resource_kind": resource_type,
                "p_resource_id": resource_id,
                "p_reason": f"{reason} ({actor_role})",
                "p_request_id": request_id or str(uuid.uuid4()),
                "p_outcome": "allowed",
            },
        ).execute()
    except Exception:
        # Do not call the loader after an audit failure: sensitive data never
        # enters the response object or downstream serialization path.
        raise HTTPException(status_code=503, detail="clinical data is temporarily unavailable") from None
    return read()
