// Runs PGlite (PostgreSQL compiled to WebAssembly) off the main thread, so a slow
// query never freezes the page and "Stop" can simply terminate this worker.
import { PGlite } from "https://cdn.jsdelivr.net/npm/@electric-sql/pglite@0.5.14/dist/index.js";
import { runLearnerSql } from "./runner.js";

const DATA = new URL("./data/worldcup2022.tar.gz", self.location.href);
let db, bundle;

async function load() {
  const res = await fetch(DATA);
  if (!res.ok) throw new Error(`Couldn't download the database (${res.status}). Run \`make playground\` to build it.`);
  const total = Number(res.headers.get("content-length")) || 0;
  const reader = res.body.getReader();
  const chunks = [];
  let got = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    chunks.push(value);
    got += value.length;
    postMessage({ type: "progress", got, total });
  }
  postMessage({ type: "progress", got, total, unpacking: true });
  bundle = new Blob(chunks);
  db = await PGlite.create({ loadDataDir: bundle });
  const v = await db.query("SELECT version() AS v");
  postMessage({ type: "ready", version: v.rows[0].v.split(" on ")[0] });
}

// See runner.js for how learner scripts are isolated. If a script escaped its
// transaction, throw this database away and start again from the downloaded copy.
async function run(sql) {
  try {
    return await runLearnerSql(db, sql);
  } catch (e) {
    if (e.escaped) {
      await db.close().catch(() => {});
      db = await PGlite.create({ loadDataDir: bundle });
      postMessage({ type: "reloaded" });
    }
    throw e;
  }
}

// Read-only catalogue queries for the schema browser, run as the owner.
async function schema() {
  const { rows } = await db.query(`
    SELECT n.nspname AS schema, c.relname AS name, c.relkind AS kind,
           obj_description(c.oid, 'pg_class') AS comment,
           json_agg(json_build_object('name', a.attname, 'type', format_type(a.atttypid, a.atttypmod))
                    ORDER BY a.attnum) AS columns
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
    WHERE n.nspname IN ('model', 'analysis', 'stg') AND c.relkind IN ('r', 'v', 'm')
    GROUP BY n.nspname, c.relname, c.relkind, c.oid
    ORDER BY n.nspname = 'analysis', n.nspname, c.relname`);
  return rows;
}

onmessage = async ({ data }) => {
  const { id, type, sql } = data;
  try {
    if (type === "load") return await load();
    const result = type === "schema" ? await schema() : await run(sql);
    postMessage({ id, ok: true, result });
  } catch (e) {
    const where = e.position ? Number(e.position) : null;
    postMessage({ id, ok: false, error: e.message, hint: e.hint ?? null, position: where, type: type === "load" ? "load-error" : undefined });
  }
};
