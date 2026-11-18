-- Analysis: shooting, chance quality and goalkeeping.

-- Helper: shots in play (no shootout kicks) with distance and angle to goal.
-- Goal mouth: posts at (120, 36) and (120, 44). The angle is the visible goal
-- width from the shot location, a standard xG feature. It is rounded to 6
-- decimals because atan2() differs in the last binary digit between C maths
-- libraries: unrounded, Postgres on Linux and PGlite in the browser disagree on
-- 31 of 1,453 shots in the 15th significant digit (caught by playground/test.mjs).
CREATE VIEW analysis.shot_detail AS
SELECT s.event_id, e.match_id, e.team_id, e.player_id, s.xg, s.is_goal, s.outcome, s.shot_type, s.body_part,
       (s.shot_type = 'Penalty') AS is_penalty,
       s.outcome IN ('Goal', 'Saved', 'Saved to Post') AS on_target,
       sqrt((120 - e.location_x) ^ 2 + (40 - e.location_y) ^ 2) AS distance,
       round(degrees(abs(atan2(44 - e.location_y, 120 - e.location_x)
                         - atan2(36 - e.location_y, 120 - e.location_x)))::numeric, 6) AS angle_deg
FROM model.shot s JOIN model.event e USING (event_id)
WHERE e.period < 5;
COMMENT ON VIEW analysis.shot_detail IS 'Helper: every in-play shot with its distance (yards) and visible goal angle.';

-- ----------------------------------------------------------- 4 team xG
-- Techniques: each measure aggregated once in its own CTE, then joined at the
-- team grain. (The first version used a correlated subquery per team that
-- rescanned the goals 32 times: 8x slower; docs/perf/README.md has both plans.)
CREATE VIEW analysis.team_xg AS
WITH opp AS (
    SELECT match_id, home_team_id AS team_id, away_team_id AS opp_id FROM model.match
    UNION ALL SELECT match_id, away_team_id, home_team_id FROM model.match
), played AS (
    SELECT team_id, count(*) AS matches FROM opp GROUP BY team_id
), scored AS (
    SELECT team_id, count(*) AS goals FROM analysis.goal GROUP BY team_id
), conceded AS (
    SELECT o.team_id, count(*) AS goals_against
    FROM analysis.goal g JOIN opp o ON o.match_id = g.match_id AND o.opp_id = g.team_id
    GROUP BY o.team_id
), shots_for AS (
    SELECT team_id, count(*) AS shots, sum(xg) AS xg,
           sum(xg) FILTER (WHERE NOT is_penalty) AS np_xg,
           count(*) FILTER (WHERE is_goal AND NOT is_penalty) AS np_goals
    FROM analysis.shot_detail GROUP BY team_id
), shots_against AS (
    SELECT o.team_id, sum(sd.xg) AS xg_against
    FROM analysis.shot_detail sd JOIN opp o ON o.match_id = sd.match_id AND o.opp_id = sd.team_id
    GROUP BY o.team_id
)
SELECT t.team_name AS team, p.matches::int,
       coalesce(sc.goals, 0)::int AS goals, sf.shots::int,
       round(sf.xg, 2) AS xg, round(sf.np_xg, 2) AS np_xg, sf.np_goals::int,
       round(sa.xg_against, 2) AS xg_against, coalesce(c.goals_against, 0)::int AS goals_against,
       round(sf.np_goals - sf.np_xg, 2) AS np_goals_minus_xg
FROM model.team t
JOIN played p USING (team_id)
JOIN shots_for sf USING (team_id)
JOIN shots_against sa USING (team_id)
LEFT JOIN scored sc USING (team_id)
LEFT JOIN conceded c USING (team_id)
ORDER BY xg DESC;
COMMENT ON VIEW analysis.team_xg IS 'Which teams created the best chances (xG) and which finished above or below them?';

-- ---------------------------------------------------- 5 player finishing
CREATE VIEW analysis.player_finishing AS
SELECT p.display_name AS player, t.team_name AS team,
       count(*)::int                                           AS np_shots,
       count(*) FILTER (WHERE sd.is_goal)::int                 AS np_goals,
       round(sum(sd.xg), 2)                                    AS np_xg,
       round(count(*) FILTER (WHERE sd.is_goal) - sum(sd.xg), 2) AS goals_minus_xg,
       round(sum(sd.xg) / count(*), 3)                         AS xg_per_shot,
       round(avg(sd.distance), 1)                              AS avg_distance
FROM analysis.shot_detail sd
JOIN model.player p USING (player_id)
JOIN model.team t ON t.team_id = sd.team_id
WHERE NOT sd.is_penalty
GROUP BY p.display_name, t.team_name
HAVING count(*) >= 8
ORDER BY goals_minus_xg DESC;
COMMENT ON VIEW analysis.player_finishing IS 'Which players (8+ non-penalty shots) scored more or fewer than their chances were worth?';

