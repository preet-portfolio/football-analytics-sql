import { challenges } from "./challenges.js";
import { checkResult } from "./check.js";

const $ = (id) => document.getElementById(id);
const esc = (s) => String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
// Prompts use `backticks` for identifiers.
const md = (s) => esc(s).replace(/`([^`]+)`/g, "<code>$1</code>");

const FREE = { id: "free", title: "Free play", concept: "Any query you like",
  prompt: "No challenge, no checking. Explore the `model` tables or the ready-made `analysis` views, for example `SELECT * FROM analysis.group_table;`.",
  starter: "-- The final group tables, as computed from raw events.\nSELECT *\nFROM analysis.group_table\nORDER BY \"group\", pos;" };
const MAX_ROWS_SHOWN = 500;

// ---------------------------------------------------------------- storage
// Progress lives only in this browser; the page works the same without it.
const store = {
  get(key, fallback) { try { const v = localStorage.getItem(key); return v === null ? fallback : JSON.parse(v); } catch { return fallback; } },
  set(key, value) { try { localStorage.setItem(key, JSON.stringify(value)); } catch { /* private mode */ } },
};
let solved = new Set(store.get("wc22.solved", []));
const drafts = store.get("wc22.drafts", {});

// ---------------------------------------------------------------- worker
let worker, ready = false, nextId = 1;
const pending = new Map();
const referenceCache = new Map();

function startWorker() {
  ready = false;
  setButtons();
  worker = new Worker("worker.js", { type: "module" });
  worker.onmessage = ({ data }) => {
    if (data.type === "progress") return showProgress(data);
    if (data.type === "ready") { ready = true; $("engine").textContent = `${data.version}, running in this tab via PGlite${data.saved ? " (from the copy saved in this browser)" : ""}.`; $("bar").hidden = true; setButtons(); loadTables(); return; }
    if (data.type === "reloaded") { referenceCache.clear(); return; }
    if (data.type === "load-error") { $("engine").textContent = data.error; return; }
    const p = pending.get(data.id);
    if (!p) return;
    pending.delete(data.id);
    data.ok ? p.resolve(data.result) : p.reject(Object.assign(new Error(data.error), { hint: data.hint, position: data.position }));
  };
  worker.onerror = (e) => { $("engine").textContent = `The database failed to start: ${e.message ?? "unknown error"}.`; };
  $("bar").hidden = false;
  worker.postMessage({ type: "load" });
}

function call(type, sql) {
  const id = nextId++;
  return new Promise((resolve, reject) => { pending.set(id, { resolve, reject }); worker.postMessage({ id, type, sql }); });
}

function showProgress({ got, total, status }) {
  const mb = (n) => (n / 1e6).toFixed(0);
  $("engine").textContent = status ?? `Downloading the database: ${mb(got)}${total ? ` of ${mb(total)}` : ""} MB`;
  $("bar").firstElementChild.style.width = status ? "100%" : total ? `${Math.min(100, (100 * got) / total)}%` : "30%";
}

// Kill a runaway query: terminate the worker and start a fresh one (served from cache).
function restart(reason) {
  worker.terminate();
  referenceCache.clear();
  for (const p of pending.values()) p.reject(new Error(reason));
  pending.clear();
  startWorker();
}

// ---------------------------------------------------------------- state
let current = null;
let running = false;

function setButtons() {
  $("run").disabled = !ready || running;
  $("stop").disabled = !running;
  $("run").textContent = current && current !== FREE ? "Run and check" : "Run";
}

function renderList() {
  $("challenge-list").innerHTML = challenges.map((c, i) => `
    <li class="${solved.has(c.id) ? "solved" : ""}"><button data-id="${c.id}" aria-current="${current.id === c.id}">
      <span class="num">${i + 1}</span><span class="ch-name">${esc(c.title)}</span><span class="ch-concept">${esc(c.concept)}</span>
    </button></li>`).join("") + `
    <li class="free"><button data-id="free" aria-current="${current === FREE}">
      <span class="num">∞</span><span class="ch-name">Free play</span><span class="ch-concept">No checking</span>
    </button></li>`;
  const n = challenges.filter((c) => solved.has(c.id)).length;
  $("progress-text").textContent = `${n} of ${challenges.length} solved`;
  $("steps").innerHTML = challenges.map((c) => `<span class="${solved.has(c.id) ? "solved" : ""}" title="${esc(c.title)}"></span>`).join("");
}

function select(id) {
  saveDraft();
  current = id === "free" ? FREE : challenges.find((c) => c.id === id) ?? FREE;
  const idx = challenges.indexOf(current);
  $("brief").innerHTML = `
    <h2 class="challenge-title">${idx >= 0 ? `${idx + 1}. ` : ""}${esc(current.title)}</h2>
    <p class="concept">${esc(current.concept)}${current.orderMatters ? ". Row order is checked." : ""}</p>
    <p class="prompt">${md(current.prompt)}</p>
    ${current === FREE ? "" : `<div class="help"><button id="show-hint">Show a hint</button><button id="show-solution">Show the solution</button></div><div id="help-body"></div>`}`;
  $("sql").value = drafts[current.id] ?? (current === FREE ? FREE.starter : "-- Write your query here\nSELECT ");
  $("verdict").innerHTML = ""; $("meta").textContent = ""; $("result").hidden = true;
  if (current !== FREE) {
    $("show-hint").onclick = () => { $("help-body").innerHTML = `<p class="hint">${md(current.hint)}</p>`; };
    $("show-solution").onclick = () => {
      if (!confirm("Show the reference solution? You can still run it to see the answer.")) return;
      $("help-body").innerHTML = `<pre class="hint mono" style="white-space:pre-wrap">${esc(current.solution)}</pre>
        <p><button class="insert" id="use-solution">Copy it into the editor</button></p>`;
      $("use-solution").onclick = () => { $("sql").value = current.solution; $("sql").focus(); };
    };
  }
  renderList();
  setButtons();
  try { history.replaceState(null, "", `#${current.id}`); } catch { /* sandboxed */ }
}

