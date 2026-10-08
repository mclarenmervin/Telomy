"""Pin the environment the tests run in, whatever the shell is holding.

Several test modules configure themselves with `os.environ.setdefault(...)`,
which quietly defers to a value that is already there. That makes the suite's
result depend on the operator's shell: working on the database starts with

    set -a && . ./.env && set +a

and running pytest in that same shell then loads the real SUPABASE_URL and
WEBHOOK_SECRET into the test process. Two tests fail with a 401 and a mismatched
client, both looking like a regression in code that has not been touched.

pytest imports conftest before it collects anything, so assigning here — not
`setdefault` — wins over both the ambient value and the modules' own defaults.

Nothing in the suite talks to a real service: Supabase is faked, the queue is
faked, and no test should ever reach a network. Fixed, obviously-fake values are
therefore the honest configuration, and a test that needs something else sets it
explicitly with monkeypatch.
"""

import os

TEST_ENVIRONMENT = {
    "SUPABASE_URL": "https://x.supabase.co",
    "SUPABASE_SERVICE_KEY": "service-key",
    "WEBHOOK_SECRET": "shh",
    "REDIS_URL": "redis://localhost:6379/0",
    "QUEUE_NAME": "events:realtime",
}

for name, value in TEST_ENVIRONMENT.items():
    os.environ[name] = value

# The readiness model is selected from the environment and decides which of two
# models every score test exercises. An operator with READINESS_MODEL=v2 set
# would silently run the suite against the model that is not the default.
os.environ.pop("READINESS_MODEL", None)
