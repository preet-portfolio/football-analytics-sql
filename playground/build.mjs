// Build the browser playground's database: copy the tested model from the Docker
// Postgres into PGlite (Postgres in WebAssembly), create the same analysis views,
// and save PGlite's data directory as one xz-compressed tarball the page loads directly.
//
//   node build.mjs   ->  site/playground/data/worldcup2022.tar.xz
//
// xz instead of gzip because the download is what makes the page slow to open:
// the same tarball is 15 MB as xz -9 and 34 MB as gzip. The browser unpacks it
// with xz-decompress (WebAssembly) while it downloads. Needs the `xz` command.
import { PGlite } from "@electric-sql/pglite";
import { REBUILT_SCHEMAS } from "../site/playground/indexes.js";
import { execFileSync, spawnSync } from "node:child_process";
import { readFileSync, readdirSync, writeFileSync, mkdirSync, statSync, rmSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const OUT = join(ROOT, "site/playground/data/worldcup2022.tar.xz");

// event_relation (330k links) is left out to keep the download small; nothing
// in the playground needs it.
const EXCLUDE = ["model.event_relation"];

const psqlArgs = ["compose", "exec", "-T", "db"];
const docker = (args, opts = {}) =>
  execFileSync("docker", [...psqlArgs, ...args], { cwd: ROOT, maxBuffer: 1 << 30, encoding: "utf8", ...opts });
const sql = (q) => docker(["psql", "-U", "football", "-d", "football", "-qAt", "-c", q]).trim();

const started = Date.now();
const step = (what) => console.log(`[${((Date.now() - started) / 1000).toFixed(1)}s] ${what}`);
for (const ev of ["unhandledRejection", "uncaughtException"]) process.on(ev, (e) => {
  console.error(`build failed: ${e.message}${e.position ? ` (at position ${e.position})` : ""}`);
  process.exit(1);
});
const db = new PGlite();

// 1. Schema: the model schema plus stg.quarantine, exactly as built and tested.
// Two dumps, because pg_dump ignores --schema when --table is also given.
const dumpArgs = ["pg_dump", "-U", "football", "-d", "football", "--schema-only", "--no-owner", "--no-privileges"];
const modelDdl = docker([...dumpArgs, "--schema=model", ...EXCLUDE.flatMap((t) => ["--exclude-table", t])]);
const stgDdl = docker([...dumpArgs, "--table=stg.quarantine"]);
// pg_dump emits psql meta-commands (\restrict, \unrestrict) that are not SQL.
const asSql = (ddl) => ddl.split("\n").filter((l) => !l.startsWith("\\")).join("\n");
await db.exec(asSql(modelDdl));
await db.exec("CREATE SCHEMA stg;"); // --table does not emit the schema itself
await db.exec(asSql(stgDdl));

step("schema created");

// 2. Data: COPY each table out of Docker Postgres and into PGlite as CSV.
const tables = sql(`
  SELECT n.nspname || '.' || c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE c.relkind = 'r' AND (n.nspname = 'model' OR (n.nspname = 'stg' AND c.relname = 'quarantine'))
  ORDER BY 1`).split("\n").filter((t) => !EXCLUDE.includes(t));

await db.exec("SET session_replication_role = replica;"); // load in any order; FKs are already proven in Docker
for (const table of tables) {
  const t0 = Date.now();
  const cols = sql(`SELECT string_agg(quote_ident(attname), ', ' ORDER BY attnum) FROM pg_attribute
                    WHERE attrelid = '${table}'::regclass AND attnum > 0 AND NOT attisdropped AND attgenerated = ''`);
  const csv = docker(["psql", "-U", "football", "-d", "football", "-qAt", "-c",
    `COPY ${table} (${cols}) TO STDOUT WITH (FORMAT csv)`]);
  await db.query(`COPY ${table} (${cols}) FROM '/dev/blob' WITH (FORMAT csv)`, [], { blob: new Blob([csv]) });
  const n = (await db.query(`SELECT count(*)::int AS n FROM ${table}`)).rows[0].n;
  console.log(`  ${table.padEnd(28)} ${String(n).padStart(8)} rows  ${((Date.now() - t0) / 1000).toFixed(1)}s`);
}
await db.exec("SET session_replication_role = origin;");

step("data loaded");

// 3. The same analysis views the test suite checks.
const analysisDir = join(ROOT, "sql/analysis");
for (const f of readdirSync(analysisDir).filter((f) => f.endsWith(".sql")).sort()) {
  await db.exec(readFileSync(join(analysisDir, f), "utf8"));
}

step("analysis views created");

// 4. A read-only role for learner queries. PGlite's session user is always a
// superuser, so a role alone can't stop `RESET ROLE`; the worker also detects any
// script that leaves its rolled-back transaction and reloads a clean copy.
await db.exec(`
  CREATE ROLE learner NOLOGIN;
  GRANT USAGE ON SCHEMA model, analysis, stg TO learner;
  GRANT SELECT ON ALL TABLES IN SCHEMA model, analysis, stg TO learner;
  GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA model, analysis TO learner;
`);
step("role created");
await db.exec("VACUUM ANALYZE;"); // must run outside the implicit transaction of a multi-statement exec

// The bulk load leaves ~170 MB of write-ahead log behind, and a checkpoint only
// renames old segments for reuse. After a checkpoint, every segment except the
// current one is unneeded for recovery, so drop them from the tarball.
step("vacuumed");
await db.exec("CHECKPOINT;");
const keepWal = (await db.query("SELECT pg_walfile_name(pg_current_wal_lsn()) AS f")).rows[0].f;

// Indexes are about half of the compressed download (mostly B-trees of random
// UUIDs, which don't compress), and the browser rebuilds them all from the tables
// in about a second. So ship every index file in these schemas empty, with the
// catalogue (primary keys, foreign keys, unique constraints) untouched; the page
// runs rebuildIndexes() (site/playground/indexes.js) before any query.
const emptied = new Set((await db.query(`
  SELECT pg_relation_filepath(c.oid) AS path FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE c.relkind = 'i' AND n.nspname = ANY($1)`, [REBUILT_SCHEMAS])).rows.map((r) => r.path));

mkdirSync(dirname(OUT), { recursive: true });
step("checkpointed");
const dump = await db.dumpDataDir("none");
step("dumped");
// Recovery in the browser starts at the checkpoint's redo point and stops at the
// end of the log, after reading the segment's first page to check its header.
// The rest of the kept segment is leftover bytes from a recycled file, which
// compress badly, so they are zeroed (zeros read as "end of log").
const wal = (await db.query(`
  SELECT redo_lsn::text AS redo, pg_walfile_name(redo_lsn) AS redo_file,
         pg_current_wal_insert_lsn()::text AS "end", pg_walfile_name(pg_current_wal_insert_lsn()) AS end_file,
         (SELECT setting::bigint FROM pg_settings WHERE name = 'wal_segment_size') AS seg, current_setting('wal_block_size')::int AS page
  FROM pg_control_checkpoint()`)).rows[0];
if (wal.redo_file !== keepWal || wal.end_file !== keepWal) throw new Error(`WAL moved on after the checkpoint: ${JSON.stringify(wal)}`);
const lsn = (t) => { const [hi, lo] = t.split("/"); return (BigInt("0x" + hi) << 32n) | BigInt("0x" + lo); };
const inSegment = (t) => Number(lsn(t) % BigInt(wal.seg));
const walKeep = { from: Math.floor(inSegment(wal.redo) / wal.page) * wal.page, to: Math.ceil(inSegment(wal.end) / wal.page) * wal.page, page: wal.page };
const tar = slimTar(Buffer.from(await dump.arrayBuffer()), keepWal, emptied, walKeep);
step("stale WAL dropped, indexes emptied");
// -9 without -e: -9e saves under 0.1 MB and takes half as long again.
const xz = spawnSync("xz", ["-9", "-T1", "-c"], { input: tar, maxBuffer: 1 << 30 });
if (xz.error || xz.status !== 0) throw new Error(`xz failed: ${xz.error?.message ?? xz.stderr}. Install xz (brew install xz / apt install xz-utils).`);
writeFileSync(OUT, xz.stdout);
rmSync(join(dirname(OUT), "worldcup2022.tar.gz"), { force: true }); // the old gzip bundle
step("compressed");
const version = (await db.query("SELECT version() AS v")).rows[0].v.split(" on ")[0];
await db.close();
writeFileSync(join(dirname(OUT), "manifest.json"), JSON.stringify({
  file: "worldcup2022.tar.xz", bytes: statSync(OUT).size, unpacked_bytes: tar.length, empty_indexes: emptied.size, postgres: version,
  pglite: JSON.parse(readFileSync(join(ROOT, "playground/node_modules/@electric-sql/pglite/package.json"), "utf8")).version,
  tables: tables.length, built_at: new Date().toISOString(),
}, null, 2));
console.log(`playground: wrote ${OUT.replace(ROOT + "/", "")} (${(statSync(OUT).size / 1e6).toFixed(1)} MB) in ${((Date.now() - started) / 1000).toFixed(0)}s`);

// Copy a ustar archive, skipping pg_wal segment files other than `keep` (and
// zeroing that one outside its first page and walKeep.from..to), and writing the
// files in `empty` (paths relative to the data directory) as 0 bytes.
function slimTar(tar, keep, empty, walKeep) {
  const out = [];
  let dropped = 0, emptied = 0;
  for (let off = 0; off + 512 <= tar.length; ) {
    const header = tar.subarray(off, off + 512);
    if (header.every((b) => b === 0)) { out.push(tar.subarray(off)); break; }
    const name = header.subarray(0, 100).toString("utf8").replace(/\0.*$/s, "");
    const size = parseInt(header.subarray(124, 136).toString("utf8").replace(/\0.*$/s, "").trim() || "0", 8);
    const end = off + 512 + Math.ceil(size / 512) * 512;
    const seg = name.match(/pg_wal\/([0-9A-F]{24})$/);
    const rel = name.match(/(base\/\d+\/\d+)$/);
    if (seg && seg[1] !== keep) dropped++;
    else if (seg) {
      const body = Buffer.alloc(size);
      const src = tar.subarray(off + 512, off + 512 + size);
      src.copy(body, 0, 0, walKeep.page);
      src.copy(body, walKeep.from, walKeep.from, walKeep.to);
      out.push(header, body, Buffer.alloc(end - off - 512 - size));
      console.log(`  kept WAL bytes ${walKeep.from}..${walKeep.to} of ${size}`);
    } else if (rel && empty.has(rel[1])) { out.push(withSize(header, 0)); emptied++; }
    else out.push(tar.subarray(off, end));
    off = end;
  }
  if (emptied !== empty.size) throw new Error(`emptied ${emptied} of ${empty.size} index files; tar layout changed?`);
  console.log(`  dropped ${dropped} stale WAL segments (kept ${keep}), emptied ${emptied} index files`);
  return Buffer.concat(out);
}

// A copy of a ustar header with a new size field and checksum.
function withSize(header, size) {
  const h = Buffer.from(header);
  h.write(size.toString(8).padStart(11, "0") + "\0", 124, 12, "ascii");
  h.fill(0x20, 148, 156);
  let sum = 0;
  for (const b of h) sum += b;
  h.write(sum.toString(8).padStart(6, "0") + "\0 ", 148, 8, "ascii");
  return h;
}
