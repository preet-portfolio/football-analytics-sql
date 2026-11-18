-- Audit layer: reconciliation of three independent witnesses of each result.
--
--   1. events  — goals counted from StatsBomb event data (what our pipeline derives)
--   2. sb      — the score StatsBomb publishes in matches.json
--   3. of      — the score openfootball publishes (independent, public domain)
--
-- Grain: one row per StatsBomb match. Reads only from raw.*; the pgTAP tests
-- and the local status page both read this view, so they cannot disagree.
--
-- Scoring rules (StatsBomb conventions):
--   * a goal is a Shot with outcome 'Goal', or an 'Own Goal For' event, which
--     StatsBomb attributes to the team that benefits;
--   * periods 1-4 are regulation and extra time; period 5 is the penalty
--     shootout and does not count towards the match score.

CREATE SCHEMA IF NOT EXISTS audit;

CREATE OR REPLACE VIEW audit.score_reconciliation AS
WITH sb AS (
    SELECT (m->>'match_id')::bigint                       AS match_id,
           (m->>'match_date')::date                       AS match_date,
           m->'competition_stage'->>'name'                AS stage,
           m->'home_team'->>'home_team_name'              AS home_team,
           m->'away_team'->>'away_team_name'              AS away_team,
           (m->>'home_score')::int                        AS sb_home,
           (m->>'away_score')::int                        AS sb_away
    FROM raw.source_file f
    CROSS JOIN LATERAL jsonb_array_elements(f.payload) AS m
    WHERE f.source = 'statsbomb' AND f.entity = 'matches'
),
goal_events AS (
    SELECT substring(f.file_path FROM '(\d+)\.json$')::bigint AS match_id,
           e->'team'->>'name'                                 AS team,
           (e->>'period')::int                                AS period
    FROM raw.source_file f
    CROSS JOIN LATERAL jsonb_array_elements(f.payload) AS e
    WHERE f.source = 'statsbomb' AND f.entity = 'events'
      AND (   (e->'type'->>'name' = 'Shot' AND e->'shot'->'outcome'->>'name' = 'Goal')
           OR  e->'type'->>'name' = 'Own Goal For')
),
ev AS (
    SELECT sb.match_id,
           count(*) FILTER (WHERE g.team = sb.home_team AND g.period < 5) AS ev_home,
           count(*) FILTER (WHERE g.team = sb.away_team AND g.period < 5) AS ev_away,
           count(*) FILTER (WHERE g.team = sb.home_team AND g.period = 5) AS ev_pen_home,
           count(*) FILTER (WHERE g.team = sb.away_team AND g.period = 5) AS ev_pen_away,
           EXISTS (SELECT 1 FROM raw.source_file f
                    WHERE f.source = 'statsbomb' AND f.entity = 'events'
                      AND f.file_path = 'statsbomb/events/' || sb.match_id || '.json') AS has_events
    FROM sb
    LEFT JOIN goal_events g USING (match_id)
    GROUP BY sb.match_id, sb.home_team, sb.away_team
),
-- openfootball spells one team differently; map it to the StatsBomb name.
team_alias (of_name, sb_name) AS (
    VALUES ('USA', 'United States')
),
of_raw AS (
    SELECT (m->>'date')::date                               AS match_date,
           coalesce(a1.sb_name, m->>'team1')                AS team1,
           coalesce(a2.sb_name, m->>'team2')                AS team2,
           -- Upstream drift: 7 matches store score as a bare array [h, a] instead of
           -- {"ft": [h, a]}. et, when present, is cumulative incl. regulation.
           CASE WHEN jsonb_typeof(m->'score') = 'array' THEN m->'score'
                ELSE coalesce(m->'score'->'et', m->'score'->'ft') END AS score,
           CASE WHEN jsonb_typeof(m->'score') = 'object' THEN m->'score'->'p' END AS pens
    FROM raw.source_file f
    CROSS JOIN LATERAL jsonb_array_elements(f.payload->'matches') AS m
    LEFT JOIN team_alias a1 ON a1.of_name = m->>'team1'
    LEFT JOIN team_alias a2 ON a2.of_name = m->>'team2'
    WHERE f.source = 'openfootball' AND f.entity = 'results'
),
-- Join on date + unordered team pair (Croatia v Morocco happens twice in 2022),
-- then orient openfootball's team1/team2 to StatsBomb's home/away.
ofm AS (
    SELECT sb.match_id,
           CASE WHEN o.team1 = sb.home_team THEN (o.score->>0)::int ELSE (o.score->>1)::int END AS of_home,
           CASE WHEN o.team1 = sb.home_team THEN (o.score->>1)::int ELSE (o.score->>0)::int END AS of_away,
           CASE WHEN o.team1 = sb.home_team THEN (o.pens->>0)::int  ELSE (o.pens->>1)::int  END AS of_pen_home,
           CASE WHEN o.team1 = sb.home_team THEN (o.pens->>1)::int  ELSE (o.pens->>0)::int  END AS of_pen_away
    FROM sb
    JOIN of_raw o
      ON o.match_date = sb.match_date
     AND ((o.team1 = sb.home_team AND o.team2 = sb.away_team)
       OR (o.team1 = sb.away_team AND o.team2 = sb.home_team))
)
SELECT sb.match_id, sb.match_date, sb.stage, sb.home_team, sb.away_team,
       sb.sb_home, sb.sb_away,
       ev.ev_home, ev.ev_away, ev.ev_pen_home, ev.ev_pen_away, ev.has_events,
       ofm.of_home, ofm.of_away, ofm.of_pen_home, ofm.of_pen_away,
       ofm.match_id IS NOT NULL                                              AS of_found,
       ev.has_events AND (ev.ev_home, ev.ev_away) = (sb.sb_home, sb.sb_away) AS events_agree,
       coalesce((ofm.of_home, ofm.of_away) = (sb.sb_home, sb.sb_away), false) AS external_agree,
       ofm.match_id IS NOT NULL
         AND ev.ev_pen_home = coalesce(ofm.of_pen_home, 0)
         AND ev.ev_pen_away = coalesce(ofm.of_pen_away, 0)                   AS shootout_agree
FROM sb
JOIN ev USING (match_id)
LEFT JOIN ofm USING (match_id);

COMMENT ON VIEW audit.score_reconciliation IS
  'Grain: one row per StatsBomb match. Compares event-derived, StatsBomb-published and openfootball scores.';
