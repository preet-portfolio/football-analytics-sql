-- Staging layer: explode raw files into one jsonb row per record, keyed.
-- Rebuilt in full on every `make model`; UNLOGGED because it is reproducible.
-- Model tables read from here instead of re-parsing 190 MB of raw JSON per table.

DROP SCHEMA IF EXISTS model CASCADE;
DROP SCHEMA IF EXISTS stg CASCADE;
CREATE SCHEMA stg;
CREATE SCHEMA model;

-- Grain: one row per StatsBomb match.
CREATE UNLOGGED TABLE stg.match AS
SELECT (m->>'match_id')::bigint AS match_id, m AS payload
FROM raw.source_file f
CROSS JOIN LATERAL jsonb_array_elements(f.payload) AS m
WHERE f.source = 'statsbomb' AND f.entity = 'matches';
ALTER TABLE stg.match ADD PRIMARY KEY (match_id);
COMMENT ON TABLE stg.match IS 'One row per match (jsonb), from matches.json.';

-- Grain: one row per competition season listed by StatsBomb.
CREATE UNLOGGED TABLE stg.competition AS
SELECT (c->>'competition_id')::int AS competition_id, (c->>'season_id')::int AS season_id, c AS payload
FROM raw.source_file f
CROSS JOIN LATERAL jsonb_array_elements(f.payload) AS c
WHERE f.source = 'statsbomb' AND f.entity = 'competitions';
ALTER TABLE stg.competition ADD PRIMARY KEY (competition_id, season_id);
COMMENT ON TABLE stg.competition IS 'One row per competition season (jsonb), from competitions.json.';

-- Grain: one row per player per team per match (matchday squad member).
CREATE UNLOGGED TABLE stg.lineup_player AS
SELECT substring(f.file_path FROM '(\d+)\.json$')::bigint AS match_id,
       (t->>'team_id')::int                               AS team_id,
       (p->>'player_id')::int                             AS player_id,
       p                                                  AS payload
FROM raw.source_file f
CROSS JOIN LATERAL jsonb_array_elements(f.payload) AS t
CROSS JOIN LATERAL jsonb_array_elements(t->'lineup') AS p
WHERE f.source = 'statsbomb' AND f.entity = 'lineups';
ALTER TABLE stg.lineup_player ADD PRIMARY KEY (match_id, player_id);
COMMENT ON TABLE stg.lineup_player IS 'One row per player in a team''s matchday squad (jsonb), from lineups.';

-- Grain: one row per event. The primary key doubles as a uniqueness check on event ids.
CREATE UNLOGGED TABLE stg.event AS
SELECT substring(f.file_path FROM '(\d+)\.json$')::bigint AS match_id,
       (e->>'id')::uuid                                   AS event_id,
       e->'type'->>'name'                                 AS type_name,
       e                                                  AS payload
FROM raw.source_file f
CROSS JOIN LATERAL jsonb_array_elements(f.payload) AS e
WHERE f.source = 'statsbomb' AND f.entity = 'events';
ALTER TABLE stg.event ADD PRIMARY KEY (event_id);
CREATE INDEX ON stg.event (type_name);
COMMENT ON TABLE stg.event IS 'One row per event (jsonb), from events files.';

-- Grain: one row per upstream record rejected by the model because it is
-- impossible (e.g. a lineup stint that ends before it starts). Rejected rows are
-- kept with the reason, never silently dropped; a test pins the known list.
CREATE TABLE stg.quarantine (
    target_table text  NOT NULL,
    record_key   jsonb NOT NULL,
    reason       text  NOT NULL,
    payload      jsonb NOT NULL,
    PRIMARY KEY (target_table, record_key)
);
COMMENT ON TABLE stg.quarantine IS 'One row per upstream record rejected as impossible, with the reason.';

ANALYZE stg.match, stg.competition, stg.lineup_player, stg.event;
