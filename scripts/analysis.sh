#!/usr/bin/env bash
# (Re)create the analysis views over the model.
set -euo pipefail
cd "$(dirname "$0")/.."
args=()
for f in sql/analysis/*.sql; do args+=(-f "/$f"); done
docker compose exec -T -e PGOPTIONS="-c client_min_messages=warning" db psql -v ON_ERROR_STOP=1 -U football -d football -q -1 "${args[@]}"
echo "analysis: created $(docker compose exec -T db psql -U football -d football -At -c "SELECT count(*) FROM information_schema.views WHERE table_schema = 'analysis'") views"