function saveDraft() {
  if (!current) return;
  drafts[current.id] = $("sql").value;
  store.set("wc22.drafts", drafts);
}

// ---------------------------------------------------------------- running
async function run() {
  if (!ready || running) return;
  const sql = $("sql").value;
  const c = current;
  saveDraft();
  running = true; setButtons();
  $("verdict").innerHTML = ""; $("meta").textContent = "Running…";
  try {
    const result = await call("run", sql);
    if (current !== c) return; // the learner moved on while it ran
    renderResult(result);
    if (c !== FREE) await check(result, c);
  } catch (e) {
    if (current !== c) return;
    $("result").hidden = true; $("meta").textContent = "";
    $("verdict").className = "verdict error";
    $("verdict").textContent = describeError(e, sql);
  } finally {
    running = false; setButtons();
  }
}

async function check(result, c) {
  if (!referenceCache.has(c.id)) referenceCache.set(c.id, await call("run", c.solution));
  const verdict = checkResult(referenceCache.get(c.id), result, c);
  if (current !== c) return;
  $("verdict").className = verdict.ok ? "verdict" : "verdict bad";
  $("verdict").textContent = verdict.ok ? `${verdict.message} Challenge solved.` : verdict.message;
  if (current !== c) return;
  if (verdict.ok && !solved.has(c.id)) { solved.add(c.id); store.set("wc22.solved", [...solved]); renderList(); }
}

function describeError(e, sql) {
  let msg = `ERROR: ${e.message}`;
  if (e.position && e.position <= sql.length) {
    const before = sql.slice(0, e.position - 1);
    const line = before.split("\n").length;
    const col = e.position - before.lastIndexOf("\n") - 1;
    msg += `\nat line ${line}, column ${col}:\n  ${sql.split("\n")[line - 1]}\n  ${" ".repeat(Math.max(0, col - 1))}^`;
  }
  if (e.hint) msg += `\nHint: ${e.hint}`;
  return msg;
}

function fmt(v) {
  if (v === null || v === undefined) return { text: "NULL", cls: "null" };
  if (v instanceof Date) return { text: v.toISOString().endsWith("T00:00:00.000Z") ? v.toISOString().slice(0, 10) : v.toISOString().replace("T", " ").replace(".000Z", "Z"), cls: "" };
  if (typeof v === "number" || typeof v === "bigint") return { text: String(v), cls: "n" };
  if (typeof v === "string" && /^-?\d+(\.\d+)?$/.test(v)) return { text: v, cls: "n" };
  if (typeof v === "object") return { text: JSON.stringify(v), cls: "" };
  return { text: String(v), cls: "" };
}

