#!/usr/bin/env bash
# Export pipeline state for the local status page (site/) as site/data/status.json.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p site/data

docker compose exec -T db psql -U football -d football -qAt -v ON_ERROR_STOP=1 <<'SQL' > site/data/status.json
SELECT json_build_object(
  'generated_at', now(),
  'sources', (
    SELECT json_agg(s ORDER BY s.source, s.entity) FROM (
      SELECT source, entity, count(*) AS files, sum(byte_size) AS bytes,
             min(source_ref) AS source_ref, max(loaded_at) AS loaded_at
      FROM raw.source_file GROUP BY source, entity) s),
  'event_count', (
    SELECT sum(jsonb_array_length(payload)) FROM raw.source_file WHERE entity = 'events'),
  'matches', (
    SELECT json_agg(r ORDER BY r.match_date, r.match_id) FROM audit.score_reconciliation r)
);
SQL
echo "report: wrote site/data/status.json"
