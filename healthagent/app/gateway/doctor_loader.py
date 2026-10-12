"""Doctor-only projections scoped by current centre assignment.

This module is intentionally isolated from the agent and concierge packages.
It uses the service-role client only after reconstructing the allowed patient
set from current memberships, verification and active assignments.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from fastapi import HTTPException


def _rows(query: Any) -> list[dict]:
    return query.execute().data or []


@dataclass(frozen=True)
class DoctorLoader:
    supabase: Any
    doctor_id: str
    centre_id: str

    @classmethod
    def for_actor(cls, supabase: Any, doctor_id: str, centre_id: str) -> "DoctorLoader":
        profiles = _rows(
            supabase.table("profiles").select("app_role").eq("id", doctor_id).limit(1)
        )
        memberships = _rows(
            supabase.table("centre_memberships")
            .select("id")
            .eq("centre_id", centre_id)
            .eq("user_id", doctor_id)
            .eq("member_kind", "doctor")
            .eq("status", "active")
            .is_("left_at", "null")
            .limit(1)
        )
        verifications = _rows(
            supabase.table("clinician_verifications")
            .select("status,created_at")
            .eq("doctor_id", doctor_id)
            .order("created_at", desc=True)
            .limit(1)
        )
        if (
            not profiles
            or profiles[0].get("app_role") != "doctor"
            or not memberships
            or not verifications
            or verifications[0].get("status") != "verified"
        ):
            raise HTTPException(status_code=403, detail="not permitted")
        return cls(supabase=supabase, doctor_id=doctor_id, centre_id=centre_id)

    def _assignments(self) -> list[dict]:
        # Re-evaluated for every operation: an ended assignment must take effect
        # even when the mobile screen and this loader object are still alive.
        return _rows(
            self.supabase.table("patient_doctor_assignments")
            .select("id,patient_id,is_primary,assigned_at")
            .eq("centre_id", self.centre_id)
            .eq("doctor_id", self.doctor_id)
            .is_("ended_at", "null")
        )

    def _patient_ids(self) -> list[str]:
        return [str(row["patient_id"]) for row in self._assignments()]

    def patients(self) -> list[dict]:
        assignments = self._assignments()
        ids = [str(row["patient_id"]) for row in assignments]
        if not ids:
            return []
        profiles = _rows(
            self.supabase.table("profiles")
            .select("id,full_name,email,created_at")
            .in_("id", ids)
        )
        by_id = {str(row["id"]): row for row in profiles}
        return [
            {**by_id[patient_id], "assignment": assignment}
            for assignment in assignments
            if (patient_id := str(assignment["patient_id"])) in by_id
        ]

    def patient(self, patient_id: str) -> dict:
        assignment = next(
            (row for row in self._assignments() if str(row["patient_id"]) == patient_id),
            None,
        )
        if assignment is None:
            raise HTTPException(status_code=404, detail="patient not found")
        profiles = _rows(
            self.supabase.table("profiles")
            .select("id,full_name,email,created_at")
            .eq("id", patient_id)
            .limit(1)
        )
        if not profiles:
            raise HTTPException(status_code=404, detail="patient not found")
        return {**profiles[0], "assignment": assignment}

    def drafts(self, patient_id: str | None = None) -> list[dict]:
        allowed = self._patient_ids()
        if patient_id is not None:
            if patient_id not in allowed:
                raise HTTPException(status_code=404, detail="patient not found")
            allowed = [patient_id]
        if not allowed:
            return []
        return _rows(
            self.supabase.table("clinical_drafts")
            .select("id,user_id,clinic_id,kind,title,body,state,version,created_at,updated_at,sla_due_at")
            .in_("user_id", allowed)
        )
