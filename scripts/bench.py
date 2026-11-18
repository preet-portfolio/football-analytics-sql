#!/usr/bin/env python3
"""EXPLAIN ANALYZE evidence for every secondary index (and one query rewrite).

For each benchmark the query runs RUNS times with the index dropped (inside a
transaction that is rolled back) and RUNS times with it, after a warm-up, and the
median execution time, plan shape and buffer reads are recorded. Output:
docs/perf/README.md (human) and site/data/perf.json (status page).
"""
import json
import statistics
import subprocess
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RUNS = 7
PSQL = ["docker", "compose", "exec", "-T", "db", "psql", "-U", "football", "-d", "football",
        "-qAt", "-v", "ON_ERROR_STOP=1"]

MESSI = "(SELECT player_id FROM model.player WHERE display_name = 'Lionel Messi')"
FINAL = "(SELECT match_id FROM model.match WHERE stage = 'Final')"

# Game state, first version: score per segment by correlated subqueries.
GAME_STATE_CORRELATED = """
WITH side AS (SELECT match_id, home_team_id AS team_id, away_team_id AS opp_id FROM model.match
              UNION ALL SELECT match_id, away_team_id, home_team_id FROM model.match),
boundary AS (SELECT mp.match_id, mp.period, interval '0' AS clock FROM model.match_period mp
             UNION ALL SELECT g.match_id, g.period, g.period_clock FROM analysis.goal g)
SELECT b.match_id, s.team_id, b.period, b.clock,
       (SELECT count(*) FROM analysis.goal g WHERE g.match_id = b.match_id AND g.team_id = s.team_id
          AND (g.period, g.period_clock) <= (b.period, b.clock)) AS gf,
       (SELECT count(*) FROM analysis.goal g WHERE g.match_id = b.match_id AND g.team_id = s.opp_id
          AND (g.period, g.period_clock) <= (b.period, b.clock)) AS ga
FROM boundary b JOIN side s USING (match_id)"""

TEAM_XG_CORRELATED = """
WITH team_matches AS (
    SELECT team_id, count(*) AS matches FROM (
        SELECT home_team_id AS team_id FROM model.match UNION ALL SELECT away_team_id FROM model.match) x
    GROUP BY team_id
), opp AS (
    SELECT match_id, home_team_id AS team_id, away_team_id AS opp_id FROM model.match
    UNION ALL SELECT match_id, away_team_id, home_team_id FROM model.match
)
SELECT t.team_name AS team, tm.matches,
       (SELECT count(*) FROM analysis.goal g WHERE g.team_id = t.team_id)::int AS goals,
       count(*) FILTER (WHERE sd.team_id = t.team_id)::int                       AS shots,
       round(sum(sd.xg) FILTER (WHERE sd.team_id = t.team_id), 2)                AS xg,
       round(sum(sd.xg) FILTER (WHERE sd.team_id = t.team_id AND NOT sd.is_penalty), 2) AS np_xg,
       count(*) FILTER (WHERE sd.team_id = t.team_id AND sd.is_goal AND NOT sd.is_penalty)::int AS np_goals,
       round(sum(sd.xg) FILTER (WHERE sd.team_id <> t.team_id), 2)               AS xg_against,
       (SELECT count(*) FROM analysis.goal g JOIN opp o ON o.match_id = g.match_id AND o.opp_id = g.team_id
         WHERE o.team_id = t.team_id)::int                                        AS goals_against,
       round(count(*) FILTER (WHERE sd.team_id = t.team_id AND sd.is_goal AND NOT sd.is_penalty)
             - sum(sd.xg) FILTER (WHERE sd.team_id = t.team_id AND NOT sd.is_penalty), 2) AS np_goals_minus_xg
FROM model.team t
JOIN team_matches tm USING (team_id)
JOIN opp o ON o.team_id = t.team_id
JOIN analysis.shot_detail sd ON sd.match_id = o.match_id
GROUP BY t.team_id, t.team_name, tm.matches
ORDER BY xg DESC
"""

