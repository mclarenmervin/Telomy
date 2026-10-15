"""Author, safety-screen and sign versioned therapy plans."""

from __future__ import annotations

import hashlib
import json
import uuid
from datetime import UTC, datetime, timedelta
from typing import Any, Mapping

from app.analytics.therapy_safety import RULE_VERSION, screen_therapy


class PlanForbidden(RuntimeError):
    pass


class PlanConflict(RuntimeError):
    pass


class PlanInvalid(ValueError):
    pass


def _rows(query: Any) -> list[dict]:
    return query.execute().data or []


def _one(supabase: Any, table: str, row_id: str) -> dict | None:
    rows = _rows(supabase.table(table).select("*").eq("id", row_id).limit(1))
    return rows[0] if rows else None


def _role(supabase: Any, actor_id: str) -> str | None:
    rows = _rows(supabase.table("profiles").select("app_role").eq("id", actor_id).limit(1))
    return rows[0].get("app_role") if rows else None


def _active_member(supabase: Any, centre_id: str, user_id: str, kind: str) -> bool:
    return bool(_rows(
        supabase.table("centre_memberships").select("id")
        .eq("centre_id", centre_id).eq("user_id", user_id)
        .eq("member_kind", kind).eq("status", "active")
        .is_("left_at", "null").limit(1)
    ))


def _doctor_may_treat(supabase: Any, doctor_id: str, centre_id: str, patient_id: str) -> bool:
    verified = _rows(
        supabase.table("clinician_verifications").select("status,created_at")
        .eq("doctor_id", doctor_id).order("created_at", desc=True).limit(1)
    )
    assigned = _rows(
        supabase.table("patient_doctor_assignments").select("id")
        .eq("centre_id", centre_id).eq("doctor_id", doctor_id)
        .eq("patient_id", patient_id).is_("ended_at", "null").limit(1)
    )
    return (
        _role(supabase, doctor_id) == "doctor"
        and _active_member(supabase, centre_id, doctor_id, "doctor")
        and bool(verified) and verified[0].get("status") == "verified"
        and bool(assigned)
    )


def _authorize_author(supabase: Any, actor_id: str, centre_id: str, patient_id: str) -> str:
    role = _role(supabase, actor_id)
    if actor_id == patient_id and role == "member" and _active_member(
        supabase, centre_id, patient_id, "patient"
    ):
        return "proposed"
    if _doctor_may_treat(supabase, actor_id, centre_id, patient_id):
        return "in_review"
    raise PlanForbidden("only the patient or their assigned verified doctor may author a plan")


def _catalogue(supabase: Any, catalogue_ids: list[str]) -> dict[str, dict]:
    rows = _rows(
        supabase.table("therapy_catalogue").select("id,slug,version,publication_status")
        .in_("id", catalogue_ids).eq("publication_status", "published")
    ) if catalogue_ids else []
    return {str(row["id"]): row for row in rows}


def _screened_item(raw: Mapping, catalogue: Mapping, position: int, facts: Mapping) -> tuple[dict, dict]:
    slug = str(catalogue["slug"])
    supplied = raw.get("modality_id")
    if supplied is not None and str(supplied) != slug:
        raise PlanInvalid("modality_id does not match the published catalogue item")
    decision = screen_therapy(slug, facts)
    excluded = not decision.eligible
    row = {
        "id": str(uuid.uuid4()),
        "catalogue_id": str(catalogue["id"]),
        "position": position,
        "frequency": dict(raw.get("frequency") or {}),
        "prescribed_dose": dict(raw.get("prescribed_dose") or {}),
        "disposition": "excluded_safety" if excluded else "proposed",
        "safety_reason_code": decision.reason_codes[0] if excluded else None,
        "safety_explanation": " ".join(decision.explanations) if excluded else None,
    }
    check = {
        "id": str(uuid.uuid4()),
        "catalogue_id": str(catalogue["id"]),
        "plan_item_id": row["id"],
        "rule_version": decision.rule_version,
        "fact_snapshot": dict(facts),
        "eligible": decision.eligible,
        "reason_codes": list(decision.reason_codes),
        "explanations": list(decision.explanations),
    }
    return row, check


