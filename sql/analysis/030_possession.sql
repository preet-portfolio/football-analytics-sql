-- Analysis: possession, pressing and passing structure.

-- --------------------------------------------------------------- 8 PPDA
-- Passes allowed per defensive action: opponent passes in their own 60% of the
-- pitch divided by our defensive actions (tackles, interceptions, fouls,
-- challenges) in that same zone. Lower = more intense pressing. Event coordinates
-- are oriented for the acting team, so the opponent's own 60% is their x < 72 and
-- our defensive actions there are at our x >= 48.
CREATE VIEW analysis.team_ppda AS
WITH opp AS (
    SELECT match_id, home_team_id AS team_id, away_team_id AS opp_id FROM model.match
    UNION ALL SELECT match_id, away_team_id, home_team_id FROM model.match
), opp_passes AS (
    SELECT o.team_id, count(*) AS passes
    FROM opp o
    JOIN model.event e ON e.match_id = o.match_id AND e.team_id = o.opp_id AND e.period < 5
    JOIN model.pass p USING (event_id)
    WHERE e.location_x < 72 AND (p.pass_type IS NULL OR p.pass_type IN ('Recovery', 'Interception'))
    GROUP BY o.team_id
), def_actions AS (
    SELECT e.team_id, count(*) AS actions
    FROM model.event e
    JOIN model.event_type et USING (event_type_id)
    LEFT JOIN model.duel d USING (event_id)
    WHERE e.period < 5 AND e.location_x >= 48
      AND (et.event_type_name IN ('Interception', 'Foul Committed', 'Dribbled Past')
           OR d.duel_type = 'Tackle')
    GROUP BY e.team_id
), pressures AS (
    SELECT e.team_id, count(*) AS pressures,
           count(*) FILTER (WHERE e.location_x >= 80) AS final_third_pressures
    FROM model.event e JOIN model.event_type et USING (event_type_id)
    WHERE et.event_type_name = 'Pressure' AND e.period < 5
    GROUP BY e.team_id
)
SELECT t.team_name AS team, op.passes::int AS opp_passes_own_60pct, da.actions::int AS def_actions,
       round(op.passes::numeric / da.actions, 2) AS ppda,
       pr.pressures::int,
       round(100.0 * pr.final_third_pressures / pr.pressures, 1) AS pct_pressures_final_third
FROM model.team t
JOIN opp_passes op USING (team_id)
JOIN def_actions da USING (team_id)
JOIN pressures pr USING (team_id)
ORDER BY ppda;
COMMENT ON VIEW analysis.team_ppda IS 'Who pressed hardest? Passes allowed per defensive action (PPDA, lower = more pressing).';

-- --------------------------------------------------- 9 possession outcomes
-- Techniques: one row per possession built with aggregate FILTERs, then team
-- averages. A possession is StatsBomb's sequence number per match.
CREATE VIEW analysis.team_possession AS
WITH poss AS (
    SELECT e.match_id, e.possession, e.possession_team_id AS team_id,
           count(*) FILTER (WHERE et.event_type_name = 'Pass' AND e.team_id = e.possession_team_id) AS passes,
           bool_or(s.event_id IS NOT NULL AND e.team_id = e.possession_team_id)                      AS ended_in_shot,
           coalesce(sum(s.xg) FILTER (WHERE e.team_id = e.possession_team_id), 0)                    AS xg
    FROM model.event e
    JOIN model.event_type et USING (event_type_id)
    LEFT JOIN model.shot s USING (event_id)
    WHERE e.period < 5
    GROUP BY e.match_id, e.possession, e.possession_team_id
), poss_time AS (
    -- period_clock restarts every period and 74 possessions straddle half-time,
    -- so duration is measured within each period and summed
    SELECT match_id, possession, sum(secs) AS seconds
    FROM (SELECT match_id, possession, period, extract(epoch FROM max(period_clock) - min(period_clock)) AS secs
          FROM model.event WHERE period < 5 GROUP BY match_id, possession, period) x
    GROUP BY match_id, possession
)
SELECT t.team_name AS team,
       count(*)::int AS possessions,
       round(avg(passes), 1)                                            AS passes_per_possession,
       round(100.0 * count(*) FILTER (WHERE passes >= 10) / count(*), 1) AS pct_10plus_pass_moves,
       round(100.0 * count(*) FILTER (WHERE ended_in_shot) / count(*), 1) AS pct_ending_in_shot,
       round(1000 * avg(xg), 1)                                          AS xg_per_1000_possessions,
       round(avg(seconds), 1)                                            AS avg_seconds
