-- Analysis views agree with published facts and with the arithmetic of the game.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap;
SELECT plan(14);

SELECT results_eq($$ SELECT "group", pos, team, pts FROM analysis.group_table $$,
$$ VALUES
    ('A', 1, 'Netherlands', 7), ('A', 2, 'Senegal', 6), ('A', 3, 'Ecuador', 4), ('A', 4, 'Qatar', 0),
    ('B', 1, 'England', 7), ('B', 2, 'United States', 5), ('B', 3, 'Iran', 3), ('B', 4, 'Wales', 1),
    ('C', 1, 'Argentina', 6), ('C', 2, 'Poland', 4), ('C', 3, 'Mexico', 4), ('C', 4, 'Saudi Arabia', 3),
    ('D', 1, 'France', 6), ('D', 2, 'Australia', 6), ('D', 3, 'Tunisia', 4), ('D', 4, 'Denmark', 1),
    ('E', 1, 'Japan', 6), ('E', 2, 'Spain', 4), ('E', 3, 'Germany', 4), ('E', 4, 'Costa Rica', 3),
    ('F', 1, 'Morocco', 7), ('F', 2, 'Croatia', 5), ('F', 3, 'Belgium', 4), ('F', 4, 'Canada', 0),
    ('G', 1, 'Brazil', 6), ('G', 2, 'Switzerland', 6), ('G', 3, 'Cameroon', 4), ('G', 4, 'Serbia', 1),
    ('H', 1, 'Portugal', 6), ('H', 2, 'South Korea', 4), ('H', 3, 'Uruguay', 4), ('H', 4, 'Ghana', 3)
$$, 'analysis.group_table equals the published final group standings');

-- Published: five players tied on 3 assists (Messi, Griezmann, Kane, Bruno Fernandes, Perišić).
SELECT results_eq($$ SELECT player, assists FROM analysis.player_per90 WHERE assists >= 3 ORDER BY player $$,
$$ VALUES ('Antoine Griezmann', 3), ('Bruno Fernandes', 3), ('Harry Kane', 3), ('Ivan Perišić', 3), ('Lionel Messi', 3) $$,
'assist leaders equal the published list (five players on 3)');

SELECT results_eq($$ SELECT sum(goals)::int, sum(goals_against)::int FROM analysis.team_xg $$,
                  $$ VALUES (172, 172) $$,
                  'team_xg: goals for and against both total the 172 tournament goals');

SELECT results_eq($$
    SELECT home, home_scored::int, away, away_scored::int FROM analysis.shootout ORDER BY match_id $$,
$$ SELECT home_team, of_pen_home, away_team, of_pen_away FROM audit.score_reconciliation
   WHERE of_pen_home IS NOT NULL ORDER BY match_id $$,
'shootout view equals the independent openfootball shootout results');

-- Game state arithmetic: the segments of each team-match tile the whole match,
-- and one side's leading time is exactly the other side's trailing time.
SELECT is_empty($$
    WITH side AS (
        SELECT match_id, home_team_id AS team_id FROM model.match
        UNION ALL SELECT match_id, away_team_id FROM model.match
    ), covered AS (
        SELECT match_id, team_id, sum(to_clock - from_clock) AS covered
        FROM analysis.game_state_segment GROUP BY match_id, team_id
    ), length AS (
        SELECT match_id, sum(duration) AS match_length FROM model.match_period GROUP BY match_id
    )
    SELECT s.match_id, s.team_id, c.covered, l.match_length
    FROM side s LEFT JOIN covered c USING (match_id, team_id) LEFT JOIN length l USING (match_id)
    WHERE c.covered IS DISTINCT FROM l.match_length
$$, 'game-state segments cover every second of all 128 team-matches exactly once');

