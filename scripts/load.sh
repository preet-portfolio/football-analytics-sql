#!/usr/bin/env bash
# Load every file under data/raw/ into raw.source_file, one row per file,
# in a single transaction. Re-running is idempotent (upsert on file_path).
set -euo pipefail
cd "$(dirname "$0")/.."
source config/sources.env

PSQL=(docker compose exec -T db psql -v ON_ERROR_STOP=1 -U football -d football -q)

for f in sql/raw/*.sql sql/audit/*.sql; do
  "${PSQL[@]}" -f "/$f"
done

{
  echo "BEGIN;"
  (cd data/raw && find statsbomb openfootball -type f -name '*.json' | sort) | while read -r path; do
    source=${path%%/*}
    if [ "$source" = statsbomb ]; then
      rest=${path#statsbomb/}; entity=${rest%%/*}; entity=${entity%.json}; ref=$STATSBOMB_COMMIT
    else
      entity=results; ref=$OPENFOOTBALL_COMMIT
    fi
    echo "SELECT raw.load_file('$source', '$entity', '$path', '$ref');"
  done
  echo "COMMIT;"
} | "${PSQL[@]}" > /dev/null

"${PSQL[@]}" -c "SELECT source, entity, count(*) AS files, pg_size_pretty(sum(byte_size)) AS size FROM raw.source_file GROUP BY 1, 2 ORDER BY 1, 2;"
