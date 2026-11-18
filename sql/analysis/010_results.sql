-- Analysis layer: analyst questions answered as views over the model.
-- Each view's COMMENT is the question it answers; the status page shows it.
-- Pitch convention: StatsBomb orients every event so the acting team attacks
-- towards x = 120; the goal centre is (120, 40).

DROP SCHEMA IF EXISTS analysis CASCADE;
CREATE SCHEMA analysis;

-- Helper: one row per goal that counts towards the score (no shootout kicks),
-- credited to the team that benefits (own goals via 'Own Goal For').
CREATE VIEW analysis.goal AS
SELECT e.match_id, e.event_id, e.team_id, e.player_id, e.period, e.period_clock, e.minute, e.second,
       (et.event_type_name = 'Own Goal For') AS is_own_goal,
       coalesce(s.shot_type = 'Penalty', false) AS is_penalty
FROM model.event e
JOIN model.event_type et USING (event_type_id)
LEFT JOIN model.shot s USING (event_id)
WHERE e.period < 5 AND (s.is_goal OR et.event_type_name = 'Own Goal For');
COMMENT ON VIEW analysis.goal IS 'Helper: every goal that counts towards the score, credited to the benefiting team.';

-- ------------------------------------------------------------ 1 group table
-- Techniques: UNION ALL to turn matches into team-match rows, conditional
-- aggregation, RANK() window with a multi-key tie-break.
CREATE VIEW analysis.group_table AS
WITH team_match AS (
    SELECT m.match_id, m.competition_id, m.season_id, m.home_team_id AS team_id,
           m.home_score AS gf, m.away_score AS ga
    FROM model.match m WHERE m.stage = 'Group Stage'
    UNION ALL
    SELECT m.match_id, m.competition_id, m.season_id, m.away_team_id, m.away_score, m.home_score
    FROM model.match m WHERE m.stage = 'Group Stage'
), tbl AS (
    SELECT st.group_name, tm.team_id,
           count(*)                                   AS played,
           count(*) FILTER (WHERE gf > ga)            AS won,
           count(*) FILTER (WHERE gf = ga)            AS drawn,
           count(*) FILTER (WHERE gf < ga)            AS lost,
           sum(gf)::int AS goals_for, sum(ga)::int AS goals_against, sum(gf - ga)::int AS goal_diff,
           sum(CASE WHEN gf > ga THEN 3 WHEN gf = ga THEN 1 ELSE 0 END)::int AS points
    FROM team_match tm
    JOIN model.season_team st USING (competition_id, season_id, team_id)
    GROUP BY st.group_name, tm.team_id
)
SELECT group_name AS "group",
       rank() OVER (PARTITION BY group_name ORDER BY points DESC, goal_diff DESC, goals_for DESC)::int AS pos,
       t.team_name AS team, played, won, drawn, lost, goals_for AS gf, goals_against AS ga, goal_diff AS gd, points AS pts
FROM tbl JOIN model.team t USING (team_id)
ORDER BY 1, 2;
COMMENT ON VIEW analysis.group_table IS 'What were the final group tables? Ranked by points, goal difference, goals scored.';

-- ------------------------------------------- 2 game state (leading/drawing/trailing)
-- Techniques: segment boundaries with LEAD(), the running score with SUM() OVER in
-- (period, clock) order (one pass, no self-join), and time split by period so
-- first-half stoppage time is not double counted (the 2nd-half clock restarts at 45:00).
CREATE VIEW analysis.game_state_segment AS
WITH side AS (
    SELECT match_id, home_team_id AS team_id, away_team_id AS opp_id FROM model.match
    UNION ALL
    SELECT match_id, away_team_id, home_team_id FROM model.match
), boundary AS (
    -- each period start and each goal opens a segment
    SELECT mp.match_id, mp.period, interval '0' AS clock, NULL::int AS scoring_team
    FROM model.match_period mp
    UNION ALL
    SELECT g.match_id, g.period, g.period_clock, g.team_id FROM analysis.goal g
), timeline AS (
    SELECT b.match_id, s.team_id, b.period, b.clock,
           coalesce(LEAD(b.clock) OVER (PARTITION BY b.match_id, s.team_id, b.period ORDER BY b.clock), mp.duration) AS to_clock,
           -- running score: one pass with SUM() OVER in (period, clock) order
           sum(CASE WHEN b.scoring_team = s.team_id THEN 1 ELSE 0 END)
               OVER (PARTITION BY b.match_id, s.team_id ORDER BY b.period, b.clock)::int AS goals_for,
           sum(CASE WHEN b.scoring_team = s.opp_id THEN 1 ELSE 0 END)
               OVER (PARTITION BY b.match_id, s.team_id ORDER BY b.period, b.clock)::int AS goals_against
    FROM boundary b
    JOIN side s USING (match_id)
    JOIN model.match_period mp USING (match_id, period)
)
SELECT match_id, team_id, period, clock AS from_clock, to_clock, goals_for, goals_against
FROM timeline;
COMMENT ON VIEW analysis.game_state_segment IS 'Helper: one row per team per stretch of a match between goals, with the score during it.';

CREATE VIEW analysis.team_game_state AS
SELECT t.team_name AS team,
       count(DISTINCT seg.match_id)::int AS matches,
       round(sum(extract(epoch FROM to_clock - from_clock)) FILTER (WHERE goals_for > goals_against) / 60)::int AS mins_leading,
       round(sum(extract(epoch FROM to_clock - from_clock)) FILTER (WHERE goals_for = goals_against) / 60)::int AS mins_level,
       round(sum(extract(epoch FROM to_clock - from_clock)) FILTER (WHERE goals_for < goals_against) / 60)::int AS mins_trailing,
       round(100.0 * sum(extract(epoch FROM to_clock - from_clock)) FILTER (WHERE goals_for > goals_against)
             / sum(extract(epoch FROM to_clock - from_clock)))::int AS pct_leading
FROM analysis.game_state_segment seg
JOIN model.team t USING (team_id)
GROUP BY t.team_name
ORDER BY pct_leading DESC NULLS LAST, mins_trailing;
COMMENT ON VIEW analysis.team_game_state IS 'How long did each team spend leading, level and trailing (minutes, stoppage time included)?';

-- --------------------------------------------------------------- 3 shootouts
CREATE VIEW analysis.shootout AS
SELECT m.match_id, ht.team_name AS home, at.team_name AS away,
       count(*) FILTER (WHERE e.team_id = m.home_team_id)                AS home_kicks,
       count(*) FILTER (WHERE e.team_id = m.home_team_id AND s.is_goal)  AS home_scored,
       count(*) FILTER (WHERE e.team_id = m.away_team_id)                AS away_kicks,
       count(*) FILTER (WHERE e.team_id = m.away_team_id AND s.is_goal)  AS away_scored,
       count(*) FILTER (WHERE s.outcome IN ('Saved', 'Saved to Post'))   AS saved,
       count(*) FILTER (WHERE NOT s.is_goal AND s.outcome NOT IN ('Saved', 'Saved to Post')) AS missed
FROM model.match m
JOIN model.event e ON e.match_id = m.match_id AND e.period = 5
JOIN model.shot s USING (event_id)
JOIN model.team ht ON ht.team_id = m.home_team_id
JOIN model.team at ON at.team_id = m.away_team_id
GROUP BY m.match_id, ht.team_name, at.team_name
ORDER BY m.match_id;
COMMENT ON VIEW analysis.shootout IS 'How did each penalty shootout go, kick by kick totals (saved vs missed)?';
