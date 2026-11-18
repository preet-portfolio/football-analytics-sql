-- Figures derived from the model must equal what was published.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap;
SELECT plan(4);

-- Goals per match from the model, using the same rules as the raw-level audit view
-- but through typed tables: shots with outcome Goal plus 'Own Goal For' events
-- (event_type_id 25), excluding the penalty shootout (period 5).
CREATE TEMP VIEW model_goals AS
SELECT m.match_id,
       count(*) FILTER (WHERE e.team_id = m.home_team_id) AS home_goals,
       count(*) FILTER (WHERE e.team_id = m.away_team_id) AS away_goals
FROM model.match m
LEFT JOIN model.event e ON e.match_id = m.match_id AND e.period < 5
     AND (e.event_type_id = 25 OR EXISTS (SELECT 1 FROM model.shot s WHERE s.event_id = e.event_id AND s.is_goal))
GROUP BY m.match_id;

SELECT is_empty($$
    SELECT m.match_id, m.home_score, m.away_score, g.home_goals, g.away_goals
    FROM model.match m JOIN model_goals g USING (match_id)
    WHERE (m.home_score, m.away_score) <> (g.home_goals, g.away_goals)
$$, 'model goals equal the published score of every match');

SELECT is_empty($$
    SELECT a.match_id FROM audit.score_reconciliation a JOIN model_goals g USING (match_id)
    WHERE (a.ev_home, a.ev_away) <> (g.home_goals, g.away_goals)
$$, 'model goals equal the raw-level audit derivation (model loses nothing)');

-- Golden Boot, as published by FIFA: Mbappé 8, Messi 7, Álvarez 4, Giroud 4.
SELECT results_eq($$
    SELECT p.display_name, count(*)::int
    FROM model.shot s JOIN model.event e USING (event_id) JOIN model.player p USING (player_id)
    WHERE s.is_goal AND e.period < 5
    GROUP BY p.display_name HAVING count(*) >= 4
    ORDER BY count(*) DESC, p.display_name
$$, $$ VALUES ('Kylian Mbappé', 8), ('Lionel Messi', 7), ('Julián Álvarez', 4), ('Olivier Giroud', 4) $$,
'top scorers (4+ goals) match the published Golden Boot standings');

-- Final group tables as published by FIFA, ranked by points, goal difference,
-- goals scored. Positions 1-2 are the Round of 16 qualifiers.
SELECT results_eq($$
    WITH team_match AS (
        SELECT m.match_id, st.group_name, m.home_team_id AS team_id, m.home_score AS gf, m.away_score AS ga
        FROM model.match m JOIN model.season_team st
          ON st.team_id = m.home_team_id AND (st.competition_id, st.season_id) = (m.competition_id, m.season_id)
        WHERE m.stage = 'Group Stage'
        UNION ALL
        SELECT m.match_id, st.group_name, m.away_team_id, m.away_score, m.home_score
        FROM model.match m JOIN model.season_team st
          ON st.team_id = m.away_team_id AND (st.competition_id, st.season_id) = (m.competition_id, m.season_id)
        WHERE m.stage = 'Group Stage'
    ), tbl AS (
        SELECT group_name, team_id,
               sum(CASE WHEN gf > ga THEN 3 WHEN gf = ga THEN 1 ELSE 0 END)::int AS points,
               sum(gf - ga) AS gd, sum(gf) AS gf
        FROM team_match GROUP BY group_name, team_id
    )
    SELECT tbl.group_name,
           (rank() OVER (PARTITION BY tbl.group_name ORDER BY points DESC, gd DESC, gf DESC))::int AS pos,
           t.team_name, points
    FROM tbl JOIN model.team t USING (team_id)
    ORDER BY 1, 2
$$, $$ VALUES
    ('A', 1, 'Netherlands', 7), ('A', 2, 'Senegal', 6), ('A', 3, 'Ecuador', 4), ('A', 4, 'Qatar', 0),
    ('B', 1, 'England', 7), ('B', 2, 'United States', 5), ('B', 3, 'Iran', 3), ('B', 4, 'Wales', 1),
    ('C', 1, 'Argentina', 6), ('C', 2, 'Poland', 4), ('C', 3, 'Mexico', 4), ('C', 4, 'Saudi Arabia', 3),
    ('D', 1, 'France', 6), ('D', 2, 'Australia', 6), ('D', 3, 'Tunisia', 4), ('D', 4, 'Denmark', 1),
    ('E', 1, 'Japan', 6), ('E', 2, 'Spain', 4), ('E', 3, 'Germany', 4), ('E', 4, 'Costa Rica', 3),
    ('F', 1, 'Morocco', 7), ('F', 2, 'Croatia', 5), ('F', 3, 'Belgium', 4), ('F', 4, 'Canada', 0),
    ('G', 1, 'Brazil', 6), ('G', 2, 'Switzerland', 6), ('G', 3, 'Cameroon', 4), ('G', 4, 'Serbia', 1),
    ('H', 1, 'Portugal', 6), ('H', 2, 'South Korea', 4), ('H', 3, 'Uruguay', 4), ('H', 4, 'Ghana', 3)
$$, 'derived group tables equal the published final standings, including tie-breaks');

SELECT * FROM finish();
ROLLBACK;
