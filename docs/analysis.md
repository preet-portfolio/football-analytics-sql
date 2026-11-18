# Analysis: 13 analyst questions, answered in SQL

Every question is a view in the `analysis` schema (`make analysis`), and each
view's `COMMENT` states the question. Run `SELECT * FROM analysis.<name>;`.
The numbers below come from the 2022 World Cup data and are recomputed on
every build. The test suite also checks every published figure listed under
"Checked against".

| # | View | Question | SQL techniques |
|---|---|---|---|
| 1 | `group_table` | What were the final group tables? | `UNION ALL` to turn matches into team-match rows, `FILTER` aggregates, `RANK()` with a multi-key tie-break |
| 2 | `team_game_state` | How long did each team spend leading, level and trailing? | `SUM() OVER` running score, `LEAD()` segment ends, time split by period |
| 3 | `shootout` | How did each penalty shootout go? | Conditional aggregation over period 5 |
| 4 | `team_xg` | Who created the best chances, and who finished above them? | One aggregate per CTE, joined at team grain |
| 5 | `player_finishing` | Which players scored more or less than their chances were worth? | `HAVING` threshold, derived ratios |
| 6 | `shot_zones` | How does conversion fall with distance, and does xG track it? | `WIDTH_BUCKET`, trigonometry (`atan2`) for the goal angle |
| 7 | `goalkeeper` | Which keepers conceded fewer goals than the xG they faced? | Time-windowed join of shots to the keeper on the pitch (row-value comparison) |
| 8 | `team_ppda` | Who pressed hardest? | Coordinate-zone filters, per-team ratio of two aggregates |
| 9 | `team_possession` | How did teams use the ball? | One row per possession, then per period to handle the clock reset |
| 10 | `team_high_turnovers` | Who won the ball high, and did it lead to shots? | `DISTINCT ON`, `LAG()`, `LATERAL ... LIMIT 1` |
| 11 | `pass_network` / `final_pass_network` | Who passed to whom, and where, before the first substitution? | `LATERAL` cut-off, a materialized view with an index |
| 12 | `player_per90` | Who contributed most per 90 minutes? | Event-derived minutes, progressive-pass geometry, xA via `assisted_shot_id` |
| 13 | `substitute_impact` | How much did each bench contribute? | Aggregating before joining (avoids fan-out) |

## Findings

- **Finishing.** The Netherlands scored 10 goals from 4.99 xG, the biggest
  overperformance. Brazil scored 8 from 10.5 xG, the biggest underperformance.
  Mbappé scored 6 non-penalty goals from 2.67 xG (+3.33). Lautaro Martínez had
  2.12 xG and no non-penalty goals.
- **Is xG calibrated?** Mostly yes. Conversion by distance band follows mean xG
  closely: 0–6 yd 44% vs 43%, 12–18 yd 12.6% vs 10.5%, 24–30 yd 2.3% vs 2.9%.
  The 36+ yd band is a single goal from 22 shots.
- **Pressing.** Mexico (PPDA 8.3) and Spain (9.0) pressed hardest. Costa Rica
  (28.3) and Qatar (22.5) sat deepest.
- **Ball use.** Spain averaged 10.2 passes per possession, a clear outlier.
- **Game state.** Argentina led for 51% of their minutes and trailed for only 51 minutes in 7 matches.
- **Goalkeeping.** Courtois, Lloris, Noppert and Bounou each conceded about 2
  goals fewer than the xG they faced.
- **Benches.** Germany's substitutes scored 4 of its 6 goals.
- **Shootouts.** 41 kicks, 26 scored, 10 saved, 5 missed (63% conversion).

## Metric definitions and caveats

- **xG** is StatsBomb's pre-shot model. Non-penalty xG excludes penalties.
  Shootout kicks are excluded everywhere.
- **Goals prevented** = xG of all shots faced − goals conceded. Open data has
  no post-shot xG. Using only on-target shots would bias every keeper negative,
  because being on target raises the scoring chance above the pre-shot xG. Using
  all shots is unbiased, but it also credits the defence for forcing misses.
- **PPDA** = opponent passes in their own 60% ÷ our tackles, interceptions,
  fouls and challenges in that zone.
- **High turnover** = we win the ball in open play within 40 m of their goal.
  StatsBomb's `play_pattern` can't identify these, so the view uses the first
  event of a possession plus an allow-list of ball-winning actions.
- **Progressive pass** = a completed open-play pass that ends at least 25% closer
  to the centre of the goal.
- **Per 90** uses event-derived minutes with stoppage time included (`model.appearance`), with a minimum of 270 minutes.

## Checked against

The analysis tests (`tests/pgtap/006_analysis.sql`) check:

- **Published results:** the group tables (all 32 teams), the assist leaders
  (five players on 3), the shootout results (against openfootball), and Messi
  playing every minute.
- **Rules of the game:** game-state segments cover every second of all 128
  team-matches, one team's leading time equals the other's trailing time, and
  the final segment shows the final score.
- **Regressions from the independent review:**
  - substitutes are counted once each;
  - possession time excludes half-time;
  - every shot is faced by exactly one keeper, including an outfielder who went
    in goal;
  - turnovers exclude stoppages;
  - each player has one position on the pass network.

## What the review caught

The independent review agent found four wrong answers that the first tests missed:

1. A substitute who scored twice was counted twice.
2. Possessions that straddled half-time were up to 59 minutes long, because the clock restarts each period.
3. Daniel Ward went in goal for Wales, but StatsBomb lists him as a midfielder, so 7 shots faced vanished.
4. 15% of "high turnovers" were drop-balls or set pieces.

Each is fixed and now pinned by a regression test. Fixing the pass network
initially made a single match 250× slower. Making it a materialized view with
an index fixed that: see [perf/README.md](perf/README.md).
