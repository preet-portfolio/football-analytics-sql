// Guided challenges. Each has a reference solution (the answer key the checker
// compares against), `wrong`: plausible mistakes the checker must reject, and
// `alsoCorrect`: other valid ways to answer that the checker must accept.
// playground/test.mjs proves both, so a challenge can't ship with an answer key
// that accepts the classic mistake it is teaching about.
//
// Answers never depend on how ties are broken: thresholds instead of LIMIT,
// ranking challenges keep every tied row, and LIMIT 1 challenges are checked
// to have no tie at the top (playground/test.mjs).

export const challenges = [
  {
    id: "high-scoring",
    title: "Goal fests",
    concept: "SELECT, WHERE",
    prompt:
      "Which matches had five or more goals? Return `match_id`, `home_score` and `away_score` from `model.match`.",
    hint: "Total goals is `home_score + away_score`. \"Five or more\" includes five.",
    solution: `SELECT match_id, home_score, away_score
FROM model.match
WHERE home_score + away_score >= 5;`,
    wrong: [
      `SELECT match_id, home_score, away_score FROM model.match WHERE home_score + away_score > 5;`,
      `SELECT match_id, home_score, away_score FROM model.match WHERE home_score >= 5 OR away_score >= 5;`,
    ],
  },
  {
    id: "knockout-bracket",
    title: "The knockout bracket",
    concept: "JOIN the same table twice",
    prompt:
      "List every knockout match (any `stage` other than 'Group Stage'): `stage`, home team name, away team name, `home_score`, `away_score`. Scores are after extra time; shootouts are not included.",
    hint: "`model.match` has two team ids. Join `model.team` twice, with a different alias each time.",
    solution: `SELECT m.stage, h.team_name AS home_team, a.team_name AS away_team,
       m.home_score, m.away_score
FROM model.match m
JOIN model.team h ON h.team_id = m.home_team_id
JOIN model.team a ON a.team_id = m.away_team_id
WHERE m.stage <> 'Group Stage';`,
    alsoCorrect: [
      `SELECT stage, (SELECT team_name FROM model.team WHERE team_id = home_team_id),
              (SELECT team_name FROM model.team WHERE team_id = away_team_id), home_score, away_score
       FROM model.match WHERE stage NOT LIKE 'Group%';`,
    ],
    wrong: [
      // Joined both sides to the home team.
      `SELECT m.stage, h.team_name, a.team_name, m.home_score, m.away_score FROM model.match m
       JOIN model.team h ON h.team_id = m.home_team_id JOIN model.team a ON a.team_id = m.home_team_id
       WHERE m.stage <> 'Group Stage';`,
      // Forgot the filter.
      `SELECT m.stage, h.team_name, a.team_name, m.home_score, m.away_score FROM model.match m
       JOIN model.team h ON h.team_id = m.home_team_id JOIN model.team a ON a.team_id = m.away_team_id;`,
    ],
  },
  {
    id: "goals-by-stage",
    title: "Goals by round",
    concept: "GROUP BY",
    prompt:
      "How many goals were scored in each `stage`? Return `stage`, the number of matches, and the total goals.",
    hint: "`count(*)` counts matches. Goals need `sum(...)` of both scores.",
    solution: `SELECT stage, count(*) AS matches, sum(home_score + away_score) AS goals
FROM model.match
GROUP BY stage;`,
    alsoCorrect: [
      `SELECT stage, count(match_id), sum(home_score) + sum(away_score) FROM model.match GROUP BY 1 ORDER BY 3 DESC;`,
    ],
    wrong: [
      `SELECT stage, count(*), count(*) FROM model.match GROUP BY stage;`,
      // Integers must be exact: no credit for "close".
      `SELECT stage, count(*), sum(home_score + away_score) + 0.4 FROM model.match GROUP BY stage;`,
      `SELECT stage, count(*), sum(home_score) FROM model.match GROUP BY stage;`,
    ],
  },
  {
    id: "top-scorers",
    title: "Golden Boot race",
    concept: "JOIN, GROUP BY, HAVING",
    prompt:
      "Which players scored at least 3 goals? Return the player's `display_name` and their goals. Count shots with `is_goal` from `model.shot`, and leave out the penalty shootout (`period` 5 in `model.event`). Own goals are not shots, so they don't count.",
    hint: "`model.shot.event_id` joins to `model.event`, which has `player_id` and `period`. Filter rows with WHERE, filter groups with HAVING.",
    solution: `SELECT p.display_name, count(*) AS goals
FROM model.shot s
JOIN model.event e ON e.event_id = s.event_id
JOIN model.player p ON p.player_id = e.player_id
WHERE s.is_goal AND e.period < 5
GROUP BY p.player_id, p.display_name
HAVING count(*) >= 3;`,
    wrong: [
      // Shootout kicks counted as goals.
      `SELECT p.display_name, count(*) FROM model.shot s JOIN model.event e ON e.event_id = s.event_id
       JOIN model.player p ON p.player_id = e.player_id WHERE s.is_goal
       GROUP BY p.player_id, p.display_name HAVING count(*) >= 3;`,
      `SELECT p.display_name, count(*) FROM model.shot s JOIN model.event e ON e.event_id = s.event_id
       JOIN model.player p ON p.player_id = e.player_id WHERE s.is_goal AND e.period < 5
       GROUP BY p.player_id, p.display_name HAVING count(*) > 3;`,
    ],
  },
  {
    id: "null-means-complete",
    title: "When NULL means success",
    concept: "NULL semantics, FILTER",
    prompt:
      "For each team, how many passes did it attempt, how many were completed, and what was its completion rate in percent (one decimal)? Return `team_name`, attempts, completions, rate. StatsBomb records no `outcome` for a completed pass: `outcome` is NULL when the pass found its man.",
    hint: "`count(*) FILTER (WHERE p.outcome IS NULL)`. Comparing with `= NULL` is never true. Passes join to `model.event` for the team.",
    solution: `SELECT t.team_name,
       count(*) AS attempts,
       count(*) FILTER (WHERE p.outcome IS NULL) AS completions,
       round(100.0 * count(*) FILTER (WHERE p.outcome IS NULL) / count(*), 1) AS completion_pct
FROM model.pass p
JOIN model.event e ON e.event_id = p.event_id
JOIN model.team t ON t.team_id = e.team_id
GROUP BY t.team_name;`,
    alsoCorrect: [
      `SELECT t.team_name, count(*), count(*) FILTER (WHERE p.outcome IS NULL),
              round(100.0 * count(*) FILTER (WHERE p.outcome IS NULL) / count(*), 2)
       FROM model.pass p JOIN model.event e ON e.event_id = p.event_id JOIN model.team t ON t.team_id = e.team_id
       GROUP BY t.team_name;`,
      `SELECT t.team_name, count(*), sum(CASE WHEN p.outcome IS NULL THEN 1 ELSE 0 END),
              100 * avg((p.outcome IS NULL)::int::float)
       FROM model.pass p JOIN model.event e ON e.event_id = p.event_id JOIN model.team t ON t.team_id = e.team_id
       GROUP BY t.team_name;`,
    ],
    wrong: [
      // Rate off by a rounding step.
      `SELECT t.team_name, count(*), count(*) FILTER (WHERE p.outcome IS NULL),
              round(100.0 * count(*) FILTER (WHERE p.outcome IS NULL) / count(*), 1) + 0.1
       FROM model.pass p JOIN model.event e ON e.event_id = p.event_id JOIN model.team t ON t.team_id = e.team_id
       GROUP BY t.team_name;`,
      // count(outcome) counts the failures, not the successes.
      `SELECT t.team_name, count(*), count(p.outcome), round(100.0 * count(p.outcome) / count(*), 1)
       FROM model.pass p JOIN model.event e ON e.event_id = p.event_id JOIN model.team t ON t.team_id = e.team_id
       GROUP BY t.team_name;`,
      // = NULL is never true.
      `SELECT t.team_name, count(*), count(*) FILTER (WHERE p.outcome = NULL), 0
       FROM model.pass p JOIN model.event e ON e.event_id = p.event_id JOIN model.team t ON t.team_id = e.team_id
       GROUP BY t.team_name;`,
    ],
  },
  {
    id: "fan-out",
    title: "The fan-out trap",
    concept: "Grain: aggregate before you join",
    prompt:
      "For every Argentina player who took at least one shot (shootout excluded), return `display_name`, total minutes played over the tournament as whole minutes (the player's total `seconds_played` divided by 60, rounded down) and the number of shots. Minutes are in `model.appearance` (one row per player per match, `seconds_played`). Shots are one row per shot.",
    hint: "Joining appearances to shots repeats each appearance once per shot, so its minutes are summed many times. Aggregate each side to one row per player first (two CTEs), then join.",
    solution: `WITH arg AS (
  SELECT team_id FROM model.team WHERE team_name = 'Argentina'
), mins AS (
  SELECT a.player_id, sum(a.seconds_played) / 60 AS minutes
  FROM model.appearance a JOIN arg USING (team_id)
  GROUP BY a.player_id
), shots AS (
  SELECT e.player_id, count(*) AS shots
  FROM model.shot s JOIN model.event e ON e.event_id = s.event_id JOIN arg USING (team_id)
  WHERE e.period < 5
  GROUP BY e.player_id
)
SELECT p.display_name, m.minutes, s.shots
FROM shots s
JOIN mins m USING (player_id)
JOIN model.player p USING (player_id);`,
    alsoCorrect: [
      `SELECT p.display_name, floor(sum(a.seconds_played) / 60.0),
              (SELECT count(*) FROM model.shot s JOIN model.event e USING (event_id)
               WHERE e.player_id = p.player_id AND e.period < 5)
       FROM model.appearance a JOIN model.player p USING (player_id) JOIN model.team t USING (team_id)
       WHERE t.team_name = 'Argentina'
       GROUP BY p.player_id, p.display_name
       HAVING (SELECT count(*) FROM model.shot s JOIN model.event e USING (event_id)
               WHERE e.player_id = p.player_id AND e.period < 5) > 0;`,
    ],
    wrong: [
      // Rounded each match down before adding.
      `WITH arg AS (SELECT team_id FROM model.team WHERE team_name = 'Argentina'),
       mins AS (SELECT a.player_id, sum(a.seconds_played / 60) AS minutes FROM model.appearance a JOIN arg USING (team_id) GROUP BY 1),
       shots AS (SELECT e.player_id, count(*) AS shots FROM model.shot s JOIN model.event e ON e.event_id = s.event_id JOIN arg USING (team_id) WHERE e.period < 5 GROUP BY 1)
       SELECT p.display_name, m.minutes, s.shots FROM shots s JOIN mins m USING (player_id) JOIN model.player p USING (player_id);`,
      // The fan-out: minutes multiplied by shots per match.
      `SELECT p.display_name, sum(a.seconds_played) / 60, count(*)
       FROM model.appearance a
       JOIN model.event e ON e.match_id = a.match_id AND e.player_id = a.player_id AND e.period < 5
       JOIN model.shot s ON s.event_id = e.event_id
       JOIN model.player p ON p.player_id = a.player_id
       JOIN model.team t ON t.team_id = a.team_id AND t.team_name = 'Argentina'
       GROUP BY p.player_id, p.display_name;`,
    ],
  },
  {
    id: "long-matches",
    title: "Marathon matches",
    concept: "Intervals",
    prompt:
      "Which matches had more than 1 hour 50 minutes of playing time? Return `match_id` and the total playing time as an interval. Each row of `model.match_period` is one period (half or extra-time half) with its `duration`; shootouts have no row.",
    hint: "`sum()` works on intervals, and you can compare with `interval '1 hour 50 minutes'`. A condition on a sum belongs in HAVING, not WHERE.",
    solution: `SELECT match_id, sum(duration) AS played
FROM model.match_period
GROUP BY match_id
HAVING sum(duration) > interval '1 hour 50 minutes';`,
    alsoCorrect: [
      `SELECT match_id, date_trunc('second', sum(duration)) FROM model.match_period GROUP BY match_id
       HAVING extract(epoch FROM sum(duration)) > 110 * 60;`,
    ],
    wrong: [
      // Picked the extra-time matches instead of measuring time.
      `SELECT match_id, sum(duration) FROM model.match_period GROUP BY match_id HAVING count(*) > 2;`,
      `SELECT match_id, sum(duration) FROM model.match_period GROUP BY match_id HAVING sum(duration) > interval '2 hours';`,
      // Compared minutes as a number of seconds.
      `SELECT match_id, sum(duration) FROM model.match_period GROUP BY match_id
       HAVING extract(epoch FROM sum(duration)) > 110;`,
    ],
  },
  {
    id: "team-top-scorer",
    title: "Each team's top scorer",
    concept: "CTE, RANK() OVER (PARTITION BY)",
    prompt:
      "For every team that scored, who was its top scorer? Return `team_name`, `display_name` and goals. Use the same goal definition as the Golden Boot challenge (shots with `is_goal`, no shootout). When players tie, return all of them.",
    hint: "Count goals per team and player in a CTE, then `RANK() OVER (PARTITION BY team ORDER BY goals DESC)` and keep rank 1. `ROW_NUMBER()` would silently drop the tied players.",
    solution: `WITH goals AS (
  SELECT e.team_id, e.player_id, count(*) AS goals
  FROM model.shot s JOIN model.event e ON e.event_id = s.event_id
  WHERE s.is_goal AND e.period < 5
  GROUP BY e.team_id, e.player_id
), ranked AS (
  SELECT *, rank() OVER (PARTITION BY team_id ORDER BY goals DESC) AS rnk
  FROM goals
)
SELECT t.team_name, p.display_name, r.goals
FROM ranked r
JOIN model.team t USING (team_id)
JOIN model.player p USING (player_id)
WHERE r.rnk = 1;`,
    wrong: [
      `WITH goals AS (
         SELECT e.team_id, e.player_id, count(*) AS goals FROM model.shot s JOIN model.event e ON e.event_id = s.event_id
         WHERE s.is_goal AND e.period < 5 GROUP BY e.team_id, e.player_id
       ), ranked AS (SELECT *, row_number() OVER (PARTITION BY team_id ORDER BY goals DESC) AS rnk FROM goals)
       SELECT t.team_name, p.display_name, r.goals FROM ranked r JOIN model.team t USING (team_id)
       JOIN model.player p USING (player_id) WHERE r.rnk = 1;`,
    ],
  },
  {
    id: "running-total",
    title: "Argentina's road to the title",
    concept: "Window functions: running SUM, LAG",
    prompt:
      "Match by match, how did Argentina's goal tally build up? Return `match_date`, the opponent's name, goals Argentina scored in that match, their running total, and how many more or fewer goals than in the previous match (NULL for the first). Order by date.",
    hint: "Build one row per Argentina match with CASE on home/away, then `sum(goals) OVER (ORDER BY match_date)` and `goals - lag(goals) OVER (ORDER BY match_date)`.",
    orderMatters: true,
    solution: `WITH arg AS (
  SELECT team_id FROM model.team WHERE team_name = 'Argentina'
), games AS (
  SELECT m.match_date,
         CASE WHEN m.home_team_id = arg.team_id THEN m.away_team_id ELSE m.home_team_id END AS opponent_id,
         CASE WHEN m.home_team_id = arg.team_id THEN m.home_score ELSE m.away_score END AS goals
  FROM model.match m, arg
  WHERE arg.team_id IN (m.home_team_id, m.away_team_id)
)
SELECT g.match_date, t.team_name AS opponent, g.goals,
       sum(g.goals) OVER (ORDER BY g.match_date) AS running_goals,
       g.goals - lag(g.goals) OVER (ORDER BY g.match_date) AS change
FROM games g JOIN model.team t ON t.team_id = g.opponent_id
ORDER BY g.match_date;`,
    alsoCorrect: [
      // The date as a timestamp or as text is the same answer.
      `WITH arg AS (SELECT team_id FROM model.team WHERE team_name = 'Argentina'), games AS (
         SELECT m.match_date, CASE WHEN m.home_team_id = arg.team_id THEN m.away_team_id ELSE m.home_team_id END AS opponent_id,
                CASE WHEN m.home_team_id = arg.team_id THEN m.home_score ELSE m.away_score END AS goals
         FROM model.match m, arg WHERE arg.team_id IN (m.home_team_id, m.away_team_id))
       SELECT g.match_date::timestamp, t.team_name, g.goals, sum(g.goals) OVER w, g.goals - lag(g.goals) OVER w
       FROM games g JOIN model.team t ON t.team_id = g.opponent_id WINDOW w AS (ORDER BY g.match_date) ORDER BY 1;`,
    ],
    wrong: [
      // Right rows, wrong order.
      `WITH arg AS (SELECT team_id FROM model.team WHERE team_name = 'Argentina'), games AS (
         SELECT m.match_date, CASE WHEN m.home_team_id = arg.team_id THEN m.away_team_id ELSE m.home_team_id END AS opponent_id,
                CASE WHEN m.home_team_id = arg.team_id THEN m.home_score ELSE m.away_score END AS goals
         FROM model.match m, arg WHERE arg.team_id IN (m.home_team_id, m.away_team_id))
       SELECT g.match_date, t.team_name, g.goals, sum(g.goals) OVER w, g.goals - lag(g.goals) OVER w
       FROM games g JOIN model.team t ON t.team_id = g.opponent_id WINDOW w AS (ORDER BY g.match_date) ORDER BY 1 DESC;`,
      // Total instead of running total (no ORDER BY in the window).
      `WITH arg AS (SELECT team_id FROM model.team WHERE team_name = 'Argentina'), games AS (
         SELECT m.match_date, CASE WHEN m.home_team_id = arg.team_id THEN m.away_team_id ELSE m.home_team_id END AS opponent_id,
                CASE WHEN m.home_team_id = arg.team_id THEN m.home_score ELSE m.away_score END AS goals
         FROM model.match m, arg WHERE arg.team_id IN (m.home_team_id, m.away_team_id))
       SELECT g.match_date, t.team_name, g.goals, sum(g.goals) OVER (), g.goals - lag(g.goals) OVER (ORDER BY g.match_date)
       FROM games g JOIN model.team t ON t.team_id = g.opponent_id ORDER BY g.match_date;`,
      // Always took the home score.
      `WITH arg AS (SELECT team_id FROM model.team WHERE team_name = 'Argentina'), games AS (
         SELECT m.match_date, CASE WHEN m.home_team_id = arg.team_id THEN m.away_team_id ELSE m.home_team_id END AS opponent_id,
                m.home_score AS goals
         FROM model.match m, arg WHERE arg.team_id IN (m.home_team_id, m.away_team_id))
       SELECT g.match_date, t.team_name, g.goals, sum(g.goals) OVER (ORDER BY g.match_date), g.goals - lag(g.goals) OVER (ORDER BY g.match_date)
       FROM games g JOIN model.team t ON t.team_id = g.opponent_id ORDER BY g.match_date;`,
    ],
  },
  {
    id: "best-chance",
    title: "Each team's best chance",
    concept: "LATERAL (top-N per group)",
    prompt:
      "For each team, what was its best chance from open play or a set piece: its single highest-xG shot that wasn't a penalty (`shot_type` 'Penalty')? Shootout kicks are penalties too, so they drop out with the same filter. Return `team_name`, the shooter's `display_name`, the `xg` rounded to 2 decimals, and whether it was scored (`is_goal`).",
    // Answer key must not depend on how ties are broken: 0 teams may tie at the top.
    tiesAtLimit: `SELECT count(*) FROM (SELECT team_id FROM (
      SELECT e.team_id, rank() OVER (PARTITION BY e.team_id ORDER BY s.xg DESC) AS r
      FROM model.shot s JOIN model.event e USING (event_id)
      WHERE s.shot_type <> 'Penalty') ranked
      WHERE r = 1 GROUP BY team_id HAVING count(*) > 1) tied`,
    hint: "`FROM model.team t CROSS JOIN LATERAL (SELECT ... WHERE e.team_id = t.team_id ORDER BY s.xg DESC LIMIT 1) best`: the subquery runs once per team.",
    solution: `SELECT t.team_name, best.display_name, round(best.xg, 2) AS xg, best.is_goal
FROM model.team t
CROSS JOIN LATERAL (
  SELECT p.display_name, s.xg, s.is_goal
  FROM model.shot s
  JOIN model.event e ON e.event_id = s.event_id
  JOIN model.player p ON p.player_id = e.player_id
  WHERE e.team_id = t.team_id AND s.shot_type <> 'Penalty'
  ORDER BY s.xg DESC
  LIMIT 1
) best;`,
    alsoCorrect: [
      `SELECT DISTINCT ON (t.team_name) t.team_name, p.display_name, s.xg, s.is_goal
       FROM model.shot s JOIN model.event e USING (event_id) JOIN model.team t ON t.team_id = e.team_id
       JOIN model.player p ON p.player_id = e.player_id
       WHERE s.shot_type <> 'Penalty' ORDER BY t.team_name, s.xg DESC;`,
    ],
    wrong: [
      // Penalties included: every penalty has the same xG (0.78), so these tie.
      `SELECT t.team_name, best.display_name, round(best.xg, 2), best.is_goal FROM model.team t
       CROSS JOIN LATERAL (SELECT p.display_name, s.xg, s.is_goal FROM model.shot s
         JOIN model.event e ON e.event_id = s.event_id JOIN model.player p ON p.player_id = e.player_id
         WHERE e.team_id = t.team_id ORDER BY s.xg DESC, s.event_id LIMIT 1) best;`,
      // ORDER BY xg ascending: the worst chance.
      `SELECT t.team_name, best.display_name, round(best.xg, 2), best.is_goal FROM model.team t
       CROSS JOIN LATERAL (SELECT p.display_name, s.xg, s.is_goal FROM model.shot s
         JOIN model.event e ON e.event_id = s.event_id JOIN model.player p ON p.player_id = e.player_id
         WHERE e.team_id = t.team_id AND s.shot_type <> 'Penalty' ORDER BY s.xg, s.event_id LIMIT 1) best;`,
    ],
  },
  {
    id: "passing-pairs",
    title: "Favourite passing pairs",
    concept: "Self-join on player tables, multi-column GROUP BY",
    prompt:
      "Which passer → recipient pairs completed at least 60 passes to each other over the tournament? Return the passer's `display_name`, the recipient's `display_name` and the number of completed passes.",
    hint: "A pass has the passer on `model.event.player_id` and the receiver on `model.pass.recipient_id`. Join `model.player` twice. Completed means `outcome IS NULL`.",
    solution: `SELECT passer.display_name AS passer, receiver.display_name AS recipient, count(*) AS passes
FROM model.pass p
JOIN model.event e ON e.event_id = p.event_id
JOIN model.player passer ON passer.player_id = e.player_id
JOIN model.player receiver ON receiver.player_id = p.recipient_id
WHERE p.outcome IS NULL
GROUP BY passer.player_id, passer.display_name, receiver.player_id, receiver.display_name
HAVING count(*) >= 60;`,
    wrong: [
      // Incomplete passes counted too.
      `SELECT a.display_name, b.display_name, count(*) FROM model.pass p JOIN model.event e ON e.event_id = p.event_id
       JOIN model.player a ON a.player_id = e.player_id JOIN model.player b ON b.player_id = p.recipient_id
       GROUP BY a.player_id, a.display_name, b.player_id, b.display_name HAVING count(*) >= 60;`,
      // Pairs merged regardless of direction.
      `SELECT least(a.display_name, b.display_name), greatest(a.display_name, b.display_name), count(*)
       FROM model.pass p JOIN model.event e ON e.event_id = p.event_id
       JOIN model.player a ON a.player_id = e.player_id JOIN model.player b ON b.player_id = p.recipient_id
       WHERE p.outcome IS NULL GROUP BY 1, 2 HAVING count(*) >= 60;`,
    ],
  },
  {
    id: "quarantine",
    title: "Records we refused to load",
    concept: "Data quality, jsonb",
    prompt:
      "Some StatsBomb lineup records are impossible (a stint that ends before it starts, for example), so the build sets them aside in `stg.quarantine` instead of fixing them silently. For each match with quarantined rows, return home team name, away team name and the number of quarantined rows. The match id is inside the `record_key` jsonb.",
    hint: "`(q.record_key ->> 'match_id')::bigint` extracts the id as a number. Then join `model.match` and `model.team` twice, as in the bracket challenge.",
    solution: `SELECT h.team_name AS home_team, a.team_name AS away_team, count(*) AS quarantined
FROM stg.quarantine q
JOIN model.match m ON m.match_id = (q.record_key ->> 'match_id')::bigint
JOIN model.team h ON h.team_id = m.home_team_id
JOIN model.team a ON a.team_id = m.away_team_id
GROUP BY m.match_id, h.team_name, a.team_name;`,
    wrong: [
      // Counted per reason instead of per match.
      `SELECT h.team_name, a.team_name, count(*) FROM stg.quarantine q
       JOIN model.match m ON m.match_id = (q.record_key ->> 'match_id')::bigint
       JOIN model.team h ON h.team_id = m.home_team_id JOIN model.team a ON a.team_id = m.away_team_id
       GROUP BY m.match_id, h.team_name, a.team_name, q.reason;`,
    ],
  },
];
