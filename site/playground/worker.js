// Runs PGlite (PostgreSQL compiled to WebAssembly) off the main thread, so a slow
// query never freezes the page and "Stop" can simply terminate this worker.
import { PGlite } from "https://cdn.jsdelivr.net/npm/@electric-sql/pglite@0.5.14/dist/index.js";
import xzDecompress from "https://cdn.jsdelivr.net/npm/xz-decompress@0.2.3/+esm"; // CommonJS: only a default export
import { runLearnerSql } from "./runner.js";

const DATA = new URL("./data/worldcup2022.tar.xz", self.location.href);
const PGLITE = "https://cdn.jsdelivr.net/npm/@electric-sql/pglite@0.5.14/dist/";
let db, bundle, runtime;

// PGlite would only fetch its engine (pglite.wasm) and base files (pglite.data)
// once the database had finished downloading. Fetch and compile them alongside
// it instead, and keep them for the reload after an escape. If prefetching fails,
// PGlite.create falls back to fetching them itself.
function prefetchRuntime() {
  const wasm = WebAssembly.compileStreaming(fetch(PGLITE + "pglite.wasm"));
  const data = fetch(PGLITE + "pglite.data").then((r) => (r.ok ? r.blob() : Promise.reject(new Error(r.status))));
  return Promise.all([wasm, data])
    .then(([pgliteWasmModule, fsBundle]) => ({ pgliteWasmModule, fsBundle }))
    .catch(() => ({}));
}

const open = () => PGlite.create({ ...runtime, loadDataDir: bundle });

async function load() {
  const runtimeReady = prefetchRuntime();
  const res = await fetch(DATA);
  if (!res.ok) throw new Error(`Couldn't download the database (${res.status}). Run \`make playground\` to build it.`);
  const total = Number(res.headers.get("content-length")) || 0;
  // Count compressed bytes for the progress bar, and unpack while downloading.
  let got = 0;
  const counted = res.body.pipeThrough(new TransformStream({
    transform(chunk, ctl) {
      got += chunk.length;
      postMessage({ type: "progress", got, total });
      ctl.enqueue(chunk);
    },
  }));
  bundle = await new Response(new xzDecompress.XzReadableStream(counted)).blob();
  postMessage({ type: "progress", got, total, unpacking: true });
  runtime = await runtimeReady;
  db = await open();
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
      db = await open();
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
