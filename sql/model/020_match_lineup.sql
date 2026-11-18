-- Canonical model: matches and lineups.

-- ------------------------------------------------------------------- match
CREATE TABLE model.match (
    match_id          bigint PRIMARY KEY,
    competition_id    int    NOT NULL,
    season_id         int    NOT NULL,
    match_date        date   NOT NULL,
    kick_off          time,
    stage             text   NOT NULL,
    match_week        int,
    home_team_id      int    NOT NULL REFERENCES model.team,
    away_team_id      int    NOT NULL REFERENCES model.team,
    home_score        int    NOT NULL CHECK (home_score >= 0),   -- incl. extra time, excl. shootout
    away_score        int    NOT NULL CHECK (away_score >= 0),
    home_manager_id   int    REFERENCES model.manager,
    away_manager_id   int    REFERENCES model.manager,
    stadium_id        int    REFERENCES model.stadium,
    referee_id        int    REFERENCES model.referee,            -- NULL for one 2022 match
    data_version      text,
    FOREIGN KEY (competition_id, season_id) REFERENCES model.season,
    CHECK (home_team_id <> away_team_id)
);
COMMENT ON TABLE model.match IS 'Grain: one row per match. Scores include extra time but not penalty shootouts.';

INSERT INTO model.match
SELECT match_id,
       (payload->'competition'->>'competition_id')::int,
       (payload->'season'->>'season_id')::int,
       (payload->>'match_date')::date,
       (payload->>'kick_off')::time,
       payload->'competition_stage'->>'name',
       (payload->>'match_week')::int,
       (payload->'home_team'->>'home_team_id')::int,
       (payload->'away_team'->>'away_team_id')::int,
       (payload->>'home_score')::int,
       (payload->>'away_score')::int,
       (payload->'home_team'->'managers'->0->>'id')::int,
       (payload->'away_team'->'managers'->0->>'id')::int,
       (payload->'stadium'->>'id')::int,
       (payload->'referee'->>'id')::int,
       payload->'metadata'->>'data_version'
FROM stg.match;

-- ------------------------------------------------------------------ lineup
-- StatsBomb clock strings are 'MM:SS' with minutes that run past 99 ('105:00'),
-- so they are parsed to seconds rather than cast to a time type.
CREATE FUNCTION model.clock_to_seconds(text) RETURNS int
LANGUAGE sql IMMUTABLE STRICT
RETURN split_part($1, ':', 1)::int * 60 + split_part($1, ':', 2)::int;

CREATE TABLE model.lineup (
    match_id      bigint  NOT NULL REFERENCES model.match,
    team_id       int     NOT NULL REFERENCES model.team,
    player_id     int     NOT NULL REFERENCES model.player,
    jersey_number int     NOT NULL CHECK (jersey_number BETWEEN 1 AND 99),
    is_starter    boolean NOT NULL,
    played        boolean NOT NULL,      -- false for unused substitutes
    PRIMARY KEY (match_id, player_id)
);
COMMENT ON TABLE model.lineup IS 'Grain: one row per player in a team''s matchday squad, including unused substitutes.';

INSERT INTO model.lineup
SELECT match_id, team_id, player_id, (payload->>'jersey_number')::int,
       coalesce(payload->'positions'->0->>'start_reason' = 'Starting XI', false),
       jsonb_array_length(payload->'positions') > 0
FROM stg.lineup_player;

CREATE TABLE model.lineup_stint (
    match_id       bigint NOT NULL,
    player_id      int    NOT NULL,
    stint_no       int    NOT NULL,
    position_id    int    NOT NULL REFERENCES model.position,
    from_period    int    NOT NULL CHECK (from_period BETWEEN 1 AND 5),
    to_period      int             CHECK (to_period BETWEEN 1 AND 5),   -- NULL: still on at the final whistle
    from_seconds   int    NOT NULL CHECK (from_seconds >= 0),
    to_seconds     int,
    start_reason   text   NOT NULL,
    end_reason     text   NOT NULL,
    PRIMARY KEY (match_id, player_id, stint_no),
    FOREIGN KEY (match_id, player_id) REFERENCES model.lineup,
    CHECK (to_seconds IS NULL OR (to_seconds >= from_seconds AND to_period >= from_period))
);
COMMENT ON TABLE model.lineup_stint IS 'Grain: one row per continuous spell a player spends in one position in a match.';

