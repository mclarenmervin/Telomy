"""Application service for safety-gated therapy session lifecycle."""

from __future__ import annotations

import uuid
from datetime import UTC, datetime
from typing import Any, Mapping

from app.analytics.therapy_safety import screen_therapy


class SessionForbidden(RuntimeError):
    pass


class SessionConflict(RuntimeError):
    pass


class SessionSafetyRefused(RuntimeError):
    def __init__(self, reason_codes: list[str]):
        self.reason_codes = reason_codes
        super().__init__("therapy refused for safety: " + ", ".join(reason_codes))


def _rows(query: Any) -> list[dict]:
    return query.execute().data or []


def _one(supabase: Any, table: str, row_id: str) -> dict | None:
    rows = _rows(supabase.table(table).select("*").eq("id", row_id).limit(1))
    return rows[0] if rows else None


def _session_for_actor(supabase: Any, actor_id: str, session_id: str) -> dict:
    session = _one(supabase, "therapy_service_sessions", session_id)
    if not session:
        raise SessionConflict("therapy session not found")
    if str(session.get("patient_id")) != actor_id:
        raise SessionForbidden("a patient may only control their own therapy session")
    return session


def _screen(
    supabase: Any,
    *, patient_id: str, centre_id: str, catalogue_id: str,
    plan_item_id: str, session_id: str | None, point: str,
    actor_id: str, facts: Mapping,
) -> tuple[Any, str]:
    catalogues = _rows(
        supabase.table("therapy_catalogue").select("id,slug,publication_status")
        .eq("id", catalogue_id).eq("publication_status", "published").limit(1)
    )
    if not catalogues:
        raise SessionConflict("therapy catalogue entry is unavailable")
    decision = screen_therapy(str(catalogues[0]["slug"]), facts)
    supabase.table("therapy_safety_checks").insert({
        "id": str(uuid.uuid4()), "patient_id": patient_id, "centre_id": centre_id,
        "catalogue_id": catalogue_id, "plan_item_id": plan_item_id,
        "session_id": session_id, "evaluation_point": point,
        "rule_version": decision.rule_version, "fact_snapshot": dict(facts),
        "eligible": decision.eligible, "reason_codes": list(decision.reason_codes),
        "explanations": list(decision.explanations), "evaluated_by": actor_id,
    }).execute()
    return decision, str(catalogues[0]["slug"])


def book_session(
    supabase: Any,
    actor_id: str,
    plan_item_id: str,
    offering_id: str,
    idempotency_key: str,
    safety_facts: Mapping,
    scheduled_start: str | None,
) -> dict:
    key = idempotency_key.strip()
    if not key:
        raise SessionConflict("idempotency key is required")
    existing = _rows(
        supabase.table("therapy_service_sessions").select("*")
        .eq("patient_id", actor_id).eq("idempotency_key", key).limit(1)
    )
    if existing:
        return existing[0]
    item = _one(supabase, "therapy_plan_items", plan_item_id)
    offering = _one(supabase, "centre_therapy_offerings", offering_id)
    if not item or not offering or offering.get("status") != "active":
        raise SessionConflict("plan item or centre offering is unavailable")
    plan = _one(supabase, "therapy_plans", str(item["plan_id"]))
    if not plan or plan.get("status") != "signed":
        raise SessionConflict("only a signed therapy plan can be booked")
    if str(plan.get("patient_id")) != actor_id:
        raise SessionForbidden("a patient may only book their own therapy plan")
    if str(offering.get("centre_id")) != str(plan.get("centre_id")) or str(offering.get("catalogue_id")) != str(item.get("catalogue_id")):
        raise SessionConflict("offering does not match the signed plan item")
    decision, _ = _screen(
        supabase, patient_id=actor_id, centre_id=str(plan["centre_id"]),
        catalogue_id=str(item["catalogue_id"]), plan_item_id=plan_item_id,
        session_id=None, point="booking", actor_id=actor_id, facts=safety_facts,
    )
    if not decision.eligible:
        raise SessionSafetyRefused(list(decision.reason_codes))
    row = {
        "id": str(uuid.uuid4()), "patient_id": actor_id, "centre_id": plan["centre_id"],
        "offering_id": offering_id, "plan_item_id": plan_item_id,
        "centre_booking_id": None, "status": "scheduled",
        "prescribed_dose": dict(item.get("prescribed_dose") or {}),
        "delivered_dose": None, "scheduled_start": scheduled_start,
        "started_at": None, "ended_at": None, "refusal_reason_codes": [],
        "cancellation_reason": None, "event_id": None,
        "idempotency_key": key, "created_by": actor_id,
    }
    supabase.table("therapy_service_sessions").insert(row).execute()
    return row


