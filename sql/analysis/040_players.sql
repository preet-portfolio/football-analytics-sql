-- Analysis: player output per 90 minutes, using event-derived minutes.

-- ----------------------------------------------------------- 12 per 90
-- Progressive pass: a completed open-play pass that moves the ball at least 25%
-- closer to the centre of the opponent's goal. xA: the xG of the shots a player's
-- passes created (non-penalty). Per-90 rates use model.appearance seconds,
-- stoppage time included; minimum 270 minutes.
CREATE VIEW analysis.player_per90 AS
WITH minutes AS (
    SELECT player_id, sum(seconds_played) / 60.0 AS minutes, count(*) AS apps
    FROM model.appearance GROUP BY player_id
), actions AS (
    SELECT e.player_id,
           count(*) FILTER (WHERE et.event_type_name = 'Pressure')                        AS pressures,
           count(*) FILTER (WHERE et.event_type_name = 'Pressure' AND e.counterpress)     AS counterpresses,
           count(*) FILTER (WHERE et.event_type_name = 'Interception'
                               OR (et.event_type_name = 'Duel' AND d.duel_type = 'Tackle')) AS tackles_interceptions,
           count(*) FILTER (WHERE p.is_complete AND (p.pass_type IS NULL OR p.pass_type IN ('Recovery', 'Interception'))
                              AND sqrt((120 - p.end_x) ^ 2 + (40 - p.end_y) ^ 2)
                                  <= 0.75 * sqrt((120 - e.location_x) ^ 2 + (40 - e.location_y) ^ 2)) AS progressive_passes,
           coalesce(sum(sa.xg) FILTER (WHERE sa.shot_type <> 'Penalty'), 0)                AS xa,
           count(*) FILTER (WHERE p.is_goal_assist)                                        AS assists
    FROM model.event e
    JOIN model.event_type et USING (event_type_id)
    LEFT JOIN model.duel d USING (event_id)
    LEFT JOIN model.pass p USING (event_id)
    LEFT JOIN model.shot sa ON sa.event_id = p.assisted_shot_id
    WHERE e.period < 5 AND e.player_id IS NOT NULL
    GROUP BY e.player_id
), shooting AS (
    SELECT player_id, count(*) FILTER (WHERE NOT is_penalty) AS np_shots,
           count(*) FILTER (WHERE is_goal AND NOT is_penalty) AS np_goals,
           sum(xg) FILTER (WHERE NOT is_penalty) AS np_xg
    FROM analysis.shot_detail GROUP BY player_id
)
SELECT p.display_name AS player,
       (SELECT t.team_name FROM model.lineup l JOIN model.team t USING (team_id) WHERE l.player_id = p.player_id LIMIT 1) AS team,
       round(m.minutes)::int AS minutes,
       coalesce(sh.np_goals, 0)::int AS np_goals,
       a.assists::int,
       round(90 * coalesce(sh.np_xg, 0) / m.minutes, 2)        AS np_xg_p90,
       round(90 * a.xa / m.minutes, 2)                         AS xa_p90,
       round(90 * a.progressive_passes / m.minutes, 1)         AS prog_passes_p90,
       round(90 * a.pressures / m.minutes, 1)                  AS pressures_p90,
       round(90 * a.counterpresses / m.minutes, 1)             AS counterpresses_p90,
       round(90 * a.tackles_interceptions / m.minutes, 1)      AS tackles_ints_p90
FROM minutes m
JOIN model.player p USING (player_id)
JOIN actions a USING (player_id)
LEFT JOIN shooting sh USING (player_id)
WHERE m.minutes >= 270
ORDER BY (coalesce(sh.np_xg, 0) + a.xa) / m.minutes DESC;
COMMENT ON VIEW analysis.player_per90 IS 'Who contributed most per 90 minutes (270+ minutes): chances, creation, progression, pressing?';

-- ----------------------------------------------------- 13 substitutes
CREATE VIEW analysis.substitute_impact AS
SELECT t.team_name AS team,
       count(*) FILTER (WHERE NOT a.is_starter)::int                         AS subs_used,
       round(sum(a.seconds_played) FILTER (WHERE NOT a.is_starter) / 60.0)::int AS sub_minutes,
       coalesce(sum(g.goals) FILTER (WHERE NOT a.is_starter), 0)::int        AS goals_by_subs,
       coalesce(sum(g.goals), 0)::int                                        AS goals_total,
       round(100.0 * coalesce(sum(g.goals) FILTER (WHERE NOT a.is_starter), 0) / nullif(sum(g.goals), 0))::int AS pct_goals_by_subs
FROM model.appearance a
JOIN model.team t USING (team_id)
-- goals pre-aggregated per player-match so a brace cannot duplicate the appearance row
LEFT JOIN (SELECT match_id, player_id, count(*) AS goals FROM analysis.goal
           WHERE NOT is_own_goal GROUP BY match_id, player_id) g
       ON g.match_id = a.match_id AND g.player_id = a.player_id
GROUP BY t.team_name
ORDER BY goals_by_subs DESC, pct_goals_by_subs DESC NULLS LAST;
COMMENT ON VIEW analysis.substitute_impact IS 'How much did each team''s bench contribute (goals scored by substitutes)?';

-- ---------------------------------------------------- helper for the status page
-- Returns the first n rows of an analysis view as JSON (identifier-quoted with %I).
CREATE FUNCTION analysis.view_rows(view_name text, n int) RETURNS json
LANGUAGE plpgsql STABLE AS $$
DECLARE result json;
BEGIN
    EXECUTE format('SELECT coalesce(json_agg(t), ''[]''::json) FROM (SELECT * FROM analysis.%I LIMIT %s) t', view_name, n)
    INTO result;
    RETURN result;
END $$;
