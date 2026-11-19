# CLAUDE.md

Portfolio project: a football analytics database built from **raw StatsBomb event
data** (FIFA World Cup 2022 first), proven correct against independent published
results, with a browser SQL playground on top.

The book *Learn SQL Through Football* (Apress, 2026; cloned at
`../Learn-SQL-Through-Football`) is a **syllabus only**. Its licence forbids reuse in
educational material or blog posts, so never copy its SQL, schemas or seed rows.
Teach the same concepts (constraints, data types, granularity, joins, aggregation)
with this project's own model.

## Commands

| Command | What it does |
|---|---|
| `make all` | Rebuild from raw files: start DB, fetch, load, model, analysis, report, test, playground, playground-test. CI runs this. |
| `make up` | Build and start Postgres 16 + pgTAP (`docker compose`, host port 5433) |
| `make fetch` | Download pinned sources to `data/raw/`; verify `data/checksums.sha256` |
| `make load` | Apply `sql/raw/*.sql`, `sql/audit/*.sql`; load every raw file |
| `make model` | Rebuild `stg` + `model` from raw in one transaction (~16 s) |
| `make analysis` | (Re)create the `analysis` views (analyst questions) |
| `make bench` | `EXPLAIN ANALYZE` before/after for every index and rewrite → `docs/perf/README.md` |
| `make test` | `pg_prove` over `tests/pgtap/`; writes `site/data/tests.tap` |
| `make report` | Writes `site/data/status.json` for the status page |
| `make playground` | Copy the model into PGlite → `site/playground/data/worldcup2022.tar.xz` (~60 s; needs the `xz` command) |
| `make playground-test` | `node --test`: PGlite ≡ Docker Postgres per relation; answer keys accept solutions, reject `wrong` |
| `make serve` | Status page at http://localhost:8000 (auto-refreshes every 5 s) |
| `make psql` | SQL shell. `make lock` re-records checksums after changing a pinned commit. |

Docker runs on **Colima** on this Mac (`colima start` if `docker info` fails).
No host `psql`; always go through `docker compose exec db ...`.

## Architecture (layers, in dependency order)

1. **raw** (`sql/raw/`) — `raw.source_file`: one row per upstream JSON file, payload
   as jsonb, with commit, sha256 and byte size. Never modified by anything downstream.
2. **audit** (`sql/audit/`) — reconciliation views that read raw directly.
   `audit.score_reconciliation` compares three witnesses per match: event-derived goals,
   StatsBomb `matches.json` score, openfootball score (plus shootouts).
3. **stg** (`sql/stg/`) — one jsonb row per record (event, lineup player, match), plus
   `stg.quarantine` for impossible upstream records (kept with a reason, pinned by a test).
4. **model** (`sql/model/`) — typed, constrained tables; event supertype + subtype tables.
   Design decisions and known upstream problems: `docs/model.md`.
5. **analysis** (`sql/analysis/`) — one view per analyst question; each view's COMMENT is the
   question. Catalogue and findings: `docs/analysis.md`.
6. **playground** (`playground/` builds, `site/playground/` serves) — PGlite (Postgres 18
   in WASM) in a Web Worker; `check.js` is shared by page and tests; `challenges.js`
   holds each challenge's `solution` and `wrong` variants.

Pinned sources live in `config/sources.env`. Changing a commit changes the data.

## Rules for this repo

- **Every table and view states its grain** in a header comment and `COMMENT ON`.
- **Correctness means agreement with reality, not with ourselves.** New models get
  pgTAP tests that reconcile against a published, independent figure where one exists
  (official scores, standings, top scorers, the 172-goal tournament total).
- Tests report the offending rows on failure (`is_empty(query)`), never just a count.
- StatsBomb conventions that bite: period 5 is the penalty shootout (not in the score);
  `Own Goal For` is credited to the benefiting team; openfootball `score.et` is
  cumulative and already includes regulation goals; openfootball says `USA` where
  StatsBomb says `United States`; Croatia v Morocco is played twice, so join matches
  on date plus team pair.
- Never fix an upstream problem silently: handle it in SQL, document it in `docs/model.md`
  and the status page, and pin it with a test so a *new* problem fails the build.
- Project agents in `.claude/agents/` load only when the session starts inside this repo;
  from elsewhere, use `general-purpose` with the agent's brief (and `model: haiku` for the profiler).
- **Indexes must earn their place**: add one only with a `scripts/bench.py` benchmark showing
  the gain; record rejected candidates too. Prefer fixing query shape (correlated
  subqueries → one aggregate/window pass) before adding indexes.
- SQL style: lowercase identifiers, uppercase keywords, CTEs over nested subqueries,
  explicit `CROSS JOIN LATERAL jsonb_array_elements(...)` for JSON arrays.
- Attribution: anything published must credit StatsBomb as the data source (and use
  their logo per their open-data README) and credit the book as inspiration.
- **Challenges:** every challenge needs at least one `wrong` variant that the checker
  rejects; never use `LIMIT` where a tie decides the answer (use thresholds, or add
  `tiesAtLimit`). Any analysis SQL must give identical rows in PGlite: round floating
  maths (atan2, sqrt of sums) to a sensible precision, or the parity test fails.
- Stop for user review at the end of each phase (foundation, model, analysis, playground).

## How to work here (Claude)

Use the whole toolkit, sized to the task:

- **Haiku subagents for cheap, mechanical, parallel work**: profiling JSON shapes
  across many files, counting field presence, drafting test boilerplate, summarising
  long logs. Use the `raw-data-profiler` agent (`model: haiku`) in `.claude/agents/`.
- **Parallel subagents** (several `Agent` calls in one message) when tasks are
  independent, e.g. profile events, lineups and 360 data at the same time.
- **`reconciliation-investigator`** when a reconciliation test fails: it traces the
  mismatch back to raw rows and reports evidence. Do not "fix" a test to make it pass.
- **`sql-reviewer`** before closing a phase: an independent read of new SQL for grain
  violations, fan-out joins, NULL handling and wrong StatsBomb conventions. Give it the
  files, not your conclusions.
- `Explore` agent for broad searches; the `superpowers` skills for brainstorming,
  planning, TDD and verification-before-completion; `/code-review` on diffs.
- Verify with real runs (`make all`, the status page) before claiming anything works.
