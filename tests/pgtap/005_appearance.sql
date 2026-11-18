-- Time on the pitch obeys the rules of the game, and agrees with the lineup
-- data wherever the lineup data is clean.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap;
SELECT plan(7);

SELECT set_eq(
    $$ SELECT match_id, player_id FROM model.appearance $$,
    $$ SELECT match_id, player_id FROM model.lineup WHERE played $$,
    'players with an appearance are exactly the lineup players who played');

SELECT is((SELECT count(*)::int FROM model.match_period WHERE period <= 2), 128,
          'every match has a first and second half');

-- 11 v 11: at the start, middle and last second of every period, each team has 11 players on
-- the pitch minus anyone dismissed earlier. The dismissals come from the LINEUP card
-- records, an independent witness to the event stream that appearance is built from.
-- Lineup card clocks are continuous ('67:30'); periods start at 0, 45, 90 and 105 minutes.
SELECT is_empty($$
    WITH instant AS (
        SELECT match_id, period, interval '0' AS clock FROM model.match_period
        UNION ALL
        SELECT match_id, period, duration / 2 FROM model.match_period
        UNION ALL
        SELECT match_id, period, duration - interval '1 second' FROM model.match_period
    ), side AS (
        SELECT match_id, home_team_id AS team_id FROM model.match
        UNION ALL SELECT match_id, away_team_id FROM model.match
    ), dismissal AS (
        SELECT c.match_id, l.team_id, c.period,
               make_interval(secs => c.clock_seconds - (ARRAY[0, 2700, 5400, 6300])[c.period]) AS clock
        FROM model.card c JOIN model.lineup l USING (match_id, player_id)
        WHERE c.card_type IN ('Red Card', 'Second Yellow') AND c.period < 5 AND l.played
    ), counted AS (
        SELECT i.match_id, s.team_id, i.period, i.clock,
               (SELECT count(*) FROM model.appearance a
                 WHERE a.match_id = i.match_id AND a.team_id = s.team_id
                   AND (a.on_period, a.on_clock) <= (i.period, i.clock)
                   AND (i.period, i.clock) < (a.off_period, a.off_clock)) AS on_pitch,
               11 - (SELECT count(*) FROM dismissal d
                      WHERE d.match_id = i.match_id AND d.team_id = s.team_id
                        AND (d.period, d.clock) <= (i.period, i.clock)) AS expected
        FROM instant i JOIN side s USING (match_id)
    )
    SELECT * FROM counted WHERE on_pitch <> expected
$$, 'each team has 11 players on the pitch, minus lineup-recorded dismissals, at the start, middle and end of every period');

SELECT is_empty($$
    SELECT a.match_id, a.player_id, a.seconds_played, sum(extract(epoch FROM mp.duration))::int AS match_seconds
    FROM model.appearance a JOIN model.match_period mp USING (match_id)
    GROUP BY a.match_id, a.player_id, a.seconds_played, a.is_starter, a.off_reason
    HAVING a.seconds_played > round(sum(extract(epoch FROM mp.duration)))
        OR (a.is_starter AND a.off_reason = 'Full time'
            AND a.seconds_played <> round(sum(extract(epoch FROM mp.duration))))
$$, 'nobody plays longer than the match, and a starter who finishes plays all of it');

SELECT is((SELECT count(*)::int FROM model.appearance WHERE off_reason = 'Sent off' AND off_period < 5), 3,
          'three players were sent off during play (Hennessey, Aboubakar, Cheddira)');

-- Where lineup positions are clean, a substitute's first lineup stint starts at the
-- substitution (lineup clock MM:SS vs event minute:second, within 5 seconds).
SELECT is_empty($$
    SELECT a.match_id, a.player_id, e.minute * 60 + e.second AS event_clock, s.from_seconds AS lineup_clock
    FROM model.appearance a
    JOIN model.substitution sub ON sub.replacement_id = a.player_id
    JOIN model.event e ON e.event_id = sub.event_id AND e.match_id = a.match_id
    JOIN model.lineup_stint s ON s.match_id = a.match_id AND s.player_id = a.player_id AND s.stint_no = 1
    WHERE NOT a.is_starter
      AND NOT EXISTS (SELECT 1 FROM stg.quarantine q
                      WHERE (q.record_key->>'match_id')::bigint = a.match_id
                        AND (q.record_key->>'player_id')::int = a.player_id)
      AND abs(e.minute * 60 + e.second - s.from_seconds) > 5
$$, 'substitutes with clean lineup data come on when the substitution event says');

SELECT cmp_ok((SELECT count(*)::int FROM model.appearance a
               JOIN model.lineup_stint s ON s.match_id = a.match_id AND s.player_id = a.player_id AND s.stint_no = 1
               WHERE NOT a.is_starter), '>', 400,
              'the substitution cross-check above compares hundreds of substitutes (not vacuous)');

SELECT * FROM finish();
ROLLBACK;
