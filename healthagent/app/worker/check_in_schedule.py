"""When — if ever — to look at an open event again.

A pure decision, separate from the queue and the agent, because "stop checking"
is the condition that keeps a forgotten event from being examined forever.
"""

from datetime import datetime, timedelta

from app.agent.graph import OPEN_STATUSES
from app.common.timeparse import parse_ts

# Job statuses that continue the timer chain. `ended` runs the full analysis and
# deliberately schedules nothing.
CONTINUING_STATUSES = frozenset({"started", "in_progress"})


def next_check_in_due(
    event: dict | None, job_status: str, now: datetime, settings
) -> datetime | None:
    if event is None or job_status not in CONTINUING_STATUSES:
        return None
    if event.get("status") not in OPEN_STATUSES:
        return None
    started_at = parse_ts(event.get("started_at"))
    if started_at is None:
        return None
    if (now - started_at).total_seconds() >= settings.check_in_max_seconds:
        return None
    return now + timedelta(seconds=settings.check_in_interval_seconds)
