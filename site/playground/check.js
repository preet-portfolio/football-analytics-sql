// Compare a learner's result with the reference result.
//
// Shared by the page (app.js) and the test suite (playground/test.mjs), so the
// rules the tests prove are the rules learners get.
//
// A result is { fields: [{ name, dataTypeID? }], rows: [[...values]] }, as PGlite
// returns with rowMode "array" and date/time parsers that keep Postgres' text.
// Rules:
//   - column NAMES don't matter; column ORDER and COUNT do;
//   - row order matters only when the challenge says so;
//   - integer reference columns need the exact integer;
//   - other numbers match within half a unit of the precision the reference shows
//     (at most 2 decimals), so 84.85 matches 84.9 and 61.29 matches 61.3;
//   - a number never matches text, even text that looks like a number;
//   - intervals match to the second; a date matches the same timestamp at midnight;
//   - NULL only matches NULL.

const INT_TYPES = new Set([20, 21, 23]);          // int8, int2, int4
const NUM_TYPES = new Set([20, 21, 23, 700, 701, 1700]);
const INTERVAL = 1186;
const NUMERIC_TEXT = /^-?\d+(\.\d+)?$/;

function decimals(v) {
  const s = String(v);
  const i = s.indexOf(".");
  return i < 0 || /e/i.test(s) ? 0 : s.length - i - 1;
}

const isNumericValue = (v) => typeof v === "number" || typeof v === "bigint";

// Without type ids (hand-built results in unit tests), a numeric string from the
// reference is treated as a number; with type ids the type decides.
function isNumber(v, typeId) {
  if (v === null) return false;
  if (typeId !== undefined) return NUM_TYPES.has(typeId);
  return isNumericValue(v) || (typeof v === "string" && NUMERIC_TEXT.test(v.trim()));
}

// "1 day 02:10:57.392", "02:10:57", "-00:00:05" -> seconds
function intervalSeconds(s) {
  const m = String(s).trim().match(/^(?:(-?\d+) days? ?)?(-)?(\d+):(\d{2}):(\d{2}(?:\.\d+)?)$/);
  if (!m) return null;
  const hms = Number(m[3]) * 3600 + Number(m[4]) * 60 + Number(m[5]);
  return Number(m[1] ?? 0) * 86400 + (m[2] ? -hms : hms);
}

const temporal = (v) => (v instanceof Date ? v.toISOString() : String(v).trim()).replace(/[ T]00:00:00(\.0+)?(Z|\+00(:00)?)?$/, "");

// Describe how to compare each reference column, from its type and values.
function columnRules(expected) {
  return expected.fields.map((f, c) => {
    const values = expected.rows.map((r) => r[c]).filter((v) => v !== null);
    if (f.dataTypeID === INTERVAL) return { kind: "interval" };
    const numeric = values.length > 0 && values.every((v) => isNumber(v, f.dataTypeID));
    if (!numeric) return { kind: "text" };
    const integer = f.dataTypeID !== undefined ? INT_TYPES.has(f.dataTypeID)
      : values.every((v) => typeof v === "bigint" || Number.isInteger(Number(v)) && decimals(v) === 0);
    const p = Math.min(2, Math.max(0, ...values.map(decimals)));
    return integer ? { kind: "int" } : { kind: "num", tol: 0.5 * 10 ** -p + 1e-9 };
  });
}

function cellMatches(e, a, rule, actualType) {
  if (e === null || a === null || e === undefined || a === undefined) return (e ?? null) === (a ?? null);
  switch (rule.kind) {
    case "int":
      if (!isNumber(a, actualType)) return false;
      try { return BigInt(String(e)) === BigInt(String(a).trim()); } catch { return false; }
    case "num":
      return isNumber(a, actualType) && Math.abs(Number(e) - Number(a)) <= rule.tol;
    case "interval": {
      const x = intervalSeconds(e), y = intervalSeconds(a);
      return x !== null && y !== null && Math.abs(x - y) < 1;
    }
    default:
      if (actualType !== undefined && NUM_TYPES.has(actualType)) return false; // text vs number
      if (e instanceof Date || a instanceof Date || /^\d{4}-\d{2}-\d{2}/.test(String(e))) return temporal(e) === temporal(a);
      if (typeof e === "boolean" || typeof a === "boolean") return String(e) === String(a);
      if (typeof e === "object" || typeof a === "object") return JSON.stringify(e) === JSON.stringify(a);
      return String(e).trim() === String(a).trim();
  }
}

const show = (row) => "(" + row.map((v) => (v === null ? "NULL" : v instanceof Date ? temporal(v) : String(v))).join(", ") + ")";

/**
 * @returns {{ ok: boolean, message: string }}
 */
export function checkResult(expected, actual, { orderMatters = false } = {}) {
  if (!actual || !actual.fields || actual.fields.length === 0)
    return { ok: false, message: "Your query didn't return a result set. End it with a SELECT." };

  const ncol = expected.fields.length;
  if (actual.fields.length !== ncol)
    return {
      ok: false,
      message: `Expected ${ncol} column${ncol === 1 ? "" : "s"} (${expected.fields.map((f) => f.name).join(", ")}), got ${actual.fields.length}.`,
    };

  const nexp = expected.rows.length;
  if (actual.rows.length !== nexp)
    return { ok: false, message: `Expected ${nexp} row${nexp === 1 ? "" : "s"}, got ${actual.rows.length}.` };

  const rules = columnRules(expected);
  const types = actual.fields.map((f) => f.dataTypeID);
  const rowMatches = (e, a) => e.every((v, c) => cellMatches(v, a[c], rules[c], types[c]));

  // Pair every reference row with a distinct learner row (results are small).
  const used = new Array(nexp).fill(false);
  const unmatched = [];
  for (const e of expected.rows) {
    const j = actual.rows.findIndex((a, k) => !used[k] && rowMatches(e, a));
    if (j < 0) unmatched.push(e);
    else used[j] = true;
  }
  if (unmatched.length)
    return {
      ok: false,
      message: `Same shape, but ${unmatched.length} row${unmatched.length === 1 ? " doesn't" : "s don't"} match the answer.` +
        ` For example, the answer contains ${show(unmatched[0])}.`,
    };

  if (orderMatters) {
    const first = expected.rows.findIndex((e, i) => !rowMatches(e, actual.rows[i]));
    if (first >= 0)
      return { ok: false, message: `Right rows, wrong order: row ${first + 1} should be ${show(expected.rows[first])}.` };
  }
  return { ok: true, message: `Correct: ${nexp} row${nexp === 1 ? "" : "s"} match.` };
}

// Keep Postgres' own text for dates, timestamps and intervals, so nothing is
// shifted into the browser's time zone. Used by the worker and the tests.
export const TEXT_PARSERS = { 1082: (s) => s, 1114: (s) => s, 1184: (s) => s, 1186: (s) => s };
