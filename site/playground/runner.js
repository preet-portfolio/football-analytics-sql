// Run one learner script against a PGlite instance. Shared by worker.js and
// playground/test.mjs, so the isolation the tests prove is the isolation the page has.
//
// Every script runs as the read-only `learner` role inside a transaction that is
// always rolled back. PGlite's session user is a superuser, so a script could
// `RESET ROLE` - but anything it does then is still rolled back, unless it also
// ends the transaction (COMMIT, ROLLBACK, END). That is detectable: we give our
// transaction an id up front, and if the id isn't ours afterwards, the script
// left our transaction and may have changed data. The caller must then reload.
// (now() can't be used: PGlite's clock is too coarse to tell two transactions apart.)
import { TEXT_PARSERS } from "./check.js";

export async function runLearnerSql(db, sql) {
  const started = performance.now();
  await db.exec("BEGIN; SET LOCAL ROLE learner;");
  const txId = (await db.query("SELECT pg_current_xact_id()::text AS t")).rows[0].t;

  let results, error;
  try {
    results = await db.exec(sql, { rowMode: "array", parsers: TEXT_PARSERS });
  } catch (e) {
    error = e;
  }

  // Still inside our transaction? An aborted transaction (error 25P02) also counts.
  let escaped;
  try {
    escaped = (await db.query("SELECT pg_current_xact_id_if_assigned()::text AS t")).rows[0].t !== txId;
  } catch (e) {
    escaped = e.code !== "25P02";
  }
  await db.exec("ROLLBACK;").catch(() => {});

  if (escaped) {
    const err = new Error("Transaction control (COMMIT, ROLLBACK, BEGIN) isn't allowed here, because every query runs in a transaction that is rolled back. A clean copy of the database has been loaded.");
    err.escaped = true;
    throw err;
  }
  if (error) throw error;

  const last = results.filter((r) => r.fields.length > 0).at(-1) ?? null;
  return {
    fields: last ? last.fields.map((f) => ({ name: f.name, dataTypeID: f.dataTypeID })) : [],
    rows: last ? last.rows : [],
    ms: performance.now() - started,
  };
}
