#!/usr/bin/env bash
# Usage: PGSUPER_URL=postgres://postgres:postgres@localhost:5432/postgres ./scripts/test.sh
# Rebuilds a scratch database "nset_test" from the migrations and runs tests/isolation.sql.
set -euo pipefail
BASE="${PGSUPER_URL:?set PGSUPER_URL to a superuser connection URL (to the 'postgres' db)}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
psql -q "$BASE" -c "DROP DATABASE IF EXISTS nset_test WITH (FORCE)"
"$ROOT/scripts/migrate.sh" nset_test >/dev/null
psql -q -v ON_ERROR_STOP=1 -o /dev/null "${BASE%/*}/nset_test" -f "$ROOT/tests/isolation.sql" 2>&1 \
  | sed -E 's/^psql:[^ ]+ //' | grep -E 'PASS|FAIL|ERROR|ALL TESTS'