def start_session(supabase: Any, actor_id: str, session_id: str, safety_facts: Mapping) -> dict:
    session = _session_for_actor(supabase, actor_id, session_id)
    if session.get("status") == "started":
        return session
    if session.get("status") != "scheduled":
        raise SessionConflict("therapy session is not scheduled")
    item = _one(supabase, "therapy_plan_items", str(session["plan_item_id"]))
    decision, _ = _screen(
        supabase, patient_id=actor_id, centre_id=str(session["centre_id"]),
        catalogue_id=str(item["catalogue_id"]), plan_item_id=str(item["id"]),
        session_id=session_id, point="start", actor_id=actor_id, facts=safety_facts,
    )
    if not decision.eligible:
        refused = {"status": "refused", "refusal_reason_codes": list(decision.reason_codes)}
        supabase.table("therapy_service_sessions").update(refused).eq("id", session_id).eq("status", "scheduled").execute()
        raise SessionSafetyRefused(list(decision.reason_codes))
    started = {"status": "started", "started_at": datetime.now(UTC).isoformat()}
    rows = _rows(supabase.table("therapy_service_sessions").update(started).eq("id", session_id).eq("status", "scheduled"))
    if not rows:
        raise SessionConflict("therapy session changed")
    return {**session, **started}


def finish_session(supabase: Any, actor_id: str, session_id: str, delivered_dose: Mapping) -> dict:
    session = _session_for_actor(supabase, actor_id, session_id)
    if session.get("status") == "completed":
        return {**session, "reconciliation_state": "emitted" if session.get("event_id") else "pending"}
    if session.get("status") != "started":
        raise SessionConflict("therapy session is not in progress")
    item = _one(supabase, "therapy_plan_items", str(session["plan_item_id"]))
    catalogue = _one(supabase, "therapy_catalogue", str(item["catalogue_id"]))
    event_id = str(uuid.uuid5(uuid.NAMESPACE_URL, f"telomy:therapy-session:{session_id}"))
    ended_at = datetime.now(UTC).isoformat()
    events = _rows(supabase.table("events").select("id").eq("id", event_id).limit(1))
    if not events:
        supabase.table("events").insert({
            "id": event_id, "user_id": actor_id, "event_type": catalogue["slug"],
            "status": "ended", "source": "manual", "confidence": 1,
            "started_at": session["started_at"], "ended_at": ended_at,
            "metadata": {
                "therapy_session_id": session_id,
                "prescribed_dose": session.get("prescribed_dose") or {},
                "delivered_dose": dict(delivered_dose),
            },
        }).execute()
    completed = {
        "status": "completed", "ended_at": ended_at,
        "delivered_dose": dict(delivered_dose), "event_id": event_id,
    }
    rows = _rows(supabase.table("therapy_service_sessions").update(completed).eq("id", session_id).eq("status", "started"))
    if not rows:
        raise SessionConflict("therapy session changed while completing")
    return {**session, **completed, "reconciliation_state": "emitted"}


def add_checkin(
    supabase: Any, actor_id: str, session_id: str, question_version: str,
    ordinal: int, question_code: str, answer: Any,
) -> dict:
    _session_for_actor(supabase, actor_id, session_id)
    if ordinal not in (1, 2):
        raise SessionConflict("a therapy session accepts at most two check-ins")
    existing = _rows(supabase.table("therapy_checkins").select("id,question_ordinal").eq("session_id", session_id))
    if any(int(row["question_ordinal"]) == ordinal for row in existing):
        raise SessionConflict("this check-in question was already answered")
    if len(existing) >= 2:
        raise SessionConflict("a therapy session accepts at most two check-ins")
    row = {
        "id": str(uuid.uuid4()), "session_id": session_id, "patient_id": actor_id,
        "question_version": question_version, "question_ordinal": ordinal,
        "question_code": question_code, "answer": answer,
    }
    supabase.table("therapy_checkins").insert(row).execute()
    return row