FROM poss JOIN poss_time USING (match_id, possession) JOIN model.team t USING (team_id)
GROUP BY t.team_name
ORDER BY passes_per_possession DESC;
COMMENT ON VIEW analysis.team_possession IS 'How did teams use the ball: pass length of possessions, how often they led to a shot, xG per possession?';

-- ------------------------------------------------------ 10 high turnovers
-- A high turnover: we win the ball from the opponent in open play within 40 m
-- (43.7 yd) of their goal. Operationally: the first event of one of our
-- possessions is ours, at x >= 76.26, the previous possession was the opponent's,
-- and that first action is on an allow-list of ball-winning / open-play actions
-- (so no drop-balls, set-piece passes or set-piece shots). StatsBomb's play_pattern
-- can't be used: a regain soon after an opponent's throw-in still says 'From Throw In'.
-- Techniques: DISTINCT ON for the first event of each possession, LAG() for the
-- previous possession's team, LATERAL for the first shot of the possession.
CREATE VIEW analysis.high_turnover AS
WITH first_event AS (
    SELECT DISTINCT ON (e.match_id, e.possession)
           e.match_id, e.possession, e.possession_team_id, e.event_id, e.event_type_id,
           e.period, e.period_clock, e.location_x
    FROM model.event e
    WHERE e.period < 5 AND e.location_x IS NOT NULL AND e.team_id = e.possession_team_id
    ORDER BY e.match_id, e.possession, e.event_index
), seq AS (
    SELECT f.*, LAG(f.possession_team_id) OVER (PARTITION BY f.match_id ORDER BY f.possession) AS prev_team
    FROM first_event f
)
SELECT s.match_id, s.possession, s.possession_team_id AS team_id, s.event_id,
       et.event_type_name AS first_action, s.period, s.period_clock, s.location_x
FROM seq s
JOIN model.event_type et USING (event_type_id)
LEFT JOIN model.pass p USING (event_id)
WHERE s.prev_team <> s.possession_team_id
  AND s.location_x >= 120 - 43.74
  AND et.event_type_name IN ('Ball Recovery', 'Interception', 'Duel', 'Pass', 'Carry', 'Dribble', 'Ball Receipt*')
  AND (p.event_id IS NULL OR p.pass_type IS NULL OR p.pass_type IN ('Recovery', 'Interception'));
COMMENT ON VIEW analysis.high_turnover IS 'Helper: one row per high turnover (ball won in open play within 40 m of the opponent''s goal).';

CREATE VIEW analysis.team_high_turnovers AS
SELECT t.team_name AS team,
       mp.matches::int AS matches,
       count(*)::int AS high_turnovers,
       round(count(*)::numeric / mp.matches, 1) AS per_match,
       count(sh.event_id)::int AS led_to_shot,
       count(sh.event_id) FILTER (WHERE sh.secs <= 15)::int AS shot_within_15s,
       count(sh.event_id) FILTER (WHERE sh.is_goal)::int AS led_to_goal,
       round(coalesce(sum(sh.xg), 0), 2) AS xg_from_high_turnovers
FROM analysis.high_turnover tv
JOIN model.team t ON t.team_id = tv.team_id
JOIN (SELECT team_id, count(*) AS matches FROM (
        SELECT home_team_id AS team_id FROM model.match UNION ALL SELECT away_team_id FROM model.match) x
      GROUP BY team_id) mp ON mp.team_id = t.team_id