def _snapshot(plan: Mapping, items: list[Mapping]) -> str:
    value = {
        "centre_id": str(plan["centre_id"]),
        "items": [
            {
                "catalogue_id": str(item["catalogue_id"]),
                "disposition": item["disposition"],
                "frequency": item.get("frequency") or {},
                "position": item["position"],
                "prescribed_dose": item.get("prescribed_dose") or {},
                "safety_explanation": item.get("safety_explanation"),
                "safety_reason_code": item.get("safety_reason_code"),
            }
            for item in sorted(items, key=lambda item: item["position"])
        ],
        "patient_id": str(plan["patient_id"]),
        "plan_id": str(plan["id"]),
        "version": plan["version"],
    }
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def _decorate(item: Mapping, slug: str) -> dict:
    return {
        **dict(item),
        "modality_id": slug,
        "section_label": "Left out for safety" if item["disposition"] == "excluded_safety" else "In this plan",
    }


def create_plan(
    supabase: Any,
    actor_id: str,
    centre_id: str,
    patient_id: str,
    requested_items: list[Mapping],
    safety_facts: Mapping,
) -> dict:
    if not requested_items:
        raise PlanInvalid("a therapy plan needs at least one item")
    if len({str(item.get("catalogue_id")) for item in requested_items}) != len(requested_items):
        raise PlanInvalid("a catalogue item may appear only once in a plan")
    status = _authorize_author(supabase, actor_id, centre_id, patient_id)
    catalogue = _catalogue(supabase, [str(item.get("catalogue_id")) for item in requested_items])
    if len(catalogue) != len(requested_items):
        raise PlanInvalid("every plan item must reference a published catalogue entry")
    prior = _rows(
        supabase.table("therapy_plans").select("version").eq("centre_id", centre_id)
        .eq("patient_id", patient_id).order("version", desc=True).limit(1)
    )
    plan = {
        "id": str(uuid.uuid4()), "patient_id": patient_id, "centre_id": centre_id,
        "version": int(prior[0]["version"]) + 1 if prior else 1,
        "supersedes_id": None, "proposed_by": actor_id, "status": status,
        "clinical_draft_id": None, "signed_by": None, "signed_at": None,
    }
    item_rows, check_rows = [], []
    for position, raw in enumerate(requested_items, 1):
        cat = catalogue[str(raw["catalogue_id"])]
        item, check = _screened_item(raw, cat, position, safety_facts)
        item["plan_id"] = plan["id"]
        check.update({
            "patient_id": patient_id, "centre_id": centre_id,
            "evaluation_point": "proposal", "evaluated_by": actor_id,
        })
        item_rows.append(item)
        check_rows.append(check)
    body = _snapshot(plan, item_rows)
    plan["content_sha256"] = hashlib.sha256(body.encode()).hexdigest()
    supabase.table("therapy_plans").insert(plan).execute()
    supabase.table("therapy_plan_items").insert(item_rows).execute()
    supabase.table("therapy_safety_checks").insert(check_rows).execute()
    return {
        **plan,
        "items": [_decorate(row, catalogue[row["catalogue_id"]]["slug"]) for row in item_rows],
    }


def _clinic_for_centre(supabase: Any, centre_id: str) -> str | None:
    rows = _rows(
        supabase.table("centre_clinics").select("clinic_id").eq("centre_id", centre_id)
        .eq("status", "linked").is_("unlinked_at", "null").limit(1)
    )
    return str(rows[0]["clinic_id"]) if rows else None


