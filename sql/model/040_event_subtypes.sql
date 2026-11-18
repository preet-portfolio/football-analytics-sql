-- Canonical model: event subtype tables. Each has event_id as primary key and
-- foreign key to model.event, so its grain is "one row per event of that type".
-- Enum-like StatsBomb attributes (outcome, body part, ...) are kept as their names;
-- the tests pin the allowed values instead of a lookup table per attribute.

-- -------------------------------------------------------------------- shot
CREATE TABLE model.shot (
    event_id        uuid    PRIMARY KEY REFERENCES model.event,
    xg              numeric NOT NULL CHECK (xg BETWEEN 0 AND 1),   -- StatsBomb expected goals
    outcome         text    NOT NULL,     -- Goal, Saved, Off T, Blocked, Post, Wayward, Saved to Post, Saved Off Target
    shot_type       text    NOT NULL,     -- Open Play, Penalty, Free Kick, Corner, Kick Off
    body_part       text    NOT NULL,
    technique       text    NOT NULL,
    end_x           numeric,
    end_y           numeric,
    end_z           numeric,              -- height at the goal line; absent for some shots
    is_first_time   boolean NOT NULL DEFAULT false,
    is_one_on_one   boolean NOT NULL DEFAULT false,
    is_open_goal    boolean NOT NULL DEFAULT false,
    is_aerial_won   boolean NOT NULL DEFAULT false,
    is_deflected    boolean NOT NULL DEFAULT false,
    follows_dribble boolean NOT NULL DEFAULT false,
    is_redirect     boolean NOT NULL DEFAULT false,
    saved_to_post   boolean NOT NULL DEFAULT false,
    saved_off_target boolean NOT NULL DEFAULT false,
    key_pass_id     uuid    REFERENCES model.event,
    is_goal         boolean GENERATED ALWAYS AS (outcome = 'Goal') STORED
);
COMMENT ON TABLE model.shot IS 'Grain: one row per shot event (including penalty-shootout kicks, period 5).';

INSERT INTO model.shot
SELECT event_id,
       (payload->'shot'->>'statsbomb_xg')::numeric,
       payload->'shot'->'outcome'->>'name',
       payload->'shot'->'type'->>'name',
       payload->'shot'->'body_part'->>'name',
       payload->'shot'->'technique'->>'name',
       (payload->'shot'->'end_location'->>0)::numeric,
       (payload->'shot'->'end_location'->>1)::numeric,
       (payload->'shot'->'end_location'->>2)::numeric,
       coalesce((payload->'shot'->>'first_time')::boolean, false),
       coalesce((payload->'shot'->>'one_on_one')::boolean, false),
       coalesce((payload->'shot'->>'open_goal')::boolean, false),
       coalesce((payload->'shot'->>'aerial_won')::boolean, false),
       coalesce((payload->'shot'->>'deflected')::boolean, false),
       coalesce((payload->'shot'->>'follows_dribble')::boolean, false),
       coalesce((payload->'shot'->>'redirect')::boolean, false),
       coalesce((payload->'shot'->>'saved_to_post')::boolean, false),
       coalesce((payload->'shot'->>'saved_off_target')::boolean, false),
       (payload->'shot'->>'key_pass_id')::uuid
FROM stg.event WHERE type_name = 'Shot';

-- Grain: one row per player visible in the freeze frame at the moment of a shot.
CREATE TABLE model.shot_freeze_frame (
    event_id     uuid    NOT NULL REFERENCES model.shot,
    player_id    int     NOT NULL REFERENCES model.player,
    position_id  int     REFERENCES model.position,
    is_teammate  boolean NOT NULL,         -- relative to the shooter
    location_x   numeric NOT NULL,
    location_y   numeric NOT NULL,
    PRIMARY KEY (event_id, player_id)
);
COMMENT ON TABLE model.shot_freeze_frame IS 'Grain: one row per player in the freeze frame of a shot.';

INSERT INTO model.shot_freeze_frame
SELECT e.event_id, (ff->'player'->>'id')::int, (ff->'position'->>'id')::int,
       (ff->>'teammate')::boolean, (ff->'location'->>0)::numeric, (ff->'location'->>1)::numeric
FROM stg.event e
CROSS JOIN LATERAL jsonb_array_elements(e.payload->'shot'->'freeze_frame') AS ff
WHERE e.type_name = 'Shot';