LEFT JOIN LATERAL (
    SELECT e.event_id, s.xg, s.is_goal, extract(epoch FROM e.period_clock - tv.period_clock) AS secs
    FROM model.event e JOIN model.shot s USING (event_id)
    WHERE e.match_id = tv.match_id AND e.possession = tv.possession AND e.team_id = tv.team_id
    ORDER BY e.event_index LIMIT 1
) sh ON true
GROUP BY t.team_name, mp.matches
ORDER BY per_match DESC;
COMMENT ON VIEW analysis.team_high_turnovers IS 'Which teams won the ball high (within 40 m of goal) and turned it into shots?';

-- -------------------------------------------------------- 11 pass network
-- Completed passes between teammates before the team's first substitution, with
-- each player's single average position (all their on-ball events before the
-- cut-off), which places them on the network diagram.
-- A MATERIALIZED view with an index on match_id: computing it takes about 1 s
-- (its CTEs are referenced twice, so PostgreSQL computes them for every match
-- before a match_id filter applies; inlining them makes one match fast but the
-- whole set 14 s). The data is static between builds, so it is computed once
-- per build and each match is then an index lookup. docs/perf/README.md has the plans.
CREATE MATERIALIZED VIEW analysis.pass_network AS
WITH team_side AS (
    SELECT match_id, home_team_id AS team_id FROM model.match
    UNION ALL SELECT match_id, away_team_id FROM model.match
), cutoff AS (
    SELECT ts.match_id, ts.team_id,
           coalesce(fs.period, 9) AS sub_period, coalesce(fs.period_clock, interval '0') AS sub_clock
    FROM team_side ts
    LEFT JOIN LATERAL (
        SELECT e.period, e.period_clock FROM model.event e JOIN model.substitution USING (event_id)
        WHERE e.match_id = ts.match_id AND e.team_id = ts.team_id
        ORDER BY e.period, e.period_clock LIMIT 1
    ) fs ON true
), before_cutoff AS (
    SELECT e.*, p.recipient_id, p.is_complete
    FROM model.event e
    JOIN cutoff c ON c.match_id = e.match_id AND c.team_id = e.team_id
    LEFT JOIN model.pass p USING (event_id)
    WHERE e.period < 5 AND (e.period, e.period_clock) < (c.sub_period, c.sub_clock)
), player_position AS (
    -- one average position per player: all their located on-ball events before the cut-off
    SELECT match_id, player_id, round(avg(location_x), 1) AS avg_x, round(avg(location_y), 1) AS avg_y
    FROM before_cutoff WHERE location_x IS NOT NULL AND player_id IS NOT NULL
    GROUP BY match_id, player_id
)
SELECT b.match_id, b.team_id, b.player_id AS passer_id, b.recipient_id,
       count(*)::int AS passes,
       pp.avg_x AS passer_avg_x, pp.avg_y AS passer_avg_y,
       rp.avg_x AS recipient_avg_x, rp.avg_y AS recipient_avg_y
FROM before_cutoff b
JOIN player_position pp ON pp.match_id = b.match_id AND pp.player_id = b.player_id
LEFT JOIN player_position rp ON rp.match_id = b.match_id AND rp.player_id = b.recipient_id
WHERE b.is_complete AND b.recipient_id IS NOT NULL
GROUP BY b.match_id, b.team_id, b.player_id, b.recipient_id, pp.avg_x, pp.avg_y, rp.avg_x, rp.avg_y;
CREATE INDEX pass_network_match_idx ON analysis.pass_network (match_id, team_id);
COMMENT ON MATERIALIZED VIEW analysis.pass_network IS 'Who passed to whom, and where, before each team''s first substitution? (one row per passer-recipient pair per match)';

-- Readable top links of the final, for the status page.
CREATE VIEW analysis.final_pass_network AS
SELECT t.team_name AS team, pa.display_name AS passer, re.display_name AS recipient, pn.passes,
       pn.passer_avg_x, pn.passer_avg_y
FROM analysis.pass_network pn
JOIN model.match m USING (match_id)
JOIN model.team t USING (team_id)
JOIN model.player pa ON pa.player_id = pn.passer_id
JOIN model.player re ON re.player_id = pn.recipient_id
WHERE m.stage = 'Final' AND pn.passes >= 8
ORDER BY pn.passes DESC;
COMMENT ON VIEW analysis.final_pass_network IS 'The strongest passing links in the final (8+ completed passes before the first substitution).';
