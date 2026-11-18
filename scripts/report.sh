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
  'model_tables', (
    SELECT json_agg(t ORDER BY t.layer, t.name) FROM (
      SELECT n.nspname AS layer, c.relname AS name,
             obj_description(c.oid, 'pg_class') AS grain,
             (xpath('/row/c/text()', query_to_xml(
                format('SELECT count(*) AS c FROM %I.%I', n.nspname, c.relname), false, true, '')))[1]::text::bigint AS row_count,
             pg_total_relation_size(c.oid) AS bytes
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname IN ('stg', 'model') AND c.relkind = 'r') t),
  'quarantine', (
    SELECT json_agg(q ORDER BY q.match_label) FROM (
      SELECT ht.team_name || ' v ' || at.team_name AS match_label, q.reason, count(*) AS rows,
             string_agg(DISTINCT p.display_name, ', ') AS players
      FROM stg.quarantine q
      JOIN model.match m ON m.match_id = (q.record_key->>'match_id')::bigint
      JOIN model.team ht ON ht.team_id = m.home_team_id
      JOIN model.team at ON at.team_id = m.away_team_id
      JOIN model.player p ON p.player_id = (q.record_key->>'player_id')::int
      GROUP BY 1, 2) q),
  'matches', (
    SELECT json_agg(r ORDER BY r.match_date, r.match_id) FROM audit.score_reconciliation r)
);
SQL
echo "report: wrote site/data/status.json"
