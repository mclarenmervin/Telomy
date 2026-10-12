import ast
from pathlib import Path

import pytest
from fastapi import HTTPException

from app.gateway.doctor_loader import DoctorLoader
from tests.fakes import FakeSupabase


DOCTOR_A = "10000000-0000-0000-0000-000000000001"
DOCTOR_B = "10000000-0000-0000-0000-000000000002"
PATIENT_A = "10000000-0000-0000-0000-000000000003"
PATIENT_B = "10000000-0000-0000-0000-000000000004"
CENTRE_A = "20000000-0000-0000-0000-000000000001"
CENTRE_B = "20000000-0000-0000-0000-000000000002"


def db():
    return FakeSupabase({
        "profiles": [
            {"id": DOCTOR_A, "app_role": "doctor", "full_name": "Doctor A"},
            {"id": DOCTOR_B, "app_role": "doctor", "full_name": "Doctor B"},
            {"id": PATIENT_A, "app_role": "member", "full_name": "Patient A"},
            {"id": PATIENT_B, "app_role": "member", "full_name": "Patient B"},
        ],
        "centre_memberships": [
            {"centre_id": CENTRE_A, "user_id": DOCTOR_A, "member_kind": "doctor", "status": "active", "left_at": None},
            {"centre_id": CENTRE_B, "user_id": DOCTOR_A, "member_kind": "doctor", "status": "active", "left_at": None},
            {"centre_id": CENTRE_A, "user_id": DOCTOR_B, "member_kind": "doctor", "status": "active", "left_at": None},
        ],
        "clinician_verifications": [
            {"doctor_id": DOCTOR_A, "status": "verified", "created_at": "2026-01-01"},
            {"doctor_id": DOCTOR_B, "status": "verified", "created_at": "2026-01-01"},
        ],
        "patient_doctor_assignments": [
            {"id": "a1", "centre_id": CENTRE_A, "doctor_id": DOCTOR_A, "patient_id": PATIENT_A, "ended_at": None, "is_primary": True},
            {"id": "a2", "centre_id": CENTRE_B, "doctor_id": DOCTOR_A, "patient_id": PATIENT_B, "ended_at": None, "is_primary": True},
        ],
        "clinical_drafts": [
            {"id": "d1", "user_id": PATIENT_A, "centre_id": CENTRE_A, "state": "ready"},
            {"id": "d2", "user_id": PATIENT_B, "centre_id": CENTRE_B, "state": "ready"},
        ],
    })


def test_loader_returns_only_assigned_patients_for_current_centre():
    database = db()
    assert [p["id"] for p in DoctorLoader.for_actor(database, DOCTOR_A, CENTRE_A).patients()] == [PATIENT_A]
    assert DoctorLoader.for_actor(database, DOCTOR_B, CENTRE_A).patients() == []


def test_centre_switch_never_reuses_previous_patient_scope():
    database = db()
    assert DoctorLoader.for_actor(database, DOCTOR_A, CENTRE_A).patient(PATIENT_A)["id"] == PATIENT_A
    with pytest.raises(HTTPException):
        DoctorLoader.for_actor(database, DOCTOR_A, CENTRE_B).patient(PATIENT_A)
    assert DoctorLoader.for_actor(database, DOCTOR_A, CENTRE_B).patient(PATIENT_B)["id"] == PATIENT_B


def test_ended_assignment_disappears_on_next_call():
    database = db()
    loader = DoctorLoader.for_actor(database, DOCTOR_A, CENTRE_A)
    assert loader.patients()
    database.tables["patient_doctor_assignments"][0]["ended_at"] = "2026-10-12T00:00:00Z"
    assert loader.patients() == []
    assert loader.drafts() == []


def test_agent_and_tools_cannot_import_doctor_only_data_sources():
    app = Path(__file__).parents[1] / "app"
    forbidden = ("doctor_loader", "clinical_drafts", "clinician_notes")
    offenders = []
    for folder in (app / "agent", app / "tools"):
        if not folder.exists():
            continue
        for path in folder.rglob("*.py"):
            tree = ast.parse(path.read_text())
            imports = [
                node.module or "" for node in ast.walk(tree)
                if isinstance(node, ast.ImportFrom)
            ] + [
                alias.name for node in ast.walk(tree) if isinstance(node, ast.Import)
                for alias in node.names
            ]
            table_names = [
                node.args[0].value for node in ast.walk(tree)
                if isinstance(node, ast.Call)
                and isinstance(node.func, ast.Attribute)
                and node.func.attr == "table"
                and node.args
                and isinstance(node.args[0], ast.Constant)
                and isinstance(node.args[0].value, str)
            ]
            if any(term in name for term in forbidden for name in imports + table_names):
                offenders.append(str(path.relative_to(app)))
    assert offenders == []
