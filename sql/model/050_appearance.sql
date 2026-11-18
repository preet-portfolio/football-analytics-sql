-- Canonical model: time on the pitch, derived from the EVENT STREAM.
--
-- Why not lineup positions: StatsBomb's lineup positions contain 95 phantom stints
-- across 30 matches, 51 of them in the 5 extra-time matches: overlapping spells,
-- spells that "end" with the player coming on, substitutes whose only spell starts
-- after 105'. The event stream
-- (Starting XI, Substitution, red cards, Half End) is consistent, and the tests
-- check it against invariants of the game itself (11 v 11 minus dismissals).

-- Grain: one row per period played in a match (1-4; the shootout, 5, has no clock time).
CREATE TABLE model.match_period (
    match_id  bigint   NOT NULL REFERENCES model.match,
    period    int      NOT NULL CHECK (period BETWEEN 1 AND 4),
    duration  interval NOT NULL CHECK (duration > interval '0'),   -- incl. stoppage time
    PRIMARY KEY (match_id, period)
);
COMMENT ON TABLE model.match_period IS 'Grain: one row per period played in a match (1-2 regulation, 3-4 extra time), with its real duration.';

INSERT INTO model.match_period
SELECT e.match_id, e.period, max(e.period_clock)
FROM model.event e JOIN model.event_type t USING (event_type_id)
WHERE t.event_type_name = 'Half End' AND e.period < 5
GROUP BY e.match_id, e.period;

CREATE TABLE model.appearance (
    match_id        bigint   NOT NULL REFERENCES model.match,
    player_id       int      NOT NULL REFERENCES model.player,
    team_id         int      NOT NULL REFERENCES model.team,
    is_starter      boolean  NOT NULL,
    on_period       int      NOT NULL,
    on_clock        interval NOT NULL,     -- time into on_period
    off_period      int      NOT NULL,
    off_clock       interval NOT NULL,
    off_reason      text     NOT NULL CHECK (off_reason IN ('Full time', 'Substituted', 'Sent off')),
    seconds_played  int      NOT NULL CHECK (seconds_played >= 0),
    PRIMARY KEY (match_id, player_id),
    FOREIGN KEY (match_id, player_id) REFERENCES model.lineup,
    CHECK ((off_period, off_clock) >= (on_period, on_clock))
);
COMMENT ON TABLE model.appearance IS 'Grain: one row per player who took the field in a match, with when they came on and went off (from the event stream).';

INSERT INTO model.appearance
WITH came_on AS (
    -- starters, from the Starting XI event's lineup
    SELECT e.match_id, (x->'player'->>'id')::int AS player_id, e.team_id, true AS is_starter,
           1 AS on_period, interval '0' AS on_clock
    FROM model.event e
    JOIN model.event_type t USING (event_type_id)
    JOIN stg.event s USING (event_id)
    CROSS JOIN LATERAL jsonb_array_elements(s.payload->'tactics'->'lineup') x
    WHERE t.event_type_name = 'Starting XI'
    UNION ALL
    -- substitutes, from Substitution events
    SELECT e.match_id, sub.replacement_id, e.team_id, false, e.period, e.period_clock
    FROM model.substitution sub JOIN model.event e USING (event_id)
),
went_off AS (
    SELECT DISTINCT ON (match_id, player_id) match_id, player_id, period, period_clock, reason
    FROM (
        SELECT e.match_id, e.player_id, e.period, e.period_clock, 'Substituted' AS reason
        FROM model.substitution sub JOIN model.event e USING (event_id)
        UNION ALL
        SELECT e.match_id, e.player_id, e.period, e.period_clock, 'Sent off'
        FROM model.foul_committed f JOIN model.event e USING (event_id)
        WHERE f.card IN ('Red Card', 'Second Yellow')
        UNION ALL
        SELECT e.match_id, e.player_id, e.period, e.period_clock, 'Sent off'
        FROM model.event_attribute a JOIN model.event e USING (event_id)
        JOIN model.event_type t USING (event_type_id)
        WHERE t.event_type_name = 'Bad Behaviour' AND a.attributes->'card'->>'name' IN ('Red Card', 'Second Yellow')
    ) o
    ORDER BY match_id, player_id, period, period_clock
),
full_time AS (
    SELECT DISTINCT ON (match_id) match_id, period, duration
    FROM model.match_period ORDER BY match_id, period DESC
),
spell AS (
    SELECT c.match_id, c.player_id, c.team_id, c.is_starter, c.on_period, c.on_clock,
           coalesce(o.period, ft.period)         AS off_period,
           coalesce(o.period_clock, ft.duration) AS off_clock,
           coalesce(o.reason, 'Full time')       AS off_reason
    FROM came_on c
    JOIN full_time ft USING (match_id)
    -- a red card shown on the bench (player never came on) is not a "went off"
    LEFT JOIN went_off o ON o.match_id = c.match_id AND o.player_id = c.player_id
                        AND (o.period, o.period_clock) >= (c.on_period, c.on_clock)
)
SELECT s.match_id, s.player_id, s.team_id, s.is_starter, s.on_period, s.on_clock,
       s.off_period, s.off_clock, s.off_reason,
       -- sum, over each period, the overlap of [on, off] with [0, period duration]
       coalesce((
           SELECT sum(extract(epoch FROM
                      least(CASE WHEN mp.period = s.off_period THEN s.off_clock ELSE mp.duration END, mp.duration)
                    - CASE WHEN mp.period = s.on_period THEN s.on_clock ELSE interval '0' END))
           FROM model.match_period mp
           WHERE mp.match_id = s.match_id AND mp.period BETWEEN s.on_period AND s.off_period
       ), 0)::int
FROM spell s;