-- Lineup positions contain phantom spells (95 in 30 matches; worst in the 5
-- extra-time matches, after late Tactical Shifts; elsewhere mostly zero-length
-- spells at half-time substitutions). Impossible stints are quarantined with a reason; positions are
-- kept for the rest. Time on the pitch comes from model.appearance (event stream).
CREATE TEMP TABLE stint_src ON COMMIT DROP AS
SELECT lp.match_id, lp.player_id, pos.ord::int AS stint_no, pos.p,
       (pos.p->>'from_period')::int AS from_period, (pos.p->>'to_period')::int AS to_period,
       model.clock_to_seconds(pos.p->>'from') AS from_seconds, model.clock_to_seconds(pos.p->>'to') AS to_seconds
FROM stg.lineup_player lp
CROSS JOIN LATERAL jsonb_array_elements(lp.payload->'positions') WITH ORDINALITY AS pos (p, ord);

ALTER TABLE stint_src ADD COLUMN reject_reason text;
UPDATE stint_src SET reject_reason = CASE
    WHEN to_seconds IS NOT NULL AND (to_seconds < from_seconds OR to_period < from_period)
        THEN 'stint ends before it starts'
    WHEN p->>'end_reason' LIKE 'Substitution - On%'
        THEN 'stint ends because the same player came on'
END;

-- After removing those, a stint that still overlaps an earlier stint of the same
-- player is a phantom too (a player cannot be on the pitch twice at once).
UPDATE stint_src a SET reject_reason = 'stint overlaps an earlier stint of the same player'
WHERE a.reject_reason IS NULL AND EXISTS (
    SELECT 1 FROM stint_src b
    WHERE b.match_id = a.match_id AND b.player_id = a.player_id AND b.reject_reason IS NULL
      AND b.stint_no < a.stint_no
      AND (b.from_period, b.from_seconds) < (coalesce(a.to_period, 9), coalesce(a.to_seconds, 999999))
      AND (a.from_period, a.from_seconds) < (coalesce(b.to_period, 9), coalesce(b.to_seconds, 999999)));

-- A substitute must come on before anything else can happen to them: a stint
-- that precedes the substitute's entry stint (or a substitute with no entry stint
-- at all) is a phantom.
UPDATE stint_src a SET reject_reason = 'substitute''s stint precedes their entry'
WHERE a.reject_reason IS NULL
  AND NOT EXISTS (SELECT 1 FROM stint_src s WHERE s.match_id = a.match_id AND s.player_id = a.player_id
                    AND s.p->>'start_reason' = 'Starting XI')
  AND NOT EXISTS (SELECT 1 FROM stint_src b
                  WHERE b.match_id = a.match_id AND b.player_id = a.player_id AND b.reject_reason IS NULL
                    AND b.p->>'start_reason' ~ '^(Substitution - On|Player On)'
                    AND (b.from_period, b.from_seconds) <= (a.from_period, a.from_seconds));

ALTER TABLE stint_src ADD COLUMN is_valid boolean;
UPDATE stint_src SET is_valid = reject_reason IS NULL;

INSERT INTO stg.quarantine
SELECT 'model.lineup_stint', jsonb_build_object('match_id', match_id, 'player_id', player_id, 'stint_no', stint_no),
       reject_reason, p
FROM stint_src WHERE NOT is_valid;

INSERT INTO model.lineup_stint
SELECT match_id, player_id, stint_no, (p->>'position_id')::int, from_period, to_period,
       from_seconds, to_seconds, p->>'start_reason', p->>'end_reason'
FROM stint_src WHERE is_valid;

CREATE TABLE model.card (
    match_id     bigint NOT NULL,
    player_id    int    NOT NULL,
    card_no      int    NOT NULL,
    card_type    text   NOT NULL CHECK (card_type IN ('Yellow Card', 'Second Yellow', 'Red Card')),
    reason       text   NOT NULL,
    period       int    NOT NULL,
    clock_seconds int   NOT NULL,
    PRIMARY KEY (match_id, player_id, card_no),
    FOREIGN KEY (match_id, player_id) REFERENCES model.lineup
);
COMMENT ON TABLE model.card IS 'Grain: one row per card shown to a player in a match.';

INSERT INTO model.card
SELECT lp.match_id, lp.player_id, c.ord::int, c.c->>'card_type', c.c->>'reason',
       (c.c->>'period')::int, model.clock_to_seconds(c.c->>'time')
FROM stg.lineup_player lp
CROSS JOIN LATERAL jsonb_array_elements(lp.payload->'cards') WITH ORDINALITY AS c (c, ord);