-- -------------------------------------------------------------------- pass
CREATE TABLE model.pass (
    event_id          uuid    PRIMARY KEY REFERENCES model.event,
    recipient_id      int     REFERENCES model.player,     -- NULL when nobody received it
    length            numeric NOT NULL,
    angle             numeric NOT NULL,                    -- radians
    height            text    NOT NULL,                    -- Ground Pass, Low Pass, High Pass
    end_x             numeric NOT NULL,
    end_y             numeric NOT NULL,
    outcome           text,                                -- NULL = completed (StatsBomb convention)
    pass_type         text,                                -- Corner, Free Kick, Throw-in, Kick Off, ...; NULL = open play
    body_part         text,
    technique         text,                                -- Through Ball, Inswinging, ...
    is_cross          boolean NOT NULL DEFAULT false,
    is_switch         boolean NOT NULL DEFAULT false,
    is_cut_back       boolean NOT NULL DEFAULT false,
    is_shot_assist    boolean NOT NULL DEFAULT false,
    is_goal_assist    boolean NOT NULL DEFAULT false,
    is_aerial_won     boolean NOT NULL DEFAULT false,
    is_deflected      boolean NOT NULL DEFAULT false,
    is_miscommunication boolean NOT NULL DEFAULT false,
    is_no_touch       boolean NOT NULL DEFAULT false,
    assisted_shot_id  uuid    REFERENCES model.event,
    is_complete       boolean GENERATED ALWAYS AS (outcome IS NULL) STORED
);
COMMENT ON TABLE model.pass IS 'Grain: one row per pass event. outcome NULL means the pass was completed.';

INSERT INTO model.pass
SELECT event_id,
       (payload->'pass'->'recipient'->>'id')::int,
       (payload->'pass'->>'length')::numeric,
       (payload->'pass'->>'angle')::numeric,
       payload->'pass'->'height'->>'name',
       (payload->'pass'->'end_location'->>0)::numeric,
       (payload->'pass'->'end_location'->>1)::numeric,
       payload->'pass'->'outcome'->>'name',
       payload->'pass'->'type'->>'name',
       payload->'pass'->'body_part'->>'name',
       payload->'pass'->'technique'->>'name',
       coalesce((payload->'pass'->>'cross')::boolean, false),
       coalesce((payload->'pass'->>'switch')::boolean, false),
       coalesce((payload->'pass'->>'cut_back')::boolean, false),
       coalesce((payload->'pass'->>'shot_assist')::boolean, false),
       coalesce((payload->'pass'->>'goal_assist')::boolean, false),
       coalesce((payload->'pass'->>'aerial_won')::boolean, false),
       coalesce((payload->'pass'->>'deflected')::boolean, false),
       coalesce((payload->'pass'->>'miscommunication')::boolean, false),
       coalesce((payload->'pass'->>'no_touch')::boolean, false),
       (payload->'pass'->>'assisted_shot_id')::uuid
FROM stg.event WHERE type_name = 'Pass';

-- ------------------------------------------------------------------- carry
CREATE TABLE model.carry (
    event_id uuid    PRIMARY KEY REFERENCES model.event,
    end_x    numeric NOT NULL,
    end_y    numeric NOT NULL
);
COMMENT ON TABLE model.carry IS 'Grain: one row per carry (a player moving with the ball).';

INSERT INTO model.carry
SELECT event_id, (payload->'carry'->'end_location'->>0)::numeric, (payload->'carry'->'end_location'->>1)::numeric
FROM stg.event WHERE type_name = 'Carry';

-- ----------------------------------------------------------------- dribble
CREATE TABLE model.dribble (
    event_id   uuid    PRIMARY KEY REFERENCES model.event,
    outcome    text    NOT NULL CHECK (outcome IN ('Complete', 'Incomplete')),
    is_nutmeg  boolean NOT NULL DEFAULT false,
    is_overrun boolean NOT NULL DEFAULT false,
    is_no_touch boolean NOT NULL DEFAULT false
);
COMMENT ON TABLE model.dribble IS 'Grain: one row per dribble attempt past an opponent.';

INSERT INTO model.dribble
SELECT event_id, payload->'dribble'->'outcome'->>'name',
       coalesce((payload->'dribble'->>'nutmeg')::boolean, false),
       coalesce((payload->'dribble'->>'overrun')::boolean, false),
       coalesce((payload->'dribble'->>'no_touch')::boolean, false)
FROM stg.event WHERE type_name = 'Dribble';

-- -------------------------------------------------------------------- duel
CREATE TABLE model.duel (
    event_id  uuid PRIMARY KEY REFERENCES model.event,
    duel_type text NOT NULL,     -- Aerial Lost, Tackle
    outcome   text               -- for tackles: Won, Lost In Play, Success In Play, ...
);
COMMENT ON TABLE model.duel IS 'Grain: one row per duel (tackle or aerial).';

