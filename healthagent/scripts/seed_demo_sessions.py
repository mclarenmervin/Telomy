"""Seed past running sessions for a demo user so the baseline and score exist.

Demo/test use only. Idempotent-ish: re-running adds more history.
"""
import os
import sys
import uuid
from datetime import datetime, timedelta, timezone

from supabase import create_client

user_id = sys.argv[1] if len(sys.argv) > 1 else os.environ["DEMO_USER_ID"]
client = create_client(os.environ["SUPABASE_URL"], os.environ["SUPABASE_SERVICE_KEY"])

now = datetime.now(timezone.utc)
for days_ago, avg_hr in ((10, 152), (7, 150), (4, 151), (2, 149)):
    started = now - timedelta(days=days_ago)
    client.table("activity_sessions").insert(
        {
            "id": str(uuid.uuid4()),
            "user_id": user_id,
            "activity_type": "running",
            "started_at": started.isoformat(),
            "ended_at": (started + timedelta(minutes=30)).isoformat(),
            "duration_seconds": 1800,
            "summary": {"heartRate": avg_hr, "spo2": 97, "hrv": 42},
            "samples": [{"heartRate": avg_hr} for _ in range(30)],
        }
    ).execute()
print(f"seeded 4 past running sessions for {user_id}")
