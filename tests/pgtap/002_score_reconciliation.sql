-- Correctness against reality: goals counted from raw events must equal the
-- published score of every match, and that score must equal an independent source.
-- On failure, is_empty() prints the offending matches.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap;
SELECT plan(6);

SELECT is((SELECT count(*)::int FROM audit.score_reconciliation), 64,
          'reconciliation covers all 64 matches, one row each');

SELECT is_empty($$
    SELECT match_id, home_team, away_team, sb_home, sb_away, ev_home, ev_away
    FROM audit.score_reconciliation WHERE NOT events_agree
$$, 'event-derived goals equal the StatsBomb published score for every match');

SELECT is_empty($$
    SELECT match_id, match_date, home_team, away_team
    FROM audit.score_reconciliation WHERE NOT of_found
$$, 'every StatsBomb match is found in openfootball (by date and team pair)');

SELECT is_empty($$
    SELECT match_id, home_team, away_team, sb_home, sb_away, of_home, of_away
    FROM audit.score_reconciliation WHERE NOT external_agree
$$, 'StatsBomb published score equals the openfootball score for every match');

SELECT is_empty($$
    SELECT match_id, home_team, away_team, ev_pen_home, ev_pen_away, of_pen_home, of_pen_away
    FROM audit.score_reconciliation WHERE NOT shootout_agree
$$, 'penalty shootout goals from events equal the openfootball shootout result');

SELECT is((SELECT sum(sb_home + sb_away)::int FROM audit.score_reconciliation), 172,
          '172 goals in the tournament, the total FIFA reports for Qatar 2022');

SELECT * FROM finish();
ROLLBACK;