def sign_plan(
    supabase: Any,
    doctor_id: str,
    plan_id: str,
    expected_sha256: str,
    note: str,
    safety_facts: Mapping,
) -> dict:
    plan = _one(supabase, "therapy_plans", plan_id)
    if not plan:
        raise PlanInvalid("therapy plan not found")
    if plan.get("status") not in ("proposed", "in_review"):
        raise PlanConflict("therapy plan is not signable")
    if not _doctor_may_treat(supabase, doctor_id, str(plan["centre_id"]), str(plan["patient_id"])):
        raise PlanForbidden("only the assigned verified doctor may sign this plan")
    items = _rows(
        supabase.table("therapy_plan_items").select("*").eq("plan_id", plan_id).order("position")
    )
    catalogue = _catalogue(supabase, [str(item["catalogue_id"]) for item in items])
    checks = []
    changed = False
    for item in items:
        decision = screen_therapy(str(catalogue[str(item["catalogue_id"])]["slug"]), safety_facts)
        replacement = {
            "disposition": "excluded_safety" if not decision.eligible else "proposed",
            "safety_reason_code": decision.reason_codes[0] if not decision.eligible else None,
            "safety_explanation": " ".join(decision.explanations) if not decision.eligible else None,
        }
        if any(item.get(key) != value for key, value in replacement.items()):
            changed = True
            supabase.table("therapy_plan_items").update(replacement).eq("id", item["id"]).execute()
            item.update(replacement)
        checks.append({
            "id": str(uuid.uuid4()), "patient_id": plan["patient_id"],
            "centre_id": plan["centre_id"], "catalogue_id": item["catalogue_id"],
            "plan_item_id": item["id"], "evaluation_point": "signature",
            "rule_version": RULE_VERSION, "fact_snapshot": dict(safety_facts),
            "eligible": decision.eligible, "reason_codes": list(decision.reason_codes),
            "explanations": list(decision.explanations), "evaluated_by": doctor_id,
        })
    supabase.table("therapy_safety_checks").insert(checks).execute()
    body = _snapshot(plan, items)
    digest = hashlib.sha256(body.encode()).hexdigest()
    if changed:
        supabase.table("therapy_plans").update({"content_sha256": digest}).eq("id", plan_id).execute()
    if expected_sha256 != plan.get("content_sha256") or digest != plan.get("content_sha256"):
        raise PlanConflict("therapy plan changed; reload before signing")
    draft_id = str(uuid.uuid4())
    now = datetime.now(UTC)
    supabase.table("clinical_drafts").insert({
        "id": draft_id, "user_id": plan["patient_id"],
        "clinic_id": _clinic_for_centre(supabase, str(plan["centre_id"])),
        "kind": "therapy", "title": f"Therapy plan v{plan['version']}",
        "body": body, "evidence": [{"therapy_plan_id": plan_id, "content_sha256": digest}],
        "routing_flags": ["clinical_plan"], "status": "drafted",
        "sla_due_at": (now + timedelta(hours=72)).isoformat(),
        "model_version": RULE_VERSION, "source_kind": "therapy_plan",
        "source_id": plan_id, "dedupe_key": f"therapy-plan:{plan_id}:{digest}",
    }).execute()
    supabase.table("clinical_drafts").update({"status": "queued"}).eq("id", draft_id).execute()
    supabase.table("clinical_drafts").update({
        "status": "in_review", "claimed_by": doctor_id, "claimed_at": now.isoformat(),
    }).eq("id", draft_id).execute()
    supabase.table("clinical_reviews").insert({
        "id": str(uuid.uuid4()), "draft_id": draft_id, "clinician_id": doctor_id,
        "action": "signed", "signed_body_sha256": digest, "notes": note.strip() or None,
    }).execute()
    supabase.table("clinical_drafts").update({"status": "signed"}).eq("id", draft_id).execute()
    signed = {
        "status": "signed", "clinical_draft_id": draft_id, "content_sha256": digest,
        "signed_by": doctor_id, "signed_at": now.isoformat(),
    }
    supabase.table("therapy_plans").update(signed).eq("id", plan_id).execute()
    return {**plan, **signed, "items": [_decorate(row, catalogue[str(row["catalogue_id"])]["slug"]) for row in items]}
