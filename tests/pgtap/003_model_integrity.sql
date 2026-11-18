-- The model is complete (nothing from raw is lost) and every table honours its stated grain.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap;
SELECT plan(14);

SELECT is_empty($$
    SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'model' AND c.relkind = 'r'
      AND NOT EXISTS (SELECT 1 FROM pg_constraint k WHERE k.conrelid = c.oid AND k.contype = 'p')
$$, 'every model table has a primary key (its grain is enforced, not just described)');

SELECT is_empty($$
    SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'model' AND c.relkind = 'r'
      AND coalesce(obj_description(c.oid, 'pg_class'), '') NOT LIKE 'Grain:%'
$$, 'every model table documents its grain');

SELECT is((SELECT count(*) FROM model.event),
          (SELECT sum(jsonb_array_length(payload)) FROM raw.source_file WHERE entity = 'events'),
          'model.event has exactly one row per raw event');

SELECT is((SELECT count(*) FROM model.match),
          (SELECT sum(jsonb_array_length(payload)) FROM raw.source_file WHERE entity = 'matches')::bigint,
          'model.match has exactly one row per raw match');

SELECT is((SELECT count(*) FROM model.lineup),
          (SELECT count(*) FROM raw.source_file f, jsonb_array_elements(f.payload) t, jsonb_array_elements(t->'lineup')
            WHERE f.entity = 'lineups'),
          'model.lineup has exactly one row per raw lineup player');

SELECT is((SELECT count(*) FROM model.lineup_stint)
        + (SELECT count(*) FROM stg.quarantine WHERE target_table = 'model.lineup_stint'),
          (SELECT count(*) FROM raw.source_file f, jsonb_array_elements(f.payload) t,
                  jsonb_array_elements(t->'lineup') p, jsonb_array_elements(p->'positions')
            WHERE f.entity = 'lineups'),
          'every raw lineup position is either a model stint or quarantined');

SELECT is_empty($$
    SELECT et.event_type_name, count(e.event_id) AS events, count(s.event_id) AS subtype_rows
    FROM model.event e
    JOIN model.event_type et USING (event_type_id)
    LEFT JOIN (SELECT event_id FROM model.shot UNION ALL SELECT event_id FROM model.pass
               UNION ALL SELECT event_id FROM model.carry UNION ALL SELECT event_id FROM model.dribble
               UNION ALL SELECT event_id FROM model.duel UNION ALL SELECT event_id FROM model.goalkeeper_action
               UNION ALL SELECT event_id FROM model.substitution UNION ALL SELECT event_id FROM model.foul_committed) s
           USING (event_id)
    WHERE et.event_type_name IN ('Shot', 'Pass', 'Carry', 'Dribble', 'Duel', 'Goal Keeper', 'Substitution', 'Foul Committed')
    GROUP BY et.event_type_name
    HAVING count(e.event_id) <> count(s.event_id)
$$, 'every event of a modelled type has exactly one subtype row');

-- Upstream drift guard: a new top-level event key would be silently ignored by the model.
SELECT is_empty($$
    SELECT DISTINCT k FROM stg.event, jsonb_object_keys(payload) k
    WHERE k NOT IN ('id', 'index', 'period', 'timestamp', 'minute', 'second', 'type', 'possession',
                    'possession_team', 'play_pattern', 'team', 'player', 'position', 'location',
                    'duration', 'under_pressure', 'counterpress', 'off_camera', 'out', 'related_events',
                    'shot', 'pass', 'carry', 'dribble', 'duel', 'goalkeeper', 'substitution', 'foul_committed',
                    'tactics', 'ball_receipt', 'ball_recovery', 'clearance', 'interception', 'block',
                    'miscontrol', '50_50', 'bad_behaviour', 'foul_won', 'injury_stoppage', 'player_off',
                    'half_start', 'half_end')
$$, 'no unknown top-level event keys (upstream schema drift)');

SELECT is_empty($$
    SELECT match_id, team_id, count(*) FILTER (WHERE is_starter) AS starters
    FROM model.lineup GROUP BY match_id, team_id
    HAVING count(*) FILTER (WHERE is_starter) <> 11
$$, 'every team starts every match with exactly 11 players');

