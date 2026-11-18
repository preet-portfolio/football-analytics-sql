#!/usr/bin/env bash
# Rebuild the stg and model schemas from raw, atomically (one transaction:
# a failing constraint leaves the previous model untouched).
set -euo pipefail
cd "$(dirname "$0")/.."
args=()
for f in sql/stg/*.sql sql/model/*.sql; do args+=(-f "/$f"); done
start=$(date +%s)
docker compose exec -T db psql -v ON_ERROR_STOP=1 -U football -d football -q -1 "${args[@]}"
docker compose exec -T db psql -U football -d football -q -c "ANALYZE;"
echo "model: rebuilt stg + model in $(( $(date +%s) - start ))s"
