// Build the browser playground's database: copy the tested model from the Docker
// Postgres into PGlite (Postgres in WebAssembly), create the same analysis views,
// and save PGlite's data directory as one gzipped tarball the page loads directly.
//
//   node build.mjs   ->  site/playground/data/worldcup2022.tar.gz
import { PGlite } from "@electric-sql/pglite";
import { execFileSync } from "node:child_process";
import { readFileSync, readdirSync, writeFileSync, mkdirSync, statSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { gzipSync } from "node:zlib";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const OUT = join(ROOT, "site/playground/data/worldcup2022.tar.gz");

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

mkdirSync(dirname(OUT), { recursive: true });
step("checkpointed");
const dump = await db.dumpDataDir("none");
step("dumped");
const tar = withoutStaleWal(Buffer.from(await dump.arrayBuffer()), keepWal);
step("stale WAL dropped");
writeFileSync(OUT, gzipSync(tar));
step("compressed");
const version = (await db.query("SELECT version() AS v")).rows[0].v.split(" on ")[0];
await db.close();
writeFileSync(join(dirname(OUT), "manifest.json"), JSON.stringify({
  file: "worldcup2022.tar.gz", bytes: statSync(OUT).size, postgres: version,
  pglite: JSON.parse(readFileSync(join(ROOT, "playground/node_modules/@electric-sql/pglite/package.json"), "utf8")).version,
  tables: tables.length, built_at: new Date().toISOString(),
}, null, 2));
console.log(`playground: wrote ${OUT.replace(ROOT + "/", "")} (${(statSync(OUT).size / 1e6).toFixed(1)} MB) in ${((Date.now() - started) / 1000).toFixed(0)}s`);

// Copy a ustar archive, skipping pg_wal segment files other than `keep`.
function withoutStaleWal(tar, keep) {
  const out = [];
  let dropped = 0;
  for (let off = 0; off + 512 <= tar.length; ) {
    const header = tar.subarray(off, off + 512);
    if (header.every((b) => b === 0)) { out.push(tar.subarray(off)); break; }
    const name = header.subarray(0, 100).toString("utf8").replace(/\0.*$/s, "");
    const size = parseInt(header.subarray(124, 136).toString("utf8").replace(/\0.*$/s, "").trim() || "0", 8);
    const end = off + 512 + Math.ceil(size / 512) * 512;
    const seg = name.match(/pg_wal\/([0-9A-F]{24})$/);
    if (seg && seg[1] !== keep) dropped++;
    else out.push(tar.subarray(off, end));
    off = end;
  }
  console.log(`  dropped ${dropped} stale WAL segments, kept ${keep}`);
  return Buffer.concat(out);
}
