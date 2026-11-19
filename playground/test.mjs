// Playground tests (node --test). Needs the built bundle (`make playground`)
// and, for the parity test, the Docker database (`make up`).
//
// 1. Parity: every table and analysis view in the browser database has exactly
//    the same rows as the pgTAP-tested Postgres 16 database.
// 2. Isolation: no learner script can change the data the next query sees.
// 3. Answer keys: every reference solution passes the checker, every listed
//    alternative correct answer passes, and every listed wrong answer fails.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { PGlite } from "@electric-sql/pglite";
import xzDecompress from "xz-decompress"; // the same decoder (and version) the page loads from jsDelivr
import { challenges } from "../site/playground/challenges.js";
import { checkResult } from "../site/playground/check.js";
import { runLearnerSql } from "../site/playground/runner.js";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const BUNDLE = join(ROOT, "site/playground/data/worldcup2022.tar.xz");
let db;

// Same execution path as the page's worker.
const runAsLearner = (sql) => runLearnerSql(db, sql);

before(async () => {
  const tar = await new Response(new xzDecompress.XzReadableStream(new Blob([readFileSync(BUNDLE)]).stream())).blob();
  db = await PGlite.create({ loadDataDir: tar });
});
after(() => db?.close());

// One fingerprint per relation: row count + md5 over the sorted per-row md5s.
// Sorting by md5 keeps it independent of collation and physical order.
const fingerprintSql = (rel) => `
  SELECT count(*) || ':' || md5(coalesce(string_agg(h, '' ORDER BY h), ''))
  FROM (SELECT md5(t::text) AS h FROM ${rel} t) x`;

test("parity: browser database matches the tested Postgres, relation by relation", async (t) => {
  const psql = (q) =>
    execFileSync("docker", ["compose", "exec", "-T", "db", "psql", "-U", "football", "-d", "football", "-qAt", "-c", q],
      { cwd: ROOT, encoding: "utf8", maxBuffer: 1 << 26, stdio: ["ignore", "pipe", "pipe"] }).trim();
  const rels = (await db.query(`
    SELECT n.nspname || '.' || c.relname AS rel FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname IN ('model', 'analysis', 'stg') AND c.relkind IN ('r', 'v', 'm') ORDER BY 1`)).rows.map((r) => r.rel);
  // The list comes from the tested database, so a relation missing from the bundle fails.
  const expectedRels = psql(`
    SELECT n.nspname || '.' || c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE (n.nspname IN ('model', 'analysis') OR (n.nspname, c.relname) = ('stg', 'quarantine'))
      AND c.relkind IN ('r', 'v', 'm') AND n.nspname || '.' || c.relname <> 'model.event_relation'
    ORDER BY 1`).split("\n");
  assert.deepEqual(rels, expectedRels, "the browser database has a different set of tables and views");
  for (const rel of rels) {
    await t.test(rel, async () => {
      const browser = (await db.query(fingerprintSql(rel), [], { rowMode: "array" })).rows[0][0];
      assert.equal(browser, psql(fingerprintSql(rel)));
    });
  }
});

test("isolation: no learner script changes what the next query sees", async () => {
  const counts = async () => (await db.query(
    "SELECT (SELECT count(*) FROM model.match)::int AS m, (SELECT count(*) FROM model.card)::int AS c, to_regclass('model.event_type') IS NOT NULL AS t")).rows[0];
  const before = await counts();
  await assert.rejects(runAsLearner("DELETE FROM model.match"), /permission denied/);
  await assert.rejects(runAsLearner("DROP TABLE model.team"), /must be owner/);
  // Privilege tricks inside the transaction are rolled back with it.
  await runAsLearner("RESET ROLE; DELETE FROM model.card; SELECT 1");
  await runAsLearner("SET ROLE postgres; DELETE FROM model.card; SELECT 1");
  assert.deepEqual(await counts(), before, "a role switch inside the transaction changed data");
  // Leaving the transaction is detected (the page then reloads a clean copy).
  for (const escape of ["COMMIT; SELECT 1", "ROLLBACK; SELECT 1", "END; SELECT 1", "COMMIT; BEGIN; SELECT 1"]) {
    await assert.rejects(runAsLearner(escape), (e) => e.escaped === true, `not detected: ${escape}`);
  }
  // Errors inside the transaction are ordinary errors, not escapes.
  await assert.rejects(runAsLearner("SELECT 1/0"), (e) => !e.escaped && /division by zero/.test(e.message));
  assert.deepEqual(await counts(), before);
});

