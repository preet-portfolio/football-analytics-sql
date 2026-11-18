-- Canonical model: the event stream (common attributes of every on-ball action).
-- Type-specific attributes live in subtype tables (040_event_subtypes.sql), one row
-- per event of that type, sharing event_id as primary and foreign key.

CREATE TABLE model.event (
    event_id           uuid     PRIMARY KEY,
    match_id           bigint   NOT NULL REFERENCES model.match,
    event_index        int      NOT NULL,                 -- order within the match
    period             int      NOT NULL CHECK (period BETWEEN 1 AND 5),   -- 5 = penalty shootout
    period_clock       interval NOT NULL,                 -- time since the period started
    minute             int      NOT NULL,                 -- continuous match clock (2nd half starts at 45)
    second             int      NOT NULL CHECK (second BETWEEN 0 AND 59),
    event_type_id      int      NOT NULL REFERENCES model.event_type,
    possession         int      NOT NULL,                 -- possession sequence number within the match
    possession_team_id int      NOT NULL REFERENCES model.team,
    play_pattern_id    int      NOT NULL REFERENCES model.play_pattern,
    team_id            int      NOT NULL REFERENCES model.team,
    player_id          int      REFERENCES model.player,  -- NULL for team events (Half Start, ...)
    position_id        int      REFERENCES model.position,
    location_x         numeric(5,2) CHECK (location_x BETWEEN 0 AND 120),   -- StatsBomb pitch: 120 x 80
    location_y         numeric(5,2) CHECK (location_y BETWEEN 0 AND 80),
    duration_seconds   numeric,
    under_pressure     boolean  NOT NULL DEFAULT false,
    counterpress       boolean  NOT NULL DEFAULT false,
    off_camera         boolean  NOT NULL DEFAULT false,
    is_out             boolean  NOT NULL DEFAULT false,
    UNIQUE (match_id, event_index)
);
COMMENT ON TABLE model.event IS 'Grain: one row per on-ball event (pass, shot, pressure, ...) in a match.';

INSERT INTO model.event
SELECT event_id, match_id,
       (payload->>'index')::int,
       (payload->>'period')::int,
       (payload->>'timestamp')::interval,
       (payload->>'minute')::int,
       (payload->>'second')::int,
       (payload->'type'->>'id')::int,
       (payload->>'possession')::int,
       (payload->'possession_team'->>'id')::int,
       (payload->'play_pattern'->>'id')::int,
       (payload->'team'->>'id')::int,
       (payload->'player'->>'id')::int,
       (payload->'position'->>'id')::int,
       (payload->'location'->>0)::numeric,
       (payload->'location'->>1)::numeric,
       (payload->>'duration')::numeric,
       coalesce((payload->>'under_pressure')::boolean, false),
       coalesce((payload->>'counterpress')::boolean, false),
       coalesce((payload->>'off_camera')::boolean, false),
       coalesce((payload->>'out')::boolean, false)
FROM stg.event;

-- Grain: one row per directed link between two events (e.g. a pass and the
-- receipt it led to). StatsBomb lists links on both sides.
CREATE TABLE model.event_relation (
    event_id         uuid NOT NULL REFERENCES model.event,
    related_event_id uuid NOT NULL REFERENCES model.event,
    PRIMARY KEY (event_id, related_event_id)
);
COMMENT ON TABLE model.event_relation IS 'Grain: one row per directed link from an event to a related event.';

INSERT INTO model.event_relation
SELECT DISTINCT e.event_id, r::uuid
FROM stg.event e
CROSS JOIN LATERAL jsonb_array_elements_text(e.payload->'related_events') AS r;
