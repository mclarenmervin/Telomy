"""Gateway-only, membership-scoped reads for the Centre Owner workspace."""

from __future__ import annotations

from datetime import UTC, datetime, timedelta
from typing import Any

from app.gateway.access_audit import audited_patient_reads
from app.gateway.tenancy import CentreOwnerScope


def _utc(value: Any) -> datetime | None:
    if not value:
        return None
    try:
        parsed = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
        return parsed.replace(tzinfo=UTC) if parsed.tzinfo is None else parsed
    except (TypeError, ValueError):
        return None


class CentreLoader:
    """Read one resolved centre; never accepts a caller-supplied centre ID."""

    def __init__(
        self,
        supabase: Any,
        scope: CentreOwnerScope,
        *,
        request_id: str | None = None,
        actor_role: str = "centre",
    ) -> None:
        self._db = supabase
        self.scope = scope
        self.request_id = request_id
        self.actor_role = actor_role

    def _rows(self, table: str, columns: str, *, batch_size: int = 500) -> list[dict]:
        """Load every scoped row in bounded PostgREST pages."""
        rows: list[dict] = []
        offset = 0
        while True:
            query = (
                self._db.table(table)
                .select(columns)
                .eq("centre_id", self.scope.centre_id)
            )
            if not hasattr(query, "range"):
                return query.limit(10_000).execute().data or []
            page = query.range(offset, offset + batch_size - 1).execute().data or []
            rows.extend(page)
            if len(page) < batch_size:
                return rows
            offset += batch_size

    def rooms(self) -> list[dict]:
        return self._rows(
            "centre_rooms",
            "id,centre_id,name,status,created_at,updated_at",
        )

    def room_hours(self) -> list[dict]:
        return self._rows(
            "centre_room_hours",
            "id,centre_id,room_id,weekday,opens_at,closes_at,valid_from,valid_until",
        )

    def services(self) -> list[dict]:
        return self._rows(
            "centre_services",
            "id,centre_id,name,description,duration_minutes,"
            "indicative_price_minor,currency_code,status,created_at,updated_at",
        )

    def therapy_offerings(self) -> list[dict]:
        return self._rows(
            "centre_therapy_offerings",
            "id,centre_id,catalogue_id,service_id,status,indicative_price_minor,currency_code,default_duration_minutes,operational_notes,created_at,updated_at",
        )

    def therapy_sessions(self) -> list[dict]:
        """Operational lifecycle only: no safety facts or clinical plan content."""
        return self._rows(
            "therapy_service_sessions",
            "id,centre_id,patient_id,offering_id,status,scheduled_start,started_at,ended_at,centre_booking_id,created_at,updated_at",
        )

    def room_services(self) -> list[dict]:
        return self._rows(
            "centre_room_services",
            "id,centre_id,room_id,service_id,linked_at,unlinked_at",
        )

    def bookings(self) -> list[dict]:
        bookings = self._rows(
            "centre_bookings",
            "id,centre_id,patient_id,service_id,room_id,scheduled_start,"
            "scheduled_end,status,version,service_name_snapshot,"
            "duration_minutes_snapshot,indicative_price_minor_snapshot,"
            "currency_code_snapshot,checked_in_at,completed_at,no_show_at,"
            "cancelled_at,cancellation_reason,created_at,updated_at",
        )
        patient_ids = list(
            dict.fromkeys(
                row["patient_id"] for row in bookings if row.get("patient_id")
            )
        )
        profiles = (
            self._db.table("profiles")
            .select("id,full_name")
            .in_("id", patient_ids)
            .execute()
            .data
            if patient_ids
            else []
        ) or []
        patient_names = {
            row["id"]: row.get("full_name") or "Member" for row in profiles
        }
        room_names = {
            row["id"]: row.get("name") or "Room" for row in self.rooms()
        }
        return [
            {
                **row,
                "patient_display_name": patient_names.get(
                    row.get("patient_id"), "Member"
                ),
                "room_name": room_names.get(row.get("room_id"), "Room"),
            }
            for row in bookings
        ]

    def booking_transitions(self) -> list[dict]:
        return self._rows(
            "centre_booking_transitions",
            "id,centre_id,booking_id,actor_id,from_status,to_status,command,"
            "expected_version,reason,created_at",
        )

    def doctors(self, *, limit: int = 200) -> list[dict]:
        memberships = (
            self._db.table("centre_memberships")
            .select("id,user_id,status,accepted_at")
            .eq("centre_id", self.scope.centre_id)
            .eq("member_kind", "doctor")
            .eq("status", "active")
            .is_("left_at", "null")
            .limit(limit)
            .execute()
            .data
            or []
        )
        doctor_ids = [row["user_id"] for row in memberships]
        profiles = (
            self._db.table("profiles")
            .select("id,full_name")
            .in_("id", doctor_ids)
            .execute()
            .data
            if doctor_ids
            else []
        ) or []
        names = {row["id"]: row.get("full_name") or "Doctor" for row in profiles}
        return [
            {
                "id": row["user_id"],
                "centre_id": self.scope.centre_id,
                "name": names.get(row["user_id"], "Doctor"),
                "membership_id": row["id"],
                "status": row.get("status"),
                "accepted_at": row.get("accepted_at"),
            }
            for row in memberships
        ]

    def patients(self, *, limit: int = 200) -> list[dict]:
        """Return the contact-free operational roster, independent of consent."""
        memberships = (
            self._db.table("centre_memberships")
            .select("id,user_id,status,accepted_at")
            .eq("centre_id", self.scope.centre_id)
            .eq("member_kind", "patient")
            .eq("status", "active")
            .is_("left_at", "null")
            .limit(limit)
            .execute()
            .data
            or []
        )
        patient_ids = [row["user_id"] for row in memberships]
        profiles = (
            self._db.table("profiles")
            .select("id,full_name")
            .in_("id", patient_ids)
            .execute()
            .data
            if patient_ids
            else []
        ) or []
        names = {row["id"]: row.get("full_name") or "Patient" for row in profiles}
        return [
            {
                "id": row["user_id"],
                "centre_id": self.scope.centre_id,
                "name": names.get(row["user_id"], "Patient"),
                "membership_id": row["id"],
                "status": row.get("status"),
                "accepted_at": row.get("accepted_at"),
            }
            for row in memberships
        ]

    def _current_member_ids(self) -> list[str]:
        now = datetime.now(UTC).isoformat()
        consents = (
            self._db.table("clinical_access_consents")
            .select("patient_id")
            .eq("centre_id", self.scope.centre_id)
            .eq("purpose", "clinical_care")
            .is_("revoked_at", "null")
            .gt("expires_at", now)
            .execute()
            .data
            or []
        )
        consented = list(dict.fromkeys(row["patient_id"] for row in consents))
        if not consented:
            return []
        memberships = (
            self._db.table("centre_memberships")
            .select("user_id")
            .eq("centre_id", self.scope.centre_id)
            .eq("member_kind", "patient")
            .eq("status", "active")
            .is_("left_at", "null")
            .in_("user_id", consented)
            .execute()
            .data
            or []
        )
        active = {row["user_id"] for row in memberships}
        return [patient_id for patient_id in consented if patient_id in active]

    def member_snapshot(self, *, not_seen_days: int = 30) -> dict:
        """Return audited, contact-free member and follow-up inputs."""
        patient_ids = self._current_member_ids()

        def load() -> dict:
            return self._member_snapshot(patient_ids, not_seen_days=not_seen_days)

        return audited_patient_reads(
            self._db,
            actor_id=self.scope.actor_id,
            actor_role=self.actor_role,
            patient_ids=patient_ids,
            centre_id=self.scope.centre_id,
            resource_type="centre_member_summary",
            reason="consented centre member read",
            request_id=self.request_id,
            read=load,
        )

    def _member_snapshot(self, patient_ids: list[str], *, not_seen_days: int) -> dict:
        if not patient_ids:
            return {
                "items": [],
                "member_count": 0,
                "risk_candidates": [],
                "not_seen_candidates": [],
            }
        profiles = (
            self._db.table("profiles")
            .select("id,full_name")
            .in_("id", patient_ids)
            .execute()
            .data
            or []
        )
        names = {row["id"]: row.get("full_name") or "Member" for row in profiles}
        assignments = (
            self._db.table("patient_doctor_assignments")
            .select("id,centre_id,patient_id,doctor_id,is_primary,assigned_at")
            .eq("centre_id", self.scope.centre_id)
            .in_("patient_id", patient_ids)
            .is_("ended_at", "null")
            .execute()
            .data
            or []
        )
        bookings = (
            self._db.table("centre_bookings")
            .select(
                "id,centre_id,patient_id,service_id,room_id,scheduled_start,"
                "scheduled_end,status,version,service_name_snapshot,"
                "duration_minutes_snapshot,indicative_price_minor_snapshot,"
                "currency_code_snapshot,completed_at"
            )
            .eq("centre_id", self.scope.centre_id)
            .in_("patient_id", patient_ids)
            .execute()
            .data
            or []
        )
        evidence = (
            self._db.table("lab_escalations")
            .select("id,user_id,severity,created_at")
            .in_("user_id", patient_ids)
            .is_("acknowledged_at", "null")
            .execute()
            .data
            or []
        )
        items = []
        for patient_id in patient_ids:
            patient_evidence = [
                {
                    "evidence_class": "critical_lab",
                    "date": row.get("created_at"),
                }
                for row in evidence
                if row.get("user_id") == patient_id
            ]
            items.append({
                "id": patient_id,
                "centre_id": self.scope.centre_id,
                "display_name": names.get(patient_id, "Member"),
                "assignments": [
                    row for row in assignments if row.get("patient_id") == patient_id
                ],
                "bookings": [
                    row for row in bookings if row.get("patient_id") == patient_id
                ],
                "risk_evidence": patient_evidence,
            })

        risk_candidates = [
            {
                "id": item["id"],
                "display_name": item["display_name"],
                "evidence_class": item["risk_evidence"][0]["evidence_class"],
                "date": item["risk_evidence"][0]["date"],
                "action": "Suggest a doctor consultation or retest.",
            }
            for item in items
            if item["risk_evidence"]
        ]
        cutoff = datetime.now(UTC) - timedelta(days=not_seen_days)
        not_seen = [
            {"id": item["id"], "display_name": item["display_name"]}
            for item in items
            if not any(
                booking.get("status") == "completed"
                and (completed := _utc(booking.get("completed_at"))) is not None
                and completed >= cutoff
                for booking in item["bookings"]
            )
        ]
        return {
            "items": items,
            "member_count": len(items),
            "risk_candidates": risk_candidates,
            "not_seen_candidates": not_seen,
        }
