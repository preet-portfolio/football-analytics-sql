-- Canonical model: dimensions.
-- Every table states its grain in COMMENT ON TABLE; the status page shows it.

-- ---------------------------------------------------------------- competition
CREATE TABLE model.competition (
    competition_id   int     PRIMARY KEY,
    competition_name text    NOT NULL,
    country_name     text    NOT NULL,
    gender           text    NOT NULL CHECK (gender IN ('male', 'female')),
    is_youth         boolean NOT NULL,
    is_international boolean NOT NULL
);
COMMENT ON TABLE model.competition IS 'Grain: one row per competition (e.g. FIFA World Cup), across all its seasons.';

INSERT INTO model.competition
SELECT DISTINCT ON (competition_id)
       competition_id, payload->>'competition_name', payload->>'country_name',
       payload->>'competition_gender', (payload->>'competition_youth')::boolean,
       (payload->>'competition_international')::boolean
FROM stg.competition
ORDER BY competition_id, season_id;

-- ------------------------------------------------------------------ season
-- StatsBomb season_id is NOT unique on its own: 106 is both the 2022 men's
-- World Cup and Women's Euro 2022. A season only exists within a competition.
CREATE TABLE model.season (
    competition_id int  NOT NULL REFERENCES model.competition,
    season_id      int  NOT NULL,
    season_name    text NOT NULL,
    PRIMARY KEY (competition_id, season_id)
);
COMMENT ON TABLE model.season IS 'Grain: one row per competition season (competition_id, season_id).';

INSERT INTO model.season
SELECT competition_id, season_id, payload->>'season_name' FROM stg.competition;

-- -------------------------------------------------------------------- team
CREATE TABLE model.team (
    team_id   int  PRIMARY KEY,
    team_name text NOT NULL UNIQUE,
    country   text NOT NULL,
    gender    text NOT NULL
);
COMMENT ON TABLE model.team IS 'Grain: one row per team.';

INSERT INTO model.team
SELECT DISTINCT ON (team_id) team_id, team_name, country, gender
FROM (
    SELECT (payload->'home_team'->>'home_team_id')::int, payload->'home_team'->>'home_team_name',
           payload->'home_team'->'country'->>'name', payload->'home_team'->>'home_team_gender', match_id
    FROM stg.match
    UNION ALL
    SELECT (payload->'away_team'->>'away_team_id')::int, payload->'away_team'->>'away_team_name',
           payload->'away_team'->'country'->>'name', payload->'away_team'->>'away_team_gender', match_id
    FROM stg.match
) t (team_id, team_name, country, gender, match_id)
ORDER BY team_id, match_id DESC;

-- ------------------------------------------------------------- season_team
-- Group membership belongs to a team within one season, not to the team.
CREATE TABLE model.season_team (
    competition_id int  NOT NULL,
    season_id      int  NOT NULL,
    team_id        int  NOT NULL REFERENCES model.team,
    group_name     text,                        -- e.g. 'Group A'; NULL for league formats
    PRIMARY KEY (competition_id, season_id, team_id),
    FOREIGN KEY (competition_id, season_id) REFERENCES model.season
);
COMMENT ON TABLE model.season_team IS 'Grain: one row per team per competition season, with its group.';

-- StatsBomb leaves the group label empty for some teams (2022: Morocco, in all
-- three of its group matches). Group-stage opponents always share a group, so a
-- missing label is taken from the opponents' label.
INSERT INTO model.season_team
WITH side AS (
    SELECT (payload->'competition'->>'competition_id')::int AS competition_id,
           (payload->'season'->>'season_id')::int          AS season_id,
           (payload->'home_team'->>'home_team_id')::int    AS team_id,
           nullif(payload->'home_team'->>'home_team_group', '') AS own_group,
           nullif(payload->'away_team'->>'away_team_group', '') AS opponent_group
    FROM stg.match WHERE payload->'competition_stage'->>'name' = 'Group Stage'
    UNION ALL
    SELECT (payload->'competition'->>'competition_id')::int,
           (payload->'season'->>'season_id')::int,
           (payload->'away_team'->>'away_team_id')::int,
           nullif(payload->'away_team'->>'away_team_group', ''),
           nullif(payload->'home_team'->>'home_team_group', '')
    FROM stg.match WHERE payload->'competition_stage'->>'name' = 'Group Stage'
)
SELECT competition_id, season_id, team_id,
       coalesce(max(own_group), max(opponent_group)) AS group_name
FROM side
GROUP BY competition_id, season_id, team_id
-- a team with conflicting labels is left out; the '8 groups of 4' test then fails
HAVING count(DISTINCT own_group) <= 1 AND count(DISTINCT coalesce(own_group, opponent_group)) <= 1;

-- ------------------------------------------------------------------ player
-- StatsBomb spells a few players differently across matches under one id
-- ('Phil Foden' / 'Philip Foden'), and nickname/country vary too (Zaroury's
-- country is Morocco in 3 matches, Belgium in 4). Each attribute is chosen on its
-- own: the most frequent non-NULL value, ties broken by the latest match date.
CREATE TABLE model.player (
    player_id       int  PRIMARY KEY,
    player_name     text NOT NULL,
    player_nickname text,                       -- the commonly used name, e.g. 'Lionel Messi'
    country         text,
    display_name    text GENERATED ALWAYS AS (coalesce(player_nickname, player_name)) STORED
);
COMMENT ON TABLE model.player IS 'Grain: one row per player (StatsBomb player_id); each attribute is its most frequent value.';

