// The download ships every index in these schemas as an empty file (see
// playground/build.mjs): rebuilding them from the tables takes about a second,
// downloading them would take half the download. Constraints are unchanged in the
// catalogue, so primary keys, unique constraints and foreign keys look and work
// as usual once this has run. It must run before any query touches those tables.
export const REBUILT_SCHEMAS = ["model", "analysis", "stg"];

export async function rebuildIndexes(db) {
  for (const schema of REBUILT_SCHEMAS) await db.exec(`REINDEX SCHEMA ${schema};`); // not allowed inside a transaction block
}
