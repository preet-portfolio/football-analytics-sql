// Runs PGlite (PostgreSQL compiled to WebAssembly) off the main thread, so a slow
// query never freezes the page and "Stop" can simply terminate this worker.
import { PGlite } from "https://cdn.jsdelivr.net/npm/@electric-sql/pglite@0.5.14/dist/index.js";
import xzDecompress from "https://cdn.jsdelivr.net/npm/xz-decompress@0.2.3/+esm"; // CommonJS: only a default export
import { runLearnerSql } from "./runner.js";
import { rebuildIndexes } from "./indexes.js";

const DATA_DIR = new URL("./data/", self.location.href);
const SAVED = "wc22-database"; // Cache Storage bucket holding the unpacked tarball
const PGLITE = "https://cdn.jsdelivr.net/npm/@electric-sql/pglite@0.5.14/dist/";
let db, bundle, runtime;
let indexed = false; // does `bundle` already have its indexes? (the download doesn't)

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

async function open() {
  const fresh = await PGlite.create({ ...runtime, loadDataDir: bundle });
  if (!indexed) {
    postMessage({ type: "progress", status: "Building indexes…" });
    await rebuildIndexes(fresh);
  }
  return fresh;
}

// Repeat visits skip the download, the xz unpacking and the index rebuild: once
// the indexes are built, the data directory is saved in Cache Storage, keyed by
// the build's timestamp from manifest.json, so a new build replaces it. It is
// saved before the first learner query can run, and never written to afterwards
// (PGlite works on its own in-memory copy), so Reset and the reload after an
// escape start from it too.
async function load() {
  const runtimeReady = prefetchRuntime();
  const build = await fetch(new URL("manifest.json", DATA_DIR), { cache: "no-cache" })
    .then((r) => (r.ok ? r.json() : null))
    .catch(() => null);
  const key = build && new URL(`${build.file}?built=${encodeURIComponent(build.built_at)}`, DATA_DIR);
  bundle = await savedCopy(key);
  const fromSaved = indexed = Boolean(bundle);
  if (!bundle) {
    if (!key) throw new Error("Couldn't reach the site to download the database. Check your connection and reload.");
    bundle = await download(key);
  }
  postMessage({ type: "progress", status: "Starting PostgreSQL…" });
  runtime = await runtimeReady;
  db = await open();
  if (!fromSaved) {
    await db.exec("CHECKPOINT;");
    bundle = await db.dumpDataDir("none");
    indexed = true;
    save(key, bundle); // in the background
  }
  const v = await db.query("SELECT version() AS v");
  postMessage({ type: "ready", version: v.rows[0].v.split(" on ")[0], saved: fromSaved });
}

// The saved copy for this build; offline (no manifest), any saved copy.
async function savedCopy(key) {
  try {
    const cache = await caches.open(SAVED);
    const hit = key ? await cache.match(key) : (await cache.matchAll())[0];
    return hit ? await hit.blob() : null;
  } catch {
    return null; // storage blocked (private mode, quota): download as usual
  }
}

async function save(key, blob) {
  try {
    const cache = await caches.open(SAVED);
    for (const old of await cache.keys()) if (old.url !== key.href) await cache.delete(old);
    await cache.put(key, new Response(blob, { headers: { "content-type": blob.type || "application/x-tar" } }));
  } catch {
    // Not saved; the next visit downloads again.
  }
}

// The build's timestamp is in the URL, so a stale HTTP-cached file from an
// older build can't be saved under the new build's key.
async function download(url) {
  let note = null; // shown with the progress after a failed attempt
  for (let attempt = 1; ; attempt++) {
    try {
      return await downloadOnce(url, note);
    } catch (e) {
      if (!e.retry) throw e;
      if (attempt === ATTEMPTS) throw new Error(`The database download ${e.message} ${ATTEMPTS} times. Check your connection and reload the page.`);
      note = `the last attempt ${e.message}; attempt ${attempt + 1} of ${ATTEMPTS}`;
      postMessage({ type: "progress", got: 0, total: 0, note });
    }
  }
}

// Downloads from GitHub Pages occasionally stop sending bytes without failing,
// which would leave the page at "Downloading…" forever. If nothing arrives for
// STALL_MS (including before the response starts), give up on this attempt and
// start again, bypassing the HTTP cache in case it holds the broken response.
const STALL_MS = 15000;
const ATTEMPTS = 3;

async function downloadOnce(url, note) {
  const abort = new AbortController();
  let stalled = false, timer;
  const watch = () => {
    clearTimeout(timer);
    timer = setTimeout(() => { stalled = true; abort.abort(); }, STALL_MS);
  };
  const retryable = (message) => Object.assign(new Error(message), { retry: true });
  watch();
  try {
    let res;
    try {
      res = await fetch(url, { signal: abort.signal, cache: note ? "no-store" : "default" });
    } catch (e) {
      throw retryable(stalled ? "stalled" : "failed");
    }
    if (res.status >= 500) throw retryable(`failed (${res.status})`);
    if (!res.ok) throw new Error(`Couldn't download the database (${res.status}). Run \`make playground\` to build it.`);
    const total = Number(res.headers.get("content-length")) || 0;
    // Count compressed bytes for the progress bar, and unpack while downloading.
    let got = 0;
    const counted = res.body.pipeThrough(new TransformStream({
      transform(chunk, ctl) {
        watch();
        got += chunk.length;
        postMessage({ type: "progress", got, total, note });
        ctl.enqueue(chunk);
      },
    }));
    try {
      return await new Response(new xzDecompress.XzReadableStream(counted)).blob();
    } catch (e) {
      if (stalled || e instanceof TypeError) throw retryable(stalled ? "stalled" : "failed");
      throw e; // a corrupt file: retrying won't help
    }
  } finally {
    clearTimeout(timer);
  }
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