SELECT is_empty($$
    WITH t AS (
        SELECT match_id, team_id,
               sum(to_clock - from_clock) FILTER (WHERE goals_for > goals_against) AS leading,
               sum(to_clock - from_clock) FILTER (WHERE goals_for < goals_against) AS trailing
        FROM analysis.game_state_segment GROUP BY match_id, team_id)
    SELECT a.match_id FROM t a JOIN t b ON a.match_id = b.match_id AND a.team_id <> b.team_id
    WHERE a.leading IS DISTINCT FROM b.trailing
$$, 'one team''s time leading equals the other team''s time trailing, in every match');

SELECT is_empty($$
    WITH last_segment AS (
        SELECT DISTINCT ON (match_id, team_id) match_id, team_id, goals_for, goals_against
        FROM analysis.game_state_segment
        ORDER BY match_id, team_id, period DESC, from_clock DESC
    ), final_score AS (
        SELECT match_id, home_team_id AS team_id, home_score AS gf, away_score AS ga FROM model.match
        UNION ALL SELECT match_id, away_team_id, away_score, home_score FROM model.match
    )
    SELECT l.*, f.gf, f.ga FROM last_segment l JOIN final_score f USING (match_id, team_id)
    WHERE (l.goals_for, l.goals_against) <> (f.gf, f.ga)
$$, 'the last game-state segment of every match shows the final score');

-- Published: Messi played every minute of Argentina's seven matches. seconds_played
-- is rounded per match, so allow one second of rounding per match.
SELECT cmp_ok((
    SELECT abs((SELECT sum(a.seconds_played) FROM model.appearance a JOIN model.player p USING (player_id)
                WHERE p.display_name = 'Lionel Messi')
             - (SELECT sum(extract(epoch FROM mp.duration)) FROM model.match_period mp
                JOIN model.match m USING (match_id) JOIN model.team t ON t.team_id IN (m.home_team_id, m.away_team_id)
                WHERE t.team_name = 'Argentina'))), '<=', 7::numeric,
    'Messi''s event-derived minutes equal the full length of Argentina''s 7 matches');

SELECT cmp_ok((SELECT sum(high_turnovers)::int FROM analysis.team_high_turnovers), '>', 200,
              'high-turnover detection finds hundreds of turnovers (not vacuous)');

-- Regression tests from the analysis review.
SELECT results_eq(
    $$ SELECT sum(subs_used)::int, sum(goals_total)::int FROM analysis.substitute_impact $$,
    $$ SELECT (SELECT count(*)::int FROM model.appearance WHERE NOT is_starter),
              (SELECT count(*)::int FROM analysis.goal WHERE NOT is_own_goal) $$,
    'substitute_impact counts each substitute once and each non-own goal once (no fan-out)');

SELECT is_empty($$ SELECT team, avg_seconds FROM analysis.team_possession WHERE avg_seconds >= 45 $$,
    'average possession lasts under 45 s for every team (half-time is not counted as possession time)');

SELECT results_eq(
    $$ SELECT sum(shots_faced)::int, sum(goals)::int FROM analysis.goalkeeper_match $$,
    $$ SELECT count(*)::int, count(*) FILTER (WHERE is_goal)::int FROM analysis.shot_detail $$,
    'every in-play shot is faced by exactly one goalkeeper (incl. outfielders who went in goal)');

SELECT is_empty($$
    SELECT first_action, count(*) FROM analysis.high_turnover
    WHERE first_action NOT IN ('Ball Recovery', 'Interception', 'Duel', 'Pass', 'Carry', 'Dribble', 'Ball Receipt*')
    GROUP BY first_action
$$, 'high turnovers start with a ball-winning or open-play action (no drop-balls or set pieces)');

SELECT is_empty($$
    SELECT match_id, passer_id, count(DISTINCT (passer_avg_x, passer_avg_y)) AS positions
    FROM analysis.pass_network GROUP BY match_id, passer_id HAVING count(DISTINCT (passer_avg_x, passer_avg_y)) > 1
$$, 'each player has one position per match on the pass network');

SELECT * FROM finish();
ROLLBACK;
