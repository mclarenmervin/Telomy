"""Create (or reuse) a demo auth user and give it a display name.

Idempotent: safe to re-run. Demo/test use only — never run against production data.
"""
import os
import sys

from supabase import create_client

EMAIL = os.environ.get("DEMO_EMAIL", "activity-demo@example.com")
PASSWORD = os.environ.get("DEMO_PASSWORD", "Telomy-Demo-2026!")
DISPLAY_NAME = os.environ.get("DEMO_NAME", "Asha")

client = create_client(os.environ["SUPABASE_URL"], os.environ["SUPABASE_SERVICE_KEY"])


def find_existing(email):
    try:
        users = client.auth.admin.list_users()
    except Exception as exc:
        print(f"could not list users: {exc}", file=sys.stderr)
        return None
    items = users if isinstance(users, list) else getattr(users, "users", []) or []
    for user in items:
        if (getattr(user, "email", None) or "").lower() == email.lower():
            return user
    return None


existing = find_existing(EMAIL)
if existing is not None:
    user_id = existing.id
    print(f"reusing existing demo user: {EMAIL}")
else:
    created = client.auth.admin.create_user({
        "email": EMAIL, "password": PASSWORD, "email_confirm": True,
    })
    user = getattr(created, "user", None) or created
    user_id = user.id
    print(f"created demo user: {EMAIL}")

# Personalisation source for the dynamic prompt (design §7.2).
client.table("user_preferences").upsert(
    {"user_id": user_id, "profile": {"name": DISPLAY_NAME, "displayName": DISPLAY_NAME}},
    on_conflict="user_id",
).execute()

print(f"user_id      = {user_id}")
print(f"display name = {DISPLAY_NAME}")
print("\nAdd this to .env so the demo scripts can find it:")
print(f"DEMO_USER_ID={user_id}")
