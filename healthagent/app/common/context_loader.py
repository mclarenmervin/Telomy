from datetime import datetime, timedelta, timezone

from app.analytics.check_in import CHECK_IN_PREFIX
from app.analytics.event_analysis import BASELINE_DAYS, TRACKED, WINDOW, Reading, to_readings


# Model-reachable log kinds. `medications` is deliberately absent: safety facts are
# fetched deterministically and always included, never via a skippable tool.
LOG_KINDS = frozenset({
    "lab_results", "therapy_sessions", "genetic_records", "environment_logs",
    "meals", "workouts", "hydration_logs", "plans", "progress_checkins",
    "consultations", "timeline_events",
})

SESSION_FIELDS = "id,activity_type,started_at,ended_at,duration_seconds,summary"

# Document classes with a storage backend. Genetics exports and, later, imaging
# have none, and asking for one of those is answered with `unconfigured` rather
# than an empty list.
LAB_DOCUMENT_KINDS = frozenset({"lab_report", "lab_reports"})

# Providers `app.common.documents` has an adapter for.
READABLE_PROVIDERS = frozenset({"supabase"})


def _ok(items) -> dict:
    """`empty` means we looked and found nothing — never confuse it with `unconfigured`."""
    return {"status": "ok" if items else "empty", "items": items}


def _unconfigured(reason: str) -> dict:
    return {"status": "unconfigured", "items": [], "reason": reason}


def _since(days: int) -> str:
    return (datetime.now(timezone.utc) - timedelta(days=days)).isoformat()


