#!/usr/bin/env bash
set -euo pipefail
DPM="${DPM_BIN:?DPM_BIN is required}"
PG_ADMIN="${POSTGRES_ADMIN_URL:-postgres://postgres@localhost:5432/postgres}"
CR_ADMIN="${COCKROACH_ADMIN_URL:-postgresql://root@localhost:26257/defaultdb?sslmode=disable}"
PG_DB="dm_cross_engine_pg"
CR_DB="dm_cross_engine_cr"
PG_TARGET="postgres://postgres@localhost:5432/${PG_DB}"
CR_TARGET="postgresql://root@localhost:26257/${CR_DB}?sslmode=disable"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
artifacts="$root/artifacts"
mkdir -p "$artifacts"
cleanup() {
  psql "$PG_ADMIN" -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS ${PG_DB} WITH (FORCE)" >/dev/null 2>&1 || true
  psql "$CR_ADMIN" -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS ${CR_DB} CASCADE" >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup
psql "$PG_ADMIN" -v ON_ERROR_STOP=1 -c "CREATE DATABASE ${PG_DB}" >/dev/null
psql "$CR_ADMIN" -v ON_ERROR_STOP=1 -c "CREATE DATABASE ${CR_DB}" >/dev/null

"$DPM" apply --source-sql "$root/fixtures/v1.sql" --target "$PG_TARGET" --shadow "$PG_ADMIN" --yes
"$DPM" apply --source-sql "$root/fixtures/v1.sql" --target "$CR_TARGET" --shadow "$CR_ADMIN" --yes
"$DPM" diff --source-sql "$root/fixtures/v2.sql" --target "$PG_TARGET" --shadow "$PG_ADMIN" --out "$artifacts/postgres-plan.sql"
"$DPM" diff --source-sql "$root/fixtures/v2.sql" --target "$CR_TARGET" --shadow "$CR_ADMIN" --out "$artifacts/cockroach-plan.sql"
for plan in "$artifacts/postgres-plan.sql" "$artifacts/cockroach-plan.sql"; do
  grep -Eqi 'ADD COLUMN|CREATE TABLE' "$plan"
  grep -Eqi 'account_events|status' "$plan"
done

"$DPM" apply --source-sql "$root/fixtures/v2.sql" --target "$PG_TARGET" --shadow "$PG_ADMIN" --yes
"$DPM" apply --source-sql "$root/fixtures/v2.sql" --target "$CR_TARGET" --shadow "$CR_ADMIN" --yes
"$DPM" verify --source-sql "$root/fixtures/v2.sql" --target "$PG_TARGET" --shadow "$PG_ADMIN"
"$DPM" verify --source-sql "$root/fixtures/v2.sql" --target "$CR_TARGET" --shadow "$CR_ADMIN"

signature_sql="SELECT table_name || '|' || column_name || '|' || is_nullable FROM information_schema.columns WHERE table_schema='app' ORDER BY table_name,column_name"
psql "$PG_TARGET" -Atqc "$signature_sql" > "$artifacts/postgres-signature.txt"
psql "$CR_TARGET" -Atqc "$signature_sql" > "$artifacts/cockroach-signature.txt"
diff -u "$artifacts/postgres-signature.txt" "$artifacts/cockroach-signature.txt"

set +e
"$DPM" diff --source "$PG_TARGET" --target "$CR_TARGET" > "$artifacts/cross-dialect.out" 2> "$artifacts/cross-dialect.err"
status=$?
set -e
if [[ "$status" -eq 0 ]]; then
  echo "cross-dialect live diff unexpectedly succeeded" >&2
  exit 1
fi
if [[ ! -s "$artifacts/cross-dialect.err" ]]; then
  echo "cross-dialect refusal did not provide an actionable error" >&2
  exit 1
fi

echo "Cross-engine compatibility certification passed"