BENCHMARKS = [
    dict(id="player_timeline", kind="index", index=["event_player_idx"],
         question="Every event by Lionel Messi, in match order",
         sql=f"SELECT match_id, event_index, event_type_id, location_x, location_y FROM model.event "
             f"WHERE player_id = {MESSI} ORDER BY match_id, event_index"),
    dict(id="one_possession", kind="index", index=["event_match_possession_idx"],
         question="Replay one possession of the final",
         sql=f"SELECT event_index, event_type_id, player_id FROM model.event "
             f"WHERE match_id = {FINAL} AND possession = 100 ORDER BY event_index"),
    dict(id="passes_received", kind="index", index=["pass_recipient_idx"],
         question="Every pass Messi received",
         sql=f"SELECT p.event_id, p.end_x, p.end_y FROM model.pass p WHERE p.recipient_id = {MESSI}"),
    dict(id="match_pass_network", kind="rewrite",
         question="Pass network of the final: live view vs materialized view + index on match_id",
         before_sql=f"SELECT * FROM ({{PASS_NETWORK_DEF}}) pn WHERE match_id = {FINAL}",
         sql=f"SELECT * FROM analysis.pass_network WHERE match_id = {FINAL}"),
    dict(id="pass_network_candidate_index", kind="candidate",
         index_ddl="CREATE INDEX event_match_team_type_idx ON model.event (match_id, team_id, event_type_id)",
         question="Live pass-network query with a candidate index (rejected: the materialized view supersedes it)",
         sql=f"SELECT * FROM ({{PASS_NETWORK_DEF}}) pn WHERE match_id = {FINAL}"),
    dict(id="team_xg_control", kind="index",
         index=["event_player_idx", "event_match_possession_idx", "pass_recipient_idx"],
         question="Control: whole-tournament team xG table (a full aggregation; no index should help)",
         sql="SELECT * FROM analysis.team_xg"),
    dict(id="team_xg_rewrite", kind="rewrite",
         question="Team xG table: correlated subqueries per team vs one aggregate per CTE",
         before_sql=TEAM_XG_CORRELATED,
         sql="SELECT * FROM analysis.team_xg"),
    dict(id="game_state_rewrite", kind="rewrite",
         question="Game state for all 64 matches: correlated subqueries vs one window pass",
         before_sql=GAME_STATE_CORRELATED,
         sql="SELECT * FROM analysis.game_state_segment"),
]


def psql(script: str) -> str:
    return subprocess.run(PSQL, input=script, capture_output=True, text=True, check=True, cwd=ROOT).stdout


def explain(sql: str, drop: list[str], setup: str = "") -> dict:
    drops = "".join(f"DROP INDEX model.{i};" for i in drop)
    out = psql(f"BEGIN; {drops} {setup} EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) {sql}; ROLLBACK;")
    return json.loads(out)[0]


def walk(node: dict):
    yield node
    for child in node.get("Plans", []):
        yield from walk(child)


def summarise(plan: dict) -> dict:
    nodes = list(walk(plan["Plan"]))
    scans = sorted({f'{n["Node Type"]}' + (f' on {n["Index Name"]}' if "Index Name" in n else
                                            f' on {n["Relation Name"]}' if "Relation Name" in n else "")
                    for n in nodes if "Scan" in n["Node Type"]})
    top = plan["Plan"]
    return {"ms": plan["Execution Time"],
            "buffers": top.get("Shared Hit Blocks", 0) + top.get("Shared Read Blocks", 0),
            "rows": top.get("Actual Rows"), "scans": scans}