SELECT is_empty($$
    SELECT l.match_id, l.player_id FROM model.lineup l
    JOIN model.event e ON e.match_id = l.match_id AND e.event_type_id = 35   -- Starting XI
    WHERE l.is_starter AND e.team_id = l.team_id
      AND NOT EXISTS (SELECT 1 FROM stg.event s, jsonb_array_elements(s.payload->'tactics'->'lineup') x
                      WHERE s.event_id = e.event_id AND (x->'player'->>'id')::int = l.player_id)
$$, 'lineup starters agree with the Starting XI event of the event stream');

-- Quarantine is pinned per reason. A new kind or number of anomaly must be looked
-- at, not silently dropped.
SELECT results_eq($$
    SELECT reason, count(*)::int FROM stg.quarantine GROUP BY reason ORDER BY reason
$$, $$ VALUES ('stint ends because the same player came on', 28),
              ('stint ends before it starts', 20),
              ('stint overlaps an earlier stint of the same player', 25),
              ('substitute''s stint precedes their entry', 22) $$,
'quarantine holds exactly the known phantom lineup stints, by reason');

SELECT is_empty($$
    SELECT a.match_id, a.player_id, a.stint_no, b.stint_no
    FROM model.lineup_stint a JOIN model.lineup_stint b
      ON a.match_id = b.match_id AND a.player_id = b.player_id AND a.stint_no < b.stint_no
    WHERE (a.from_period, a.from_seconds) < (coalesce(b.to_period, 9), coalesce(b.to_seconds, 999999))
      AND (b.from_period, b.from_seconds) < (coalesce(a.to_period, 9), coalesce(a.to_seconds, 999999))
$$, 'no player is in two lineup stints at the same time');

SELECT results_eq($$
    SELECT count(*)::int, min(n)::int, max(n)::int
    FROM (SELECT group_name, count(*) AS n FROM model.season_team WHERE group_name IS NOT NULL GROUP BY 1) g
$$, $$ VALUES (8, 4, 4) $$, 'the World Cup has 8 groups of exactly 4 teams (no team without a group)');

-- Every attribute inside a modelled subtype object maps to a column (or is a
-- documented duplicate). An unmapped key means data is being lost.
SELECT is_empty($$
    SELECT sub, k, count(*) AS events
    FROM stg.event e
    CROSS JOIN LATERAL (VALUES ('shot'), ('pass'), ('carry'), ('dribble'), ('duel'),
                               ('goalkeeper'), ('substitution'), ('foul_committed')) v (sub)
    CROSS JOIN LATERAL jsonb_object_keys(coalesce(e.payload->sub, '{}')) k
    WHERE (sub, k) NOT IN (
        ('shot','statsbomb_xg'),('shot','outcome'),('shot','type'),('shot','body_part'),('shot','technique'),
        ('shot','end_location'),('shot','first_time'),('shot','one_on_one'),('shot','open_goal'),
        ('shot','aerial_won'),('shot','deflected'),('shot','follows_dribble'),('shot','redirect'),
        ('shot','saved_to_post'),('shot','saved_off_target'),('shot','key_pass_id'),('shot','freeze_frame'),
        ('pass','recipient'),('pass','length'),('pass','angle'),('pass','height'),('pass','end_location'),
        ('pass','outcome'),('pass','type'),('pass','body_part'),('pass','technique'),('pass','cross'),
        ('pass','switch'),('pass','cut_back'),('pass','shot_assist'),('pass','goal_assist'),
        ('pass','aerial_won'),('pass','deflected'),('pass','miscommunication'),('pass','no_touch'),
        ('pass','assisted_shot_id'),
        -- duplicates of pass.technique:
        ('pass','through_ball'),('pass','inswinging'),('pass','outswinging'),('pass','straight'),
        ('carry','end_location'),
        ('dribble','outcome'),('dribble','nutmeg'),('dribble','overrun'),('dribble','no_touch'),
        ('duel','type'),('duel','outcome'),
        ('goalkeeper','type'),('goalkeeper','outcome'),('goalkeeper','technique'),('goalkeeper','position'),
        ('goalkeeper','body_part'),('goalkeeper','end_location'),('goalkeeper','punched_out'),
        ('goalkeeper','lost_in_play'),('goalkeeper','success_in_play'),
        ('goalkeeper','shot_saved_off_target'),('goalkeeper','shot_saved_to_post'),   -- kept in flags
        ('substitution','replacement'),('substitution','outcome'),
        ('foul_committed','type'),('foul_committed','card'),('foul_committed','penalty'),
        ('foul_committed','advantage'),('foul_committed','offensive'))
    GROUP BY sub, k
$$, 'every subtype attribute in raw is mapped to a model column');

SELECT * FROM finish();
ROLLBACK;
