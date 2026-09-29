from datetime import datetime, timedelta

from app.analytics.event_analysis import BASELINE_DAYS, TRACKED, WINDOW, Reading, to_readings


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
