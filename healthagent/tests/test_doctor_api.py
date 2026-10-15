from types import SimpleNamespace

import pytest
from pydantic import ValidationError

from app.gateway.api.doctor import (
    ClinicalDecision,
    NoteCreate,
    add_note,
    claim_work,
    doctor_work_queue,
    sign_report,
    doctor_today,
)
from app.gateway.api.admin_people import _clinical_record as admin_clinical_record
from app.gateway.api.centre import _clinical_record as centre_clinical_record


DOCTOR = "10000000-0000-0000-0000-000000000001"
PATIENT = "10000000-0000-0000-0000-000000000002"
CENTRE = "20000000-0000-0000-0000-000000000001"


class Db:
    def __init__(self):
        self.calls = []
        self.tables = {
            "profiles": [{"id": DOCTOR, "app_role": "doctor"}, {"id": PATIENT, "app_role": "member", "full_name": "Patient"}],
            "centre_memberships": [{"id": "m1", "centre_id": CENTRE, "user_id": DOCTOR, "member_kind": "doctor", "status": "active", "left_at": None}],
            "clinician_verifications": [{"doctor_id": DOCTOR, "status": "verified", "created_at": "2026-01-01"}],
            "patient_doctor_assignments": [{"id": "a1", "centre_id": CENTRE, "doctor_id": DOCTOR, "patient_id": PATIENT, "ended_at": None, "is_primary": True}],
            "clinical_drafts": [{"id": "draft-1", "user_id": PATIENT, "kind": "observation", "status": "queued", "body": "Body", "title": "Review", "updated_at": "v1", "routing_flags": []}],
            "monthly_reports": [{"id": "report-1", "patient_id": PATIENT, "centre_id": CENTRE, "status": "draft", "version": 1}],
            "therapy_plans": [{"id": "plan-1", "patient_id": PATIENT, "centre_id": CENTRE, "status": "proposed", "version": 1, "created_at": "2026-10-15"}],
            "clinician_notes": [],
        }

    def table(self, name): return Query(name, self.tables.setdefault(name, []))
    def rpc(self, name, params):
        self.calls.append((name, params))
        value = {"append_clinician_note": "note-1", "sign_monthly_report": "a" * 64}.get(name, True)
        return SimpleNamespace(execute=lambda: SimpleNamespace(data=value))


class Query:
    columns = {
        "clinical_drafts": {
            "id", "user_id", "clinic_id", "kind", "title", "body", "evidence",
            "routing_flags", "status", "claimed_by", "claimed_at", "sla_due_at",
            "model_version", "source_kind", "source_id", "created_at", "updated_at",
        },
        "monthly_reports": {
            "id", "patient_id", "centre_id", "period_start", "period_end",
            "source_cutoff", "evidence", "body", "version", "status", "supersedes_id",
            "created_by", "created_at", "reviewer_note", "signed_by", "reviewed_at",
            "signed_body_sha256",
        },
        "lab_escalations": {
            "id", "user_id", "upload_id", "biomarker_id", "context",
            "value_canonical", "operator", "unit", "severity", "message",
            "acknowledged_at", "created_at",
        },
    }

    def __init__(self, name, rows):
        self.name, self.rows, self.filters, self.op, self.payload = name, rows, [], "select", None
    def select(self, *args, **_kwargs):
        if self.name in self.columns:
            selected = {part.strip() for arg in args for part in arg.split(",")}
            assert selected <= self.columns[self.name], (
                self.name, selected - self.columns[self.name]
            )
        return self
    def eq(self, k, v): self.filters.append((k, v)); return self
    def is_(self, k, v):
        if self.name in self.columns:
            assert k in self.columns[self.name], (self.name, k)
        self.filters.append((k, None)); return self
    def in_(self, k, values): self.filters.append((k, set(values))); return self
    def order(self, *_args, **_kwargs): return self
    def limit(self, _n): return self
    def update(self, values): self.op, self.payload = "update", values; return self
    def insert(self, values): self.op, self.payload = "insert", values; return self
    def execute(self):
        def match(row):
            return all((row.get(k) in v if isinstance(v, set) else row.get(k) == v) for k, v in self.filters)
        rows = [r for r in self.rows if match(r)]
        if self.op == "update":
            for row in rows: row.update(self.payload)
        elif self.op == "insert":
            self.rows.append(self.payload.copy()); rows = [self.payload]
        return SimpleNamespace(data=[r.copy() for r in rows])


def test_blank_notes_are_rejected_before_any_request():
    with pytest.raises(ValidationError):
        ClinicalDecision(note="   ", version="v1")
    with pytest.raises(ValidationError):
        NoteCreate(body="   ")


def test_queue_populates_the_f12_therapy_plan_segment():
    result = doctor_work_queue(CENTRE, DOCTOR, Db())
    assert set(result) == {"monthly_reports", "sync_drafts", "consults", "therapy_plans", "rx_supplements"}
    assert [row["id"] for row in result["therapy_plans"]] == ["plan-1"]
    assert result["rx_supplements"] == []


def test_doctor_can_append_note_only_through_scoped_rpc():
    db = Db()
    result = add_note(CENTRE, PATIENT, NoteCreate(body="Reviewed trend"), DOCTOR, db)
    assert result["id"] == "note-1"
    assert db.calls[-1][1]["p_actor"] == DOCTOR


def test_claim_and_report_sign_use_authenticated_doctor_and_note():
    db = Db()
    claimed = claim_work(CENTRE, "draft-1", DOCTOR, db)
    assert claimed["status"] == "in_review"
    signed = sign_report(CENTRE, "report-1", ClinicalDecision(note="Reviewed evidence", version="1"), DOCTOR, db)
    assert signed["signed_body_sha256"] == "a" * 64
    assert db.calls[-1][1]["p_actor"] == DOCTOR


def test_gateway_queries_match_the_deployed_clinical_schema():
    db = Db()
    db.tables["lab_escalations"] = []
    doctor_today(CENTRE, DOCTOR, db)
    doctor_work_queue(CENTRE, DOCTOR, db)
    admin_clinical_record(db, PATIENT)
    centre_clinical_record(db, PATIENT)
