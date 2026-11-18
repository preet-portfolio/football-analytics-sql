# Football analytics in SQL, proven against reality

A PostgreSQL database built from **raw StatsBomb event data** for the 2022 FIFA World
Cup: 234,637 on-ball events across 64 matches. Each derived number is tested against
independently published results.

```
make all     # rebuild from raw files and run every test (needs Docker)
make serve   # status page at http://localhost:8000
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

## Layout

```
config/sources.env        pinned upstream commits and competition ids
data/checksums.sha256     sha256 of every raw file (data/raw is git-ignored)
docker/postgres/          Postgres 16 + pgTAP + pg_prove image
sql/raw/                  raw layer (one row per file, jsonb)
sql/audit/                reconciliation views over raw
tests/pgtap/              pgTAP tests, run by `make test` and CI
site/                     local status page (later: the browser SQL playground)
```

## Roadmap

| Phase | Status |
|---|---|
| Foundation: raw ingest + reconciliation | Done |
| Canonical model: competition, season, team, player, match, lineup, event, shot, pass…, with the grain documented per table | Next |
| 10–15 analyst queries (group tables, xG vs goals, pass networks, pressures per 90) with `EXPLAIN ANALYZE` evidence | Planned |
| Browser SQL playground (DuckDB-WASM or PGlite) with auto-checked challenges, on GitHub Pages | Planned |

## Credits

- **Data:** [StatsBomb Open Data](https://github.com/statsbomb/open-data). Per StatsBomb's
  terms, published work must credit StatsBomb as the data source and use its logo.
- **Results:** [openfootball/worldcup.json](https://github.com/openfootball/worldcup.json)
  (public domain).
- **Inspiration:** the concepts follow *Learn SQL Through Football* by Hamed Tabrizchi
  (Apress, 2026). No code or data from the book is used.
