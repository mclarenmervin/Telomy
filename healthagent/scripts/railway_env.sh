#!/usr/bin/env bash
# Prints the Railway variable block for the gateway and activity-worker services,
# built from your local .env. Paste the output into Railway's raw variable editor
# (Service -> Variables -> RAW Editor) on BOTH services, or into project-level
# Shared Variables once.
#
#   ./scripts/railway_env.sh            # print the block
#   ./scripts/railway_env.sh | pbcopy   # straight to the clipboard
#
# Nothing is written or uploaded; this only reads .env and writes to stdout.
set -euo pipefail

cd "$(dirname "$0")/.."
[ -f .env ] || { echo "no .env in $(pwd)" >&2; exit 1; }

get() { grep -m1 "^$1=" .env 2>/dev/null | cut -d= -f2- || true; }

missing=()
for key in SUPABASE_URL SUPABASE_SERVICE_KEY WEBHOOK_SECRET OPENAI_API_KEY SUPABASE_DB_URL; do
  [ -n "$(get "$key")" ] || missing+=("$key")
done
if [ ${#missing[@]} -gt 0 ]; then
  echo "# WARNING: missing from .env, fill these in by hand: ${missing[*]}" >&2
fi

db_url="$(get SUPABASE_DB_URL)"
case "$db_url" in
  *:6543/*) echo "# WARNING: SUPABASE_DB_URL uses port 6543 (transaction pooler)." >&2
            echo "#          The checkpointer needs the SESSION pooler on 5432." >&2 ;;
esac

cat <<EOF
SUPABASE_URL=$(get SUPABASE_URL)
SUPABASE_SERVICE_KEY=$(get SUPABASE_SERVICE_KEY)
SUPABASE_DB_URL=${db_url}
WEBHOOK_SECRET=$(get WEBHOOK_SECRET)
OPENAI_API_KEY=$(get OPENAI_API_KEY)
REDIS_URL=\${{Redis.REDIS_URL}}
LLM_PROVIDER=openai
LLM_MODEL=${LLM_MODEL_OVERRIDE:-gpt-5.4-mini}
QUEUE_NAME=events:realtime
ACTIVITY_QUEUE_NAME=activity:realtime
MAX_LLM_CALLS=2
MAX_TOOL_CALLS=8
WALL_CLOCK_SECONDS=60
EOF
