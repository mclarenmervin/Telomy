"""Therapy plans: patient proposal, doctor authority, safety and signatures."""

import pytest

from app.clinical.therapy_plans import (
    PlanConflict,
    PlanForbidden,
    create_plan,
    sign_plan,
)
from tests.fakes import FakeSupabase

PATIENT = "10000000-0000-4000-8000-000000000001"
DOCTOR = "10000000-0000-4000-8000-000000000002"
OWNER = "10000000-0000-4000-8000-000000000003"
ADMIN = "10000000-0000-4000-8000-000000000004"
CENTRE = "20000000-0000-4000-8000-000000000001"

SAFE = {
    "pregnancy_status": "not_pregnant", "pacemaker": False,
    "uncontrolled_blood_pressure": False, "recent_cardiac_event": False,
    "raynaud": False, "untreated_pneumothorax": False, "dvt": False,
    "g6pd_deficiency": False, "coronary_plaque": False,
    "alcohol_today": False, "medications": [], "medications_known": True,
}


def db():
    return FakeSupabase({
        "profiles": [
            {"id": PATIENT, "app_role": "member"},
            {"id": DOCTOR, "app_role": "doctor"},
            {"id": OWNER, "app_role": "centre"},
            {"id": ADMIN, "app_role": "admin"},
        ],
        "centre_memberships": [
            {"centre_id": CENTRE, "user_id": PATIENT, "member_kind": "patient", "status": "active", "left_at": None},
            {"centre_id": CENTRE, "user_id": DOCTOR, "member_kind": "doctor", "status": "active", "left_at": None},
            {"centre_id": CENTRE, "user_id": OWNER, "member_kind": "owner", "status": "active", "left_at": None},
        ],
        "clinician_verifications": [
            {"doctor_id": DOCTOR, "status": "verified", "created_at": "2026-10-01T00:00:00Z"},
        ],
        "patient_doctor_assignments": [
            {"centre_id": CENTRE, "patient_id": PATIENT, "doctor_id": DOCTOR, "ended_at": None},
        ],
        "therapy_catalogue": [
            {"id": "cat-sauna", "slug": "sauna", "version": 1, "publication_status": "published"},
            {"id": "cat-hbot", "slug": "hbot", "version": 1, "publication_status": "published"},
        ],
        "therapy_plans": [], "therapy_plan_items": [],
        "therapy_safety_checks": [], "clinical_drafts": [], "clinical_reviews": [],
    })


def items():
    return [{
        "catalogue_id": "cat-sauna", "modality_id": "sauna",
        "frequency": {"sessions_per_week": 3},
        "prescribed_dose": {"duration_minutes": 20},
    }]


def test_patient_can_propose_their_own_plan():
    store = db()

    result = create_plan(store, PATIENT, CENTRE, PATIENT, items(), SAFE)

    assert result["status"] == "proposed"
    assert result["proposed_by"] == PATIENT
    assert result["items"][0]["disposition"] == "proposed"
    assert result["content_sha256"]


def test_assigned_verified_doctor_can_author_a_plan():
    result = create_plan(db(), DOCTOR, CENTRE, PATIENT, items(), SAFE)

    assert result["status"] == "in_review"
    assert result["proposed_by"] == DOCTOR


@pytest.mark.parametrize("actor", [OWNER, ADMIN])
def test_operational_and_admin_roles_cannot_author_clinical_plans(actor):
    with pytest.raises(PlanForbidden):
        create_plan(db(), actor, CENTRE, PATIENT, items(), SAFE)


def test_unsafe_item_is_retained_as_left_out_for_safety():
    mixed = items() + [{
        "catalogue_id": "cat-hbot", "modality_id": "hbot",
        "frequency": {"sessions_per_week": 1},
        "prescribed_dose": {"duration_minutes": 60, "pressure_ata": 2.0},
    }]

    result = create_plan(
        db(), PATIENT, CENTRE, PATIENT, mixed,
        {**SAFE, "untreated_pneumothorax": True},
    )

    excluded = next(row for row in result["items"] if row["modality_id"] == "hbot")
    assert excluded["disposition"] == "excluded_safety"
    assert excluded["section_label"] == "Left out for safety"
    assert "pneumothorax" in excluded["safety_explanation"].lower()


def test_assigned_doctor_signs_the_exact_plan_hash():
    store = db()
    plan = create_plan(store, PATIENT, CENTRE, PATIENT, items(), SAFE)

    signed = sign_plan(
        store, DOCTOR, plan["id"], plan["content_sha256"],
        "Reviewed with the patient", SAFE,
    )

    assert signed["status"] == "signed"
    assert signed["signed_by"] == DOCTOR
    assert signed["content_sha256"] == plan["content_sha256"]
    assert store.tables["clinical_reviews"][0]["signed_body_sha256"] == plan["content_sha256"]


def test_a_stale_plan_hash_cannot_be_signed():
    store = db()
    plan = create_plan(store, PATIENT, CENTRE, PATIENT, items(), SAFE)

    with pytest.raises(PlanConflict, match="changed"):
        sign_plan(store, DOCTOR, plan["id"], "0" * 64, "Reviewed", SAFE)


def test_a_signed_plan_cannot_be_signed_or_rewritten_again():
    store = db()
    plan = create_plan(store, PATIENT, CENTRE, PATIENT, items(), SAFE)
    sign_plan(store, DOCTOR, plan["id"], plan["content_sha256"], "Reviewed", SAFE)

    with pytest.raises(PlanConflict, match="not signable"):
        sign_plan(store, DOCTOR, plan["id"], plan["content_sha256"], "Again", SAFE)