INSERT INTO model.duel
SELECT event_id, payload->'duel'->'type'->>'name', payload->'duel'->'outcome'->>'name'
FROM stg.event WHERE type_name = 'Duel';

-- -------------------------------------------------------------- goalkeeper
CREATE TABLE model.goalkeeper_action (
    event_id    uuid PRIMARY KEY REFERENCES model.event,
    action_type text NOT NULL,   -- Shot Saved, Goal Conceded, Collected, Punch, Keeper Sweeper, ...
    outcome     text,
    technique   text,
    gk_position text,
    body_part   text,
    end_x       numeric,
    end_y       numeric,
    is_punched_out boolean NOT NULL DEFAULT false,
    flags       jsonb             -- rare outcome flags (lost_in_play, shot_saved_to_post, ...)
);
COMMENT ON TABLE model.goalkeeper_action IS 'Grain: one row per goalkeeper action event.';

INSERT INTO model.goalkeeper_action
SELECT event_id, payload->'goalkeeper'->'type'->>'name', payload->'goalkeeper'->'outcome'->>'name',
       payload->'goalkeeper'->'technique'->>'name', payload->'goalkeeper'->'position'->>'name',
       payload->'goalkeeper'->'body_part'->>'name',
       (payload->'goalkeeper'->'end_location'->>0)::numeric,
       (payload->'goalkeeper'->'end_location'->>1)::numeric,
       coalesce((payload->'goalkeeper'->>'punched_out')::boolean, false),
       nullif((payload->'goalkeeper') - ARRAY['type','outcome','technique','position','body_part','end_location','punched_out']::text[], '{}'::jsonb)
FROM stg.event WHERE type_name = 'Goal Keeper';

-- ------------------------------------------------------------ substitution
CREATE TABLE model.substitution (
    event_id       uuid PRIMARY KEY REFERENCES model.event,   -- event.player_id is the player going off
    replacement_id int  NOT NULL REFERENCES model.player,     -- the player coming on
    reason         text NOT NULL                               -- Tactical, Injury
);
COMMENT ON TABLE model.substitution IS 'Grain: one row per substitution. event.player_id goes off, replacement_id comes on.';

INSERT INTO model.substitution
SELECT event_id, (payload->'substitution'->'replacement'->>'id')::int, payload->'substitution'->'outcome'->>'name'
FROM stg.event WHERE type_name = 'Substitution';

-- ------------------------------------------------------------------- fouls
CREATE TABLE model.foul_committed (
    event_id     uuid    PRIMARY KEY REFERENCES model.event,
    foul_type    text,
    card         text,             -- Yellow Card, Second Yellow, Red Card; NULL if none
    is_penalty   boolean NOT NULL DEFAULT false,
    is_advantage boolean NOT NULL DEFAULT false,
    is_offensive boolean NOT NULL DEFAULT false
);
COMMENT ON TABLE model.foul_committed IS 'Grain: one row per foul committed.';

INSERT INTO model.foul_committed
SELECT event_id, payload->'foul_committed'->'type'->>'name', payload->'foul_committed'->'card'->>'name',
       coalesce((payload->'foul_committed'->>'penalty')::boolean, false),
       coalesce((payload->'foul_committed'->>'advantage')::boolean, false),
       coalesce((payload->'foul_committed'->>'offensive')::boolean, false)
FROM stg.event WHERE type_name = 'Foul Committed';

-- ---------------------------------------------------- everything else, kept
-- Types without a dedicated table keep their type-specific object here, so no
-- upstream attribute is lost; a table is promoted out of this when an analysis needs it.
CREATE TABLE model.event_attribute (
    event_id   uuid  PRIMARY KEY REFERENCES model.event,
    attributes jsonb NOT NULL
);
COMMENT ON TABLE model.event_attribute IS 'Grain: one row per event of a type without its own table, holding its type-specific attributes.';

INSERT INTO model.event_attribute
SELECT e.event_id, kv.value
FROM stg.event e
CROSS JOIN LATERAL jsonb_each(e.payload) AS kv
WHERE jsonb_typeof(kv.value) = 'object'
  AND kv.key NOT IN ('type', 'possession_team', 'play_pattern', 'team', 'player', 'position',
                     'shot', 'pass', 'carry', 'dribble', 'duel', 'goalkeeper', 'substitution', 'foul_committed');
