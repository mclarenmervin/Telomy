#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: ./scripts/test-db.sh db/tests/<contract>.sql" >&2
  exit 64
fi

contract_file="$1"
if [[ ! -f "$contract_file" ]]; then
  echo "database contract not found: $contract_file" >&2
  exit 66
fi

database_url="${TEST_DATABASE_URL:-${SUPABASE_DB_URL:-}}"
if [[ -z "$database_url" ]]; then
  echo "set TEST_DATABASE_URL (preferred) or SUPABASE_DB_URL" >&2
  exit 78
fi

psql "$database_url" -v ON_ERROR_STOP=1 -f "$contract_file"
