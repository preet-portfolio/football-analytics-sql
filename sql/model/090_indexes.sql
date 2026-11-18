-- Secondary indexes. Each one exists because a benchmark in scripts/bench.py
-- shows it pays for itself; docs/perf/README.md has the EXPLAIN ANALYZE evidence.
-- Primary keys and UNIQUE (match_id, event_index) already cover per-match scans.

-- "Show me everything Messi did": events by player, in match order.
CREATE INDEX event_player_idx ON model.event (player_id, match_id, event_index);

-- "Replay possession N of a match": events of one possession.
CREATE INDEX event_match_possession_idx ON model.event (match_id, possession);

-- "Who passed to Messi?": passes by recipient.
CREATE INDEX pass_recipient_idx ON model.pass (recipient_id);

-- Considered and rejected: (match_id, team_id, event_type_id) for the pass-network
-- query. It speeds the live query only 1.4x (1.0 s -> 0.75 s); materializing
-- analysis.pass_network with an index on match_id answers it in 0.07 ms, so this
-- index would only cost writes and space.