function renderResult(r) {
  const n = r.rows.length;
  $("meta").textContent = r.fields.length === 0
    ? `Done in ${r.ms.toFixed(0)} ms. The last statement returned no rows to show.`
    : `${n.toLocaleString()} row${n === 1 ? "" : "s"} in ${r.ms.toFixed(0)} ms${n > MAX_ROWS_SHOWN ? `, showing the first ${MAX_ROWS_SHOWN}` : ""}.`;
  if (r.fields.length === 0) { $("result").hidden = true; return; }
  const head = `<tr>${r.fields.map((f) => `<th scope="col">${esc(f.name)}</th>`).join("")}</tr>`;
  const body = r.rows.slice(0, MAX_ROWS_SHOWN).map((row) => `<tr>${row.map((v) => { const f = fmt(v); return `<td class="${f.cls}">${esc(f.text)}</td>`; }).join("")}</tr>`).join("");
  $("result").innerHTML = `<table><thead>${head}</thead><tbody>${body}</tbody></table>`;
  $("result").hidden = false;
}

// ---------------------------------------------------------------- tables
async function loadTables() {
  try {
    const rels = await call("schema");
    const kinds = { r: "table", v: "view", m: "materialized view" };
    const groups = { model: "Model tables", analysis: "Analysis views", stg: "Data quality" };
    let html = "", last = null;
    for (const t of rels) {
      if (t.schema !== last) { html += `<p class="schema-name">${groups[t.schema] ?? t.schema}</p>`; last = t.schema; }
      const full = `${t.schema}.${t.name}`;
      html += `<details><summary><span class="mono">${esc(full)}</span> <span class="kind">${kinds[t.kind]}</span></summary>
        ${t.comment ? `<p class="grain">${esc(t.comment)}</p>` : ""}
        <p class="grain"><button class="insert" data-insert="${esc(full)}">Insert name</button></p>
        <ul>${t.columns.map((c) => `<li><span class="mono">${esc(c.name)}</span><span>${esc(c.type)}</span></li>`).join("")}</ul></details>`;
    }
    $("panel-tables").innerHTML = html;
  } catch (e) {
    $("panel-tables").innerHTML = `<p class="grain">Couldn't list tables: ${esc(e.message)}</p>`;
  }
}

function insertAtCursor(text) {
  const ta = $("sql");
  const { selectionStart: s, selectionEnd: e, value } = ta;
  ta.value = value.slice(0, s) + text + value.slice(e);
  ta.selectionStart = ta.selectionEnd = s + text.length;
  ta.focus();
}

// ---------------------------------------------------------------- wiring
$("challenge-list").addEventListener("click", (e) => { const b = e.target.closest("button[data-id]"); if (b) select(b.dataset.id); });
$("panel-tables").addEventListener("click", (e) => { const b = e.target.closest("[data-insert]"); if (b) insertAtCursor(b.dataset.insert); });
$("run").onclick = run;
$("stop").onclick = () => { restart("Query stopped."); running = false; setButtons(); $("meta").textContent = "Stopped. Restarting the database…"; };
$("reset").onclick = () => { if (confirm("Reload a fresh copy of the database in this tab?")) { restart("Database reset."); running = false; setButtons(); } };
$("sql").addEventListener("keydown", (e) => {
  if (e.key === "Enter" && (e.ctrlKey || e.metaKey)) { e.preventDefault(); run(); }
  else if (e.key === "Tab" && !e.shiftKey) { e.preventDefault(); insertAtCursor("  "); }
});
$("sql").addEventListener("input", () => { clearTimeout(saveDraft.t); saveDraft.t = setTimeout(saveDraft, 400); });
for (const tab of document.querySelectorAll('[role="tab"]')) {
  tab.onclick = () => {
    for (const t of document.querySelectorAll('[role="tab"]')) {
      const on = t === tab;
      t.setAttribute("aria-selected", on);
      $(t.getAttribute("aria-controls")).hidden = !on;
    }
  };
}

const fromHash = location.hash.slice(1);
const firstUnsolved = challenges.find((c) => !solved.has(c.id));
select(fromHash && (fromHash === "free" || challenges.some((c) => c.id === fromHash)) ? fromHash : firstUnsolved?.id ?? "free");
startWorker();
