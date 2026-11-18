-- The raw layer holds every file the pinned sources promise, and nothing is missing.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap;
SELECT plan(9);

SELECT has_table('raw', 'source_file', 'raw.source_file exists');

SELECT is((SELECT count(*)::int FROM raw.source_file WHERE source = 'statsbomb' AND entity = 'matches'),
          1, 'exactly one StatsBomb matches file is loaded');

SELECT is((SELECT jsonb_array_length(payload) FROM raw.source_file
            WHERE source = 'statsbomb' AND entity = 'matches'),
          64, 'the 2022 World Cup matches file lists 64 matches');

SELECT is_empty($$
    SELECT m->>'match_id' AS match_id_without_events
    FROM raw.source_file f, jsonb_array_elements(f.payload) m
    WHERE f.source = 'statsbomb' AND f.entity = 'matches'
      AND NOT EXISTS (SELECT 1 FROM raw.source_file e
                       WHERE e.file_path = 'statsbomb/events/' || (m->>'match_id') || '.json')
$$, 'every match has an events file');

SELECT is_empty($$
    SELECT m->>'match_id' AS match_id_without_lineups
    FROM raw.source_file f, jsonb_array_elements(f.payload) m
    WHERE f.source = 'statsbomb' AND f.entity = 'matches'
      AND NOT EXISTS (SELECT 1 FROM raw.source_file e
                       WHERE e.file_path = 'statsbomb/lineups/' || (m->>'match_id') || '.json')
$$, 'every match has a lineups file');

SELECT is((SELECT count(*)::int FROM raw.source_file WHERE entity IN ('events', 'lineups')),
          128, 'no stray events or lineups files beyond the 64 matches');

SELECT is((SELECT jsonb_array_length(payload->'matches') FROM raw.source_file WHERE source = 'openfootball'),
          64, 'openfootball lists 64 matches');

SELECT is_empty($$
    SELECT file_path FROM raw.source_file WHERE jsonb_typeof(payload) NOT IN ('array', 'object')
$$, 'every payload parsed to a JSON array or object');

-- openfootball uses two score shapes ({"ft": [h, a], ...} and a bare [h, a]);
-- fail loudly if a third appears, because the audit view only parses these two.
SELECT is_empty($$
    SELECT m->>'team1' AS team1, m->>'team2' AS team2, m->'score' AS score
    FROM raw.source_file f, jsonb_array_elements(f.payload->'matches') m
    WHERE f.source = 'openfootball'
      AND NOT (   (jsonb_typeof(m->'score') = 'array'  AND jsonb_array_length(m->'score') = 2)
               OR (jsonb_typeof(m->'score') = 'object' AND jsonb_typeof(m->'score'->'ft') = 'array'))
$$, 'every openfootball score has one of the two known shapes');

SELECT * FROM finish();
ROLLBACK;