class ContextLoader:
    """The only place the agent reads user data. Every query is scoped by user_id."""

    def __init__(self, supabase, page_size: int = 1000):
        self._db = supabase
        self._page_size = page_size

    def load_event(self, user_id: str, event_id: str) -> dict | None:
        rows = (
            self._db.table("events")
            .select("*")
            .eq("user_id", user_id)
            .eq("id", event_id)
            .execute()
            .data
        )
        return rows[0] if rows else None

    def load_readings(self, user_id: str, start: datetime, end: datetime) -> list[Reading]:
        low = (start - timedelta(days=BASELINE_DAYS)).isoformat()
        high = (end + WINDOW).isoformat()
        rows, offset = [], 0
        while True:
            page = (
                self._db.table("health_measurements")
                .select("measurement_type,value,recorded_at")
                .eq("user_id", user_id)
                .in_("measurement_type", list(TRACKED))
                .gte("recorded_at", low)
                .lte("recorded_at", high)
                .order("recorded_at")
                .range(offset, offset + self._page_size - 1)
                .execute()
                .data
            )
            rows.extend(page)
            if len(page) < self._page_size:
                return to_readings(rows)
            offset += self._page_size

    def load_other_events(
        self, user_id: str, event_id: str, since: datetime
    ) -> list[tuple[datetime, datetime]]:
        rows = (
            self._db.table("events")
            .select("started_at,ended_at")
            .eq("user_id", user_id)
            .neq("id", event_id)
            .not_.is_("ended_at", "null")
            .gte("started_at", since.isoformat())
            .execute()
            .data
        )
        return [
            (datetime.fromisoformat(r["started_at"]), datetime.fromisoformat(r["ended_at"]))
            for r in rows
        ]

    def sent_check_in_reasons(self, user_id: str, event_id: str) -> set[str]:
        """Which mid-event reasons this event has already been alerted about.

        Filtered in Python rather than with a `like`: the set per event is tiny,
        and one fewer PostgREST operator is one fewer thing to get wrong.
        """
        rows = (
            self._db.table("predictions")
            .select("kind")
            .eq("user_id", user_id)
            .eq("event_id", event_id)
            .execute()
            .data
        )
        return {
            row["kind"][len(CHECK_IN_PREFIX):]
            for row in rows
            if str(row.get("kind", "")).startswith(CHECK_IN_PREFIX)
        }

    def range_overrides(self, user_id: str) -> list[dict]:
        """Every reference-range override that applies to this person.

        Read once per user, not once per marker: grading a 40-marker panel must
        not be 40 round trips. Precedence between the rows (user beats clinic
        beats global) is decided by `app.analytics.reference_ranges`, not here —
        one place, so two screens cannot disagree about whether a result is
        normal.
        """
        clinics = [
            row["clinic_id"]
            for row in (
                self._db.table("clinic_members")
                .select("clinic_id")
                .eq("user_id", user_id)
                .execute()
                .data
            )
        ]

        rows = (
            self._db.table("reference_range_overrides")
            .select("*")
            .eq("scope", "user")
            .eq("user_id", user_id)
            .execute()
            .data
        )
        for clinic_id in clinics:
            rows += (
                self._db.table("reference_range_overrides")
                .select("*")
                .eq("scope", "clinic")
                .eq("clinic_id", clinic_id)
                .execute()
                .data
            )
        return rows

    def activity_session(self, user_id: str, session_id: str) -> dict | None:
        rows = (
            self._db.table("activity_sessions")
            .select("*")
            .eq("user_id", user_id)
            .eq("id", session_id)
            .execute()
            .data
        )
        return rows[0] if rows else None

    def past_activity_sessions(
        self,
        user_id: str,
        activity_type: str | None,
        limit: int = 5,
        window_days: int = 90,
        exclude_id: str | None = None,
    ) -> dict:
        query = (
            self._db.table("activity_sessions")
            .select(SESSION_FIELDS)
            .eq("user_id", user_id)
            .gte("started_at", _since(window_days))
        )
        if activity_type:
            query = query.eq("activity_type", activity_type)
        if exclude_id:
            # A session must never contribute to its own baseline.
            query = query.neq("id", exclude_id)
        rows = query.order("started_at", desc=True).range(0, max(0, limit - 1)).execute().data
        return _ok(rows)

    def past_activity_reports(self, user_id: str, limit: int = 3) -> dict:
        rows = (
            self._db.table("predictions")
            .select("summary,analysis,created_at")
            .eq("user_id", user_id)
            .eq("kind", "activity_summary")
            .order("created_at", desc=True)
            .range(0, max(0, limit - 1))
            .execute()
            .data
        )
        return _ok(rows)

    def user_profile(self, user_id: str) -> dict:
        rows = (
            self._db.table("user_preferences")
            .select("profile")
            .eq("user_id", user_id)
            .execute()
            .data
        )
        return _ok(rows)

    def safety_facts(self, user_id: str) -> dict:
        """Medications — always fetched, never exposed as a model-callable tool."""
        rows = (
            self._db.table("medications")
            .select("title,notes,fields,recorded_at")
            .eq("user_id", user_id)
            .order("recorded_at", desc=True)
            .range(0, 49)
            .execute()
            .data
        )
        return _ok(rows)

    def logs(self, user_id: str, kind: str, days: int = 30, limit: int = 20) -> dict:
        if kind not in LOG_KINDS:
            raise ValueError(f"kind not allowed: {kind}")
        rows = (
            self._db.table(kind)
            .select("title,notes,fields,recorded_at")
            .eq("user_id", user_id)
            .gte("recorded_at", _since(days))
            .order("recorded_at", desc=True)
            .range(0, max(0, limit - 1))
            .execute()
            .data
        )
        return _ok(rows)

    def measurements(
        self, user_id: str, measurement_type: str, days: int = 30, limit: int = 100
    ) -> dict:
        rows = (
            self._db.table("health_measurements")
            .select("measurement_type,value,unit,recorded_at,quality")
            .eq("user_id", user_id)
            .eq("measurement_type", measurement_type)
            .gte("recorded_at", _since(days))
            .order("recorded_at", desc=True)
            .range(0, max(0, limit - 1))
            .execute()
            .data
        )
        return _ok(rows)

    def daily_snapshots(self, user_id: str, days: int = 7) -> dict:
        rows = (
            self._db.table("wearable_daily_reports")
            .select("report_date,snapshot")
            .eq("user_id", user_id)
            .order("report_date", desc=True)
            .range(0, max(0, days - 1))
            .execute()
            .data
        )
        return _ok(rows)

    def biomarker_results(
        self,
        user_id: str,
        biomarker_id: str | None = None,
        days: int = 730,
        limit: int = 100,
    ) -> dict:
        """Lab values the user has confirmed, newest sample first.

        **Only `confirmed` and `corrected`.** An `extracted` row has not been
        checked by anyone, and a value the user has never seen must not come
        back out of the model's mouth as fact. That filter is the whole reason
        the confirmation step exists.

        **No verdict is included, deliberately.** `biomarkers.v1.yaml` has not
        been reviewed by a clinician, which is why the app shows these values
        with no grading; handing the model a grade would make it the thing that
        interprets them and walk straight around that gate. It gets the number,
        the unit, the date and the operator, and nothing that reads as a
        judgement.

        Two years by default, because the useful question about a lab value is
        almost always how it has moved rather than what it is today.
        """
        query = (
            self._db.table("biomarker_results")
            .select(
                "biomarker_id,context,result_type,operator,raw_value,raw_unit,"
                "value_canonical,unit_canonical,value_text,collected_at,lab_name"
            )
            .eq("user_id", user_id)
            .in_("status", ["confirmed", "corrected"])
        )
        if biomarker_id:
            query = query.eq("biomarker_id", biomarker_id)
        rows = (
            query.gte("collected_at", _since(days))
            .order("collected_at", desc=True)
            .range(0, max(0, limit - 1))
            .execute()
            .data
        )
        return _ok(rows)

    def documents(self, user_id: str, kind: str | None = None, limit: int = 5) -> dict:
        """The user's uploaded documents.

        Lab reports have a backend as of F3 and are read from `lab_uploads`.
        Every other class still reports `unconfigured`, which must never be
        narrated as the user having none — "we could not look" and "you have
        none" are different statements and the agent is told to keep them apart.

        No file contents and no signed URLs here. This is the agent's context,
        and the agent has no business downloading a 20MB PDF; it needs to know a
        report exists, when the sample was taken and whether we have finished
        reading it.
        """
        if kind is not None and kind not in LAB_DOCUMENT_KINDS:
            return _unconfigured(f"no document storage backend is configured for {kind}")

        rows = (
            self._db.table("lab_uploads")
            .select(
                "id,status,storage_provider,collected_at,reported_at,lab_name,"
                "patient_name,page_count,is_history,created_at"
            )
            .eq("user_id", user_id)
            .order("created_at", desc=True)
            .range(0, max(0, limit - 1))
            .execute()
            .data
        )

        # A report on a provider this build cannot open is unreadable, not
        # absent. Imaging moves to R2 later; until that adapter exists, saying
        # "you have no reports" to someone who has one would be a lie.
        readable = [r for r in rows if r.get("storage_provider") in READABLE_PROVIDERS]
        if rows and not readable:
            providers = sorted({str(r.get("storage_provider")) for r in rows})
            return _unconfigured("no storage adapter for " + ", ".join(providers))
        return _ok(readable)