-- ------------------------------------------------------- 6 shot zones
-- Techniques: WIDTH_BUCKET binning; conversion vs mean xG per bin shows how well
-- the xG model is calibrated on this tournament.
CREATE VIEW analysis.shot_zones AS
SELECT width_bucket(distance, 0, 36, 6) AS bin,
       CASE WHEN distance >= 36 THEN '36+ yards'
            ELSE (6 * (width_bucket(distance, 0, 36, 6) - 1))::text || '-' || (6 * width_bucket(distance, 0, 36, 6))::text || ' yards' END AS distance,
       count(*)::int AS shots,
       count(*) FILTER (WHERE is_goal)::int AS goals,
       round(100.0 * count(*) FILTER (WHERE is_goal) / count(*), 1) AS conversion_pct,
       round(100 * avg(xg), 1)                                     AS mean_xg_pct,
       round(avg(angle_deg), 1)                                    AS mean_angle_deg,
       round(100.0 * count(*) FILTER (WHERE body_part = 'Head') / count(*))::int AS headers_pct
FROM analysis.shot_detail
WHERE NOT is_penalty
GROUP BY 1, 2
ORDER BY 1;
COMMENT ON VIEW analysis.shot_zones IS 'How does conversion fall with distance, and does StatsBomb xG track it (non-penalty shots)?';

-- -------------------------------------------------------- 7 goalkeepers
-- StatsBomb open data has no post-shot xG. Comparing goals with the pre-shot xG
-- of on-target shots only is biased: a shot being on target makes a goal likelier
-- than its pre-shot xG says, so nearly every keeper would look below average.
-- Goals prevented therefore uses the xG of ALL shots faced (excluding own goals),
-- which is unbiased but also credits the defence for forcing misses.
-- Keepers are identified by goalkeeper actions OR a Goalkeeper lineup position:
-- StatsBomb lists Daniel Ward (on in goal for Wales v Iran) as a midfielder.
CREATE VIEW analysis.goalkeeper_match AS
WITH keeper_spell AS (
    SELECT a.match_id, a.team_id, a.player_id, a.on_period, a.on_clock, a.off_period, a.off_clock, a.seconds_played
    FROM model.appearance a
    WHERE EXISTS (SELECT 1 FROM model.event e JOIN model.goalkeeper_action USING (event_id)
                  WHERE e.match_id = a.match_id AND e.player_id = a.player_id)
       OR EXISTS (SELECT 1 FROM model.lineup_stint ls JOIN model.position po USING (position_id)
                  WHERE ls.match_id = a.match_id AND ls.player_id = a.player_id AND po.position_name = 'Goalkeeper')
), faced AS (
    SELECT ks.match_id, ks.player_id, sd.xg, sd.is_goal, sd.on_target
    FROM keeper_spell ks
    JOIN model.event e ON e.match_id = ks.match_id AND e.team_id <> ks.team_id
     AND (e.period, e.period_clock) >= (ks.on_period, ks.on_clock)
     AND (e.period, e.period_clock) <  (ks.off_period, ks.off_clock)
    JOIN analysis.shot_detail sd USING (event_id)
)
SELECT ks.match_id, ks.team_id, ks.player_id, ks.seconds_played,
       count(f.player_id)::int                          AS shots_faced,
       count(f.player_id) FILTER (WHERE f.on_target)::int AS on_target,
       count(f.player_id) FILTER (WHERE f.is_goal)::int   AS goals,
       coalesce(sum(f.xg), 0)                           AS xg_faced
FROM keeper_spell ks
LEFT JOIN faced f USING (match_id, player_id)
GROUP BY ks.match_id, ks.team_id, ks.player_id, ks.seconds_played;
COMMENT ON VIEW analysis.goalkeeper_match IS 'Helper: one row per goalkeeper per match, with the shots faced while on the pitch.';

CREATE VIEW analysis.goalkeeper AS
SELECT p.display_name AS keeper, t.team_name AS team,
       round(sum(gm.seconds_played) / 60.0)::int AS minutes,
       sum(gm.on_target)::int AS on_target_faced,
       sum(gm.goals)::int     AS goals_conceded,
       sum(gm.on_target - gm.goals)::int AS saves,
       round(100.0 * sum(gm.on_target - gm.goals) / nullif(sum(gm.on_target), 0), 1) AS save_pct,
       round(sum(gm.xg_faced), 2) AS xg_faced,
       round(sum(gm.xg_faced) - sum(gm.goals), 2) AS goals_prevented
FROM analysis.goalkeeper_match gm
JOIN model.player p USING (player_id)
JOIN model.team t USING (team_id)
GROUP BY p.display_name, t.team_name
HAVING sum(gm.seconds_played) >= 180 * 60
ORDER BY goals_prevented DESC;
COMMENT ON VIEW analysis.goalkeeper IS 'Which goalkeepers (180+ minutes) conceded fewer goals than the xG of the shots they faced?';