for (const c of challenges) {
  test(`challenge ${c.id}: answer key accepts the solution and rejects the mistakes`, async () => {
    const expected = await runAsLearner(c.solution);
    assert.ok(expected.rows.length > 0, "the reference answer returns no rows");
    assert.ok(checkResult(expected, expected, c).ok, "the reference answer fails its own check");
    if (c.tiesAtLimit) {
      const ties = (await db.query(c.tiesAtLimit, [], { rowMode: "array" })).rows[0][0];
      assert.equal(Number(ties), 0, "the answer depends on how ties are broken");
    }
    for (const [i, alt] of (c.alsoCorrect ?? []).entries()) {
      const verdict = checkResult(expected, await runAsLearner(alt), c);
      assert.ok(verdict.ok, `alternative correct answer #${i + 1} was rejected: ${verdict.message}`);
    }
    assert.ok(c.wrong.length > 0, "every challenge needs at least one wrong answer");
    for (const [i, w] of c.wrong.entries()) {
      const verdict = checkResult(expected, await runAsLearner(w), c);
      assert.equal(verdict.ok, false, `wrong answer #${i + 1} was accepted`);
    }
  });
}

test("checker: numbers, types, NULLs, dates, intervals and order", () => {
  const res = (rows, types) => ({ fields: rows[0].map((_, i) => ({ name: `c${i}`, dataTypeID: types?.[i] })), rows });
  const NUMERIC = 1700, INT8 = 20, TEXT = 25, INTERVAL = 1186, DATE = 1082, TS = 1114;
  const exp = res([["61.3", 2n], [null, 1n], ["84.9", 3n]], [NUMERIC, INT8]);
  assert.ok(checkResult(exp, res([[61.29, 2], [null, 1], [84.85, 3]], [701, 23])).ok, "within half a unit of the reference precision");
  assert.ok(checkResult(exp, res([[null, 1], ["61.3", 2], ["84.9", 3]], [NUMERIC, INT8])).ok, "order ignored by default");
  assert.ok(!checkResult(exp, res([[null, 1], ["61.3", 2], ["84.9", 3]], [NUMERIC, INT8]), { orderMatters: true }).ok, "order enforced when asked");
  assert.ok(!checkResult(exp, res([["61.5", 2], [null, 1], ["84.9", 3]], [NUMERIC, INT8])).ok, "wrong value");
  assert.ok(!checkResult(exp, res([["61.3", 2], ["0", 1], ["84.9", 3]], [NUMERIC, INT8])).ok, "NULL is not 0");
  assert.ok(!checkResult(exp, res([["61.3", "2.4"], [null, 1], ["84.9", 3]], [NUMERIC, NUMERIC])).ok, "integers must be exact");
  assert.ok(!checkResult(exp, res([["61.3", "2"], [null, "1"], ["84.9", "3"]], [NUMERIC, TEXT])).ok, "text is not a number");
  assert.ok(!checkResult(exp, res([["61.3", 2], [null, 1]], [NUMERIC, INT8])).ok, "missing row");
  assert.ok(!checkResult(res([["7"]], [TEXT]), res([[7]], [23])).ok, "a number is not text");
  assert.ok(!checkResult(res([["∅"]], [TEXT]), res([[null]], [TEXT])).ok, "NULL is not a string that looks like one");
  assert.ok(checkResult(res([["9007199254740993"]], [INT8]), res([["9007199254740993"]], [INT8])).ok, "bigint precision kept");
  assert.ok(!checkResult(res([["9007199254740993"]], [INT8]), res([["9007199254740992"]], [INT8])).ok, "bigint off by one");
  assert.ok(checkResult(res([["2022-12-18"]], [DATE]), res([["2022-12-18 00:00:00"]], [TS])).ok, "a date equals midnight");
  assert.ok(!checkResult(res([["2022-12-18"]], [DATE]), res([["2022-12-18 15:00:00"]], [TS])).ok, "but not 3 pm");
  assert.ok(checkResult(res([["02:10:57.392"]], [INTERVAL]), res([["02:10:57"]], [INTERVAL])).ok, "intervals to the second");
  assert.ok(!checkResult(res([["02:10:57.392"]], [INTERVAL]), res([["02:10:55"]], [INTERVAL])).ok, "but not 2 s off");
  assert.ok(checkResult(res([["1 day 01:00:00"]], [INTERVAL]), res([["25:00:00"]], [INTERVAL])).ok, "days and hours");
  assert.ok(!checkResult(exp, { fields: [{ name: "a" }], rows: [[61.3], [null], [84.9]] }).ok, "missing column");
});