CREATE TEMP TABLE player_attr ON COMMIT DROP AS
SELECT lp.player_id, a.attr, a.val, count(*) AS uses,
       max((m.payload->>'match_date')::date) AS last_seen
FROM stg.lineup_player lp
JOIN stg.match m USING (match_id)
CROSS JOIN LATERAL (VALUES ('name', lp.payload->>'player_name'),
                           ('nickname', lp.payload->>'player_nickname'),
                           ('country', lp.payload->'country'->>'name')) a (attr, val)
WHERE a.val IS NOT NULL
GROUP BY lp.player_id, a.attr, a.val;

INSERT INTO model.player (player_id, player_name, player_nickname, country)
SELECT p.player_id,
       (SELECT val FROM player_attr x WHERE x.player_id = p.player_id AND attr = 'name'     ORDER BY uses DESC, last_seen DESC, val LIMIT 1),
       (SELECT val FROM player_attr x WHERE x.player_id = p.player_id AND attr = 'nickname' ORDER BY uses DESC, last_seen DESC, val LIMIT 1),
       (SELECT val FROM player_attr x WHERE x.player_id = p.player_id AND attr = 'country'  ORDER BY uses DESC, last_seen DESC, val LIMIT 1)
FROM (SELECT DISTINCT player_id FROM stg.lineup_player) p;

-- ----------------------------------------------------------------- manager
CREATE TABLE model.manager (
    manager_id    int  PRIMARY KEY,
    manager_name  text NOT NULL,
    nickname      text,
    date_of_birth date,
    country       text
);
COMMENT ON TABLE model.manager IS 'Grain: one row per manager.';

INSERT INTO model.manager
SELECT DISTINCT ON ((mg->>'id')::int)
       (mg->>'id')::int, mg->>'name', mg->>'nickname', (mg->>'dob')::date, mg->'country'->>'name'
FROM stg.match
CROSS JOIN LATERAL (
    SELECT jsonb_array_elements(payload->'home_team'->'managers')
    UNION ALL
    SELECT jsonb_array_elements(payload->'away_team'->'managers')
) x (mg)
ORDER BY (mg->>'id')::int, match_id DESC;

-- ------------------------------------------------- stadium, referee, lookups
CREATE TABLE model.stadium (
    stadium_id   int  PRIMARY KEY,
    stadium_name text NOT NULL,
    country      text
);
COMMENT ON TABLE model.stadium IS 'Grain: one row per stadium.';

INSERT INTO model.stadium
SELECT DISTINCT ON ((payload->'stadium'->>'id')::int)
       (payload->'stadium'->>'id')::int, payload->'stadium'->>'name', payload->'stadium'->'country'->>'name'
FROM stg.match ORDER BY (payload->'stadium'->>'id')::int, match_id DESC;

CREATE TABLE model.referee (
    referee_id   int  PRIMARY KEY,
    referee_name text NOT NULL,
    country      text
);
COMMENT ON TABLE model.referee IS 'Grain: one row per referee.';

INSERT INTO model.referee
SELECT DISTINCT ON ((payload->'referee'->>'id')::int)
       (payload->'referee'->>'id')::int, payload->'referee'->>'name', payload->'referee'->'country'->>'name'
FROM stg.match WHERE payload ? 'referee'
ORDER BY (payload->'referee'->>'id')::int, match_id DESC;

-- StatsBomb id/name pairs used on every event get proper lookup tables.
CREATE TABLE model.event_type   (event_type_id   int PRIMARY KEY, event_type_name   text NOT NULL UNIQUE);
CREATE TABLE model.play_pattern (play_pattern_id int PRIMARY KEY, play_pattern_name text NOT NULL UNIQUE);
CREATE TABLE model.position     (position_id     int PRIMARY KEY, position_name     text NOT NULL UNIQUE);
COMMENT ON TABLE model.event_type   IS 'Grain: one row per StatsBomb event type (Pass, Shot, Pressure, ...).';
COMMENT ON TABLE model.play_pattern IS 'Grain: one row per play pattern (Regular Play, From Corner, ...).';
COMMENT ON TABLE model.position     IS 'Grain: one row per pitch position (Goalkeeper, Left Back, ...).';

INSERT INTO model.event_type
SELECT DISTINCT (payload->'type'->>'id')::int, payload->'type'->>'name' FROM stg.event;

INSERT INTO model.play_pattern
SELECT DISTINCT (payload->'play_pattern'->>'id')::int, payload->'play_pattern'->>'name' FROM stg.event;

INSERT INTO model.position
SELECT DISTINCT position_id, position_name FROM (
    SELECT (payload->'position'->>'id')::int, payload->'position'->>'name'
    FROM stg.event WHERE payload ? 'position'
    UNION
    SELECT (pos->>'position_id')::int, pos->>'position'
    FROM stg.lineup_player CROSS JOIN LATERAL jsonb_array_elements(payload->'positions') pos
) p (position_id, position_name);
