#!/usr/bin/env bash
# Usage: PGSUPER_URL=postgres://postgres:postgres@localhost:5432/postgres ./scripts/migrate.sh [dbname]
# Creates the database (if missing) and applies all migrations. Safe to run on a fresh DB only.
set -euo pipefail
DB="${1:-nset}"
BASE="${PGSUPER_URL:?set PGSUPER_URL to a superuser connection URL (to the 'postgres' db)}"
DIR="$(cd "$(dirname "$0")/.." && pwd)/migrations"
TARGET="${BASE%/*}/$DB"

psql -v ON_ERROR_STOP=1 "$BASE" -f "$DIR/000_roles.sql"
psql -v ON_ERROR_STOP=1 "$BASE" -tAc "SELECT 1 FROM pg_database WHERE datname='$DB'" | grep -q 1 \
  || psql -v ON_ERROR_STOP=1 "$BASE" -c "CREATE DATABASE $DB OWNER nset_owner"
# The DB may already exist (e.g. created by docker's POSTGRES_DB); make sure nset_owner owns it.
psql -v ON_ERROR_STOP=1 "$BASE" -c "ALTER DATABASE $DB OWNER TO nset_owner"

for f in 001_schema 002_security 003_integrity; do
  echo "== $f"
  PGOPTIONS='-c role=nset_owner' psql -v ON_ERROR_STOP=1 -q "$TARGET" -f "$DIR/$f.sql"
done
echo "migrations applied to $DB"