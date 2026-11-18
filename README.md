# Football analytics in SQL, proven against reality

A PostgreSQL database built from **raw StatsBomb event data** for the 2022 FIFA World
Cup: 234,637 on-ball events across 64 matches. Each derived number is tested against
independently published results.

**Live:** [status page](https://preet-portfolio.github.io/football-analytics-sql/) and
[SQL playground](https://preet-portfolio.github.io/football-analytics-sql/playground/)
(real PostgreSQL in your browser; a 34 MB download on first visit).

```
make all     # rebuild from raw files and run every test (needs Docker and Node 20+)
make serve   # status page at http://localhost:8000, playground at /playground/
```

## Why it's built this way

**Raw data, untouched.** Each upstream file is stored as one `jsonb` row in
`raw.source_file`, along with the git commit it was fetched at and the sha256 and size
of the original bytes. The sources are pinned in `config/sources.env`, and
`data/checksums.sha256` makes every rebuild byte-for-byte reproducible.

**Correctness is defined by the outside world.** `audit.score_reconciliation` checks
each match against three sources:

| Source | What it gives |
|---|---|
| Event-derived score | Goals counted from the raw event stream |
| StatsBomb | The score StatsBomb publishes in `matches.json` |
| [openfootball](https://github.com/openfootball/worldcup.json) | An independent, public-domain record of the results |

The pgTAP suite fails CI if any of these sources disagree, including on penalty
shootouts. As a non-vacuity guard, it also checks the tournament total of **172
goals**. When a test fails, it lists the matches that disagree, not just a count.

**The tests are themselves tested.** Two scoring rules were removed on purpose to
check that the tests catch them:

- Dropping the own-goal rule (StatsBomb's `Own Goal For` event) broke 3 matches.
- Counting shootout kicks (period 5) as goals broke all 5 shootout matches.

## What the data taught (so far)

- openfootball stores `score` in two shapes. Most matches use `{"ft": [h, a], "et": …, "p": …}`;
  7 matches use a bare `[h, a]`. The reconciliation test caught this on its first run.
  The parser handles both shapes, and a guard test fails if a third shape appears.
- Croatia v Morocco was played twice, in the group stage and the third-place match.
  Matches are therefore joined on date plus the unordered team pair, not on team names alone.
- openfootball's `et` score is cumulative (it includes regulation goals). The shootout lives
  only in period 5 of the StatsBomb events.

## The model

`make model` rebuilds 29 typed, constrained tables from raw in one transaction, in about 17 seconds.
The tests also check the model against the outside world and the rules of the game:

- Model-derived goals equal all 64 published scores.
- Top scorers equal FIFA's Golden Boot (Mbappé 8, Messi 7, Álvarez 4, Giroud 4).
- All 8 derived group tables, with tie-breaks, equal the published final standings.
- Each team has 11 players on the pitch, minus dismissals, throughout every period.
  Time on the pitch comes from the event stream, because StatsBomb's lineup positions
  contain 95 phantom spells across 30 matches.

Building the model surfaced more upstream problems, such as Morocco having no group
label and phantom lineup spells. Each is handled and pinned by
a test. Design decisions and the full list are in [docs/model.md](docs/model.md).

## Analysis

13 analyst questions are answered as SQL views (`make analysis`). Examples: group
tables, xG against goals, PPDA pressing, high turnovers, game state, goalkeeper
goals prevented, pass networks, and per-90 output from minutes derived from the
event stream. Each view is checked against published figures or the rules of the
game: assist leaders, shootouts, and match time fully covered by the game-state
segments. The catalogue, findings and metric definitions are in
[docs/analysis.md](docs/analysis.md).

**Performance evidence** (`make bench`, from `EXPLAIN ANALYZE`):

- Three indexes are kept, each 7–12× faster on its own access pattern.
- One candidate index was measured and rejected.
- Two query rewrites (correlated subqueries replaced by window or aggregate
  passes) are 8× and 23× faster.
- A materialized view takes the single-match pass network from 1 s to 0.07 ms.

All plans are in [docs/perf/README.md](docs/perf/README.md).

## SQL playground

`site/playground/` runs the same database in the browser: PostgreSQL 18 compiled to
WebAssembly ([PGlite](https://pglite.dev)), in a Web Worker, with no server. It offers
a schema browser that shows each table's grain, free querying, and 12 progressive challenges
(WHERE → JOINs → GROUP BY/HAVING → NULL semantics → grain and fan-out → intervals →
RANK → running totals → LATERAL → jsonb data quality). Each challenge is checked
automatically against a reference answer. Progress stays in your browser.

`make playground` copies the tested model into PGlite and saves its data directory as
one 33 MB download. `make playground-test` (`node --test`) then proves three things:

- **Parity.** The browser database has the same 48 tables and views as the tested database, with exactly the same
  rows as the pgTAP-tested Postgres 16 (row count plus a hash of every row). This
  test caught a real difference: `atan2()` in the browser's C maths library disagreed
  with Linux in the 15th significant digit for 31 shot angles. The angle is now
  rounded to 6 decimals.
- **Answer keys.** Every reference solution passes the checker. Every challenge also
  lists the classic mistakes it teaches about (counting `outcome` instead of
  `outcome IS NULL`, the fan-out join, `ROW_NUMBER` dropping tied scorers, and so on),
  and each of those mistakes must fail. Challenges that use `LIMIT 1` are checked to
  have no tie at the top, so the answer key never depends on how ties are broken.
- **Isolation.** Learner queries run as a read-only role inside a transaction that is
  always rolled back. PGlite's session user is always a superuser, so `RESET ROLE`
  can't be prevented. Anything done after it is still rolled back, though, and a script
  that ends the transaction (`COMMIT`, `END`) is detected by its transaction id. The
  page then reloads a clean copy. The tests try each of these escapes.
- **Alternatives and near misses.** Challenges also list other correct answers that
  must pass, such as `DISTINCT ON` instead of `LATERAL`, a timestamp instead of a
  date, or other rounding. Integers must match exactly. Other numbers match within
  half a unit of the reference's precision.

`.github/workflows/pages.yml` (run manually) rebuilds everything, runs every test, and
publishes `site/` to GitHub Pages.

## Layout

```
config/sources.env        pinned upstream commits and competition ids
data/checksums.sha256     sha256 of every raw file (data/raw is git-ignored)
docker/postgres/          Postgres 16 + pgTAP + pg_prove image
sql/raw/                  raw layer (one row per file, jsonb)
sql/audit/                reconciliation views over raw
sql/stg/, sql/model/      staging (jsonb per record) and the canonical typed model
sql/analysis/             one view per analyst question
scripts/bench.py          EXPLAIN ANALYZE before/after for every index and rewrite
tests/pgtap/              pgTAP tests, run by `make test` and CI
playground/               builds the PGlite bundle (build.mjs) and tests it (test.mjs)
site/                     status page (index.html) and the SQL playground (playground/)
```

## Roadmap

| Phase | Status |
|---|---|
| Foundation: raw ingest + reconciliation | Done |
| Canonical model: 29 typed tables with the grain stated per table; see [docs/model.md](docs/model.md) | Done |
| 13 analyst questions with `EXPLAIN ANALYZE` evidence; see [docs/analysis.md](docs/analysis.md) | Done |
| Browser SQL playground (PGlite) with 12 auto-checked challenges; Pages workflow ready | Done |

## Credits

- **Data:** [StatsBomb Open Data](https://github.com/statsbomb/open-data). Per StatsBomb's
  terms, published work credits StatsBomb as the data source and shows its logo
  (`site/assets/statsbomb-logo.png`, from StatsBomb's open-data repository).

  [<img src="site/assets/statsbomb-logo.png" alt="StatsBomb" width="220">](https://statsbomb.com)
- **Results:** [openfootball/worldcup.json](https://github.com/openfootball/worldcup.json)
  (public domain).
- **Inspiration:** the concepts follow *Learn SQL Through Football* by Hamed Tabrizchi
  (Apress, 2026). No code or data from the book is used.
