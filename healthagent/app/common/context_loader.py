from datetime import datetime, timedelta, timezone

from app.analytics.event_analysis import BASELINE_DAYS, TRACKED, WINDOW, Reading, to_readings


# Model-reachable log kinds. `medications` is deliberately absent: safety facts are
# fetched deterministically and always included, never via a skippable tool.
LOG_KINDS = frozenset({
    "lab_results", "therapy_sessions", "genetic_records", "environment_logs",
    "meals", "workouts", "hydration_logs", "plans", "progress_checkins",
    "consultations", "timeline_events",
})

SESSION_FIELDS = "id,activity_type,started_at,ended_at,duration_seconds,summary"


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

    def documents(self, user_id: str, kind: str | None = None, limit: int = 5) -> dict:
        """No object-storage backend is wired yet, so this reports `unconfigured` —
        which must never be narrated as the user having no documents."""
        return _unconfigured("no document storage backend is configured")