def measure(sql: str, drop: list[str], setup: str = "") -> dict:
    explain(sql, drop, setup)  # warm-up
    runs = sorted((summarise(explain(sql, drop, setup)) for _ in range(RUNS)), key=lambda r: r["ms"])
    median_run = runs[len(runs) // 2]          # RUNS is odd: the true median run
    return {**median_run, "ms": round(median_run["ms"], 2)}


def plan_text(sql: str, drop: list[str], setup: str = "") -> str:
    drops = "".join(f"DROP INDEX model.{i};" for i in drop)
    return psql(f"BEGIN; {drops} {setup} EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF) {sql}; ROLLBACK;").strip()


def main() -> None:
    # the "live" pass network is the materialized view's own defining query
    definition = psql("SELECT pg_get_viewdef('analysis.pass_network'::regclass)").strip().rstrip(";")
    for b in BENCHMARKS:
        for key in ("sql", "before_sql"):
            if key in b:
                b[key] = b[key].replace("{PASS_NETWORK_DEF}", definition)
    results = []
    for b in BENCHMARKS:
        if b["kind"] == "index":
            before = measure(b["sql"], b["index"])
            after = measure(b["sql"], [])
            before_plan, after_plan = plan_text(b["sql"], b["index"]), plan_text(b["sql"], [])
        elif b["kind"] == "candidate":
            setup = b["index_ddl"] + "; ANALYZE model.event;"
            # ANALYZE on both sides so only the index differs
            before = measure(b["sql"], [], "ANALYZE model.event;")
            after = measure(b["sql"], [], setup)
            before_plan, after_plan = plan_text(b["sql"], [], "ANALYZE model.event;"), plan_text(b["sql"], [], setup)
        else:
            before = measure(b["before_sql"], [])
            after = measure(b["sql"], [])
            before_plan, after_plan = plan_text(b["before_sql"], []), plan_text(b["sql"], [])
        speedup = before["ms"] / after["ms"] if after["ms"] else None
        results.append({**{k: b[k] for k in ("id", "kind", "question")}, "index": b.get("index") or ([b["index_ddl"].split()[2]] if b.get("index_ddl") else None),
                        "before": before, "after": after, "speedup": round(speedup, 1) if speedup else None,
                        "before_plan": before_plan, "after_plan": after_plan})
        print(f'{b["id"]:<22} {before["ms"]:>9.2f} ms -> {after["ms"]:>8.2f} ms   x{speedup:.1f}')

    generated = datetime.now(timezone.utc).isoformat(timespec="seconds")
    (ROOT / "site/data").mkdir(parents=True, exist_ok=True)
    (ROOT / "site/data/perf.json").write_text(json.dumps({"generated_at": generated, "runs": RUNS, "results": results}, indent=1))

    lines = [
        "# Query performance evidence", "",
        f"Generated by `make bench` ({RUNS} runs per variant after a warm-up; median execution time "
        "from `EXPLAIN (ANALYZE, BUFFERS)`). PostgreSQL 16 in Docker on a laptop: compare the ratios, not the absolute times.", "",
        "| Benchmark | Change | Before | After | Speed-up | Buffers before → after |",
        "|---|---|---:|---:|---:|---:|",
    ]
    for r in results:
        change = (", ".join(f"`{i}`" for i in r["index"]) if r["kind"] == "index"
                  else "candidate index (not kept)" if r["kind"] == "candidate" else "query rewrite")
        lines.append(f'| {r["question"]} | {change} | {r["before"]["ms"]} ms | {r["after"]["ms"]} ms | '
                     f'×{r["speedup"]} | {r["before"]["buffers"]:,} → {r["after"]["buffers"]:,} |')
    lines += ["", "## Plans", ""]
    for r in results:
        lines += [f'### {r["question"]}', "", "Before:", "", "```", r["before_plan"], "```", "",
                  "After:", "", "```", r["after_plan"], "```", ""]
    (ROOT / "docs/perf").mkdir(parents=True, exist_ok=True)
    (ROOT / "docs/perf/README.md").write_text("\n".join(lines))
    print("bench: wrote docs/perf/README.md and site/data/perf.json")


if __name__ == "__main__":
    main()
