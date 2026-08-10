"use strict";

const API = "http://127.0.0.1:8765";
const PAGE = 400;

const $ = (id) => document.getElementById(id);
const state = {
  path: "", isCareer: false, tables: [],
  // players
  pQuery: "", pOffset: 0, pTotal: 0, pRows: [],
  // tables
  tName: "", tOffset: 0, tRows: [], tColumns: [], tFiltered: 0,
  // misc
  selRow: null, selIdx: null,
};

// ---------- fetch helpers ----------
async function api(path, opts) {
  const res = await fetch(API + path, opts);
  const data = await res.json();
  if (!data.ok) throw new Error(data.error || "API error " + res.status);
  return data;
}
async function apiGet(path) { return api(path); }
async function apiPost(path, body) { return api(path, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) }); }

// ---------- toast / status ----------
let toastTimer = null;
function toast(msg, kind) {
  const t = $("toast");
  t.textContent = msg;
  t.className = "toast " + (kind || "");
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => t.classList.add("hidden"), 4000);
}
function setStatus(msg, cls) {
  const s = $("status");
  s.textContent = msg;
  s.className = "status " + (cls || "");
}

// ---------- tabs ----------
document.querySelectorAll(".tab").forEach((btn) => {
  btn.addEventListener("click", () => {
    document.querySelectorAll(".tab").forEach((b) => b.classList.remove("active"));
    document.querySelectorAll(".view").forEach((v) => v.classList.remove("active"));
    btn.classList.add("active");
    $("view-" + btn.dataset.tab).classList.add("active");
  });
});

// ---------- open / save / backup ----------
function loadSettingsDir() {
  apiGet("/api/settings-dir").then((d) => {
    if (d.files.length && !$("path-input").value) {
      const guess = d.files.find((f) => /Squad/i.test(f) && /FIFER|Beta|Alpha/i.test(f)) || d.files[0];
      if (guess) $("path-input").value = guess;
    }
  }).catch(() => {});
}

async function doOpen() {
  const p = $("path-input").value.trim();
  if (!p) { toast("Enter a squad file path", "err"); return; }
  try {
    const d = await apiPost("/api/open", { path: p });
    state.path = d.path; state.isCareer = d.is_career;
    state.tables = (await apiGet("/api/tables")).tables;
    setStatus(`Opened ${d.path}${d.is_career ? "  (career save)" : ""} — ${d.players} players, ${d.teams} teams, ${d.names} names`, "open");
    initTablesList();
    // default players view
    $("p-search").value = "";
    loadPlayers();
  } catch (e) {
    setStatus("", "err");
    toast("Open failed: " + e.message, "err");
  }
}

async function doSave() {
  if (!state.path) { toast("Open a file first", "err"); return; }
  try {
    const d = await apiPost("/api/save", {});
    toast("Saved: " + d.path, "ok");
  } catch (e) { toast("Save failed: " + e.message, "err"); }
}

async function doBackup() {
  if (!state.path) { toast("Open a file first", "err"); return; }
  try {
    const d = await apiPost("/api/backup", {});
    toast("Backup: " + d.path, "ok");
  } catch (e) { toast("Backup failed: " + e.message, "err"); }
}

$("btn-open").addEventListener("click", doOpen);
$("path-input").addEventListener("keydown", (e) => { if (e.key === "Enter") doOpen(); });
$("btn-save").addEventListener("click", doSave);
$("btn-backup").addEventListener("click", doBackup);

// ---------- players view ----------
let searchTimer = null;
async function loadPlayers(reset) {
  if (reset) state.pOffset = 0;
  const q = $("p-search").value.trim();
  try {
    const d = await apiGet(`/api/players?q=${encodeURIComponent(q)}&limit=${PAGE}&offset=${state.pOffset}`);
    state.pRows = d.rows; state.pTotal = d.total; state.pOffset = d.offset;
    renderPlayers();
  } catch (e) { toast(e.message, "err"); }
}
function renderPlayers() {
  const tb = $("p-table").querySelector("tbody");
  tb.innerHTML = "";
  for (const r of state.pRows) {
    const tr = document.createElement("tr");
    // face + name
    const tdName = document.createElement("td");
    const img = document.createElement("img");
    img.className = "pface";
    img.loading = "lazy";
    img.src = API + r.face;
    img.onerror = () => (img.style.visibility = "hidden");
    const span = document.createElement("span");
    span.textContent = r.name;
    tdName.append(img, span);
    tr.appendChild(tdName);
    // club badge + team
    const tdTeam = document.createElement("td");
    if (r.club_badge) {
      const b = document.createElement("img");
      b.className = "cbadge";
      b.loading = "lazy";
      b.src = API + r.club_badge;
      b.title = r.team;
      b.onerror = () => (b.style.visibility = "hidden");
      tdTeam.appendChild(b);
    }
    if (r.league_icon) {
      const li = document.createElement("img");
      li.className = "cicon";
      li.loading = "lazy";
      li.src = API + r.league_icon;
      li.onerror = () => (li.style.visibility = "hidden");
      tdTeam.appendChild(li);
    }
    tdTeam.appendChild(document.createTextNode(" " + r.team));
    tr.appendChild(tdTeam);
    for (const c of ["ovr", "pot", "pos", "contract"]) {
      const td = document.createElement("td");
      td.textContent = r[c] === null || r[c] === undefined ? "" : r[c];
      tr.appendChild(td);
    }
    tb.appendChild(tr);
  }
  const total = state.pTotal;
  const from = state.pOffset + 1, to = state.pOffset + state.pRows.length;
  $("p-count").textContent = total ? `showing ${from}–${to} of ${total}` : "";
  updatePager("p", total);
}

// search as you type (debounced)
$("p-search").addEventListener("input", () => {
  clearTimeout(searchTimer);
  searchTimer = setTimeout(() => loadPlayers(true), 250);
});
$("p-search-btn").addEventListener("click", () => loadPlayers(true));
$("p-all").addEventListener("click", () => { $("p-search").value = ""; loadPlayers(true); });
$("p-prev").addEventListener("click", () => { if (state.pOffset > 0) { state.pOffset -= PAGE; loadPlayers(); } });
$("p-next").addEventListener("click", () => { if (state.pOffset + PAGE < state.pTotal) { state.pOffset += PAGE; loadPlayers(); } });

// sortable columns (client-side over current page)
document.querySelectorAll("#p-table th").forEach((th) => {
  th.addEventListener("click", () => {
    if (th.classList.contains("no-sort")) return;
    const col = th.dataset.col;
    const dir = th.dataset.dir === "asc" ? "desc" : "asc";
    document.querySelectorAll("#p-table th").forEach((h) => { delete h.dataset.dir; h.textContent = h.textContent.replace(/ [▲▼]$/, ""); });
    th.dataset.dir = dir;
    th.textContent += dir === "asc" ? " ▲" : " ▼";
    state.pRows.sort((a, b) => {
      const va = a[col], vb = b[col];
      if (va === vb) return 0;
      const na = Number(va), nb = Number(vb);
      if (!isNaN(na) && !isNaN(nb)) return dir === "asc" ? na - nb : nb - na;
      return dir === "asc" ? String(va).localeCompare(String(vb)) : String(vb).localeCompare(String(va));
    });
    renderPlayers();
  });
});

// ---------- raw tables view ----------
function initTablesList() {
  const list = $("t-list");
  list.innerHTML = "";
  for (const t of state.tables) {
    const div = document.createElement("div");
    div.className = "titem";
    div.textContent = t;
    div.dataset.table = t;
    div.addEventListener("click", () => selectTable(t));
    list.appendChild(div);
  }
  $("t-filter-tables").value = "";
  if (state.tables.length) selectTable(state.tables[0]);
}
function selectTable(name) {
  state.tName = name; state.tOffset = 0; state.selRow = null;
  document.querySelectorAll(".titem").forEach((d) => d.classList.toggle("active", d.dataset.table === name));
  $("t-name").textContent = name;
  loadTableRows(true);
}
function filterTableList() {
  const q = $("t-filter-tables").value.trim().toLowerCase();
  document.querySelectorAll(".titem").forEach((d) => {
    d.style.display = q && !d.dataset.table.toLowerCase().includes(q) ? "none" : "";
  });
}
$("t-filter-tables").addEventListener("input", filterTableList);

async function loadTableRows(reset) {
  if (reset) state.tOffset = 0;
  const name = state.tName;
  if (!name) return;
  const filt = $("t-filter-rows").value.trim();
  try {
    const d = await apiGet(`/api/table?name=${encodeURIComponent(name)}&limit=${PAGE}&offset=${state.tOffset}&filter=${encodeURIComponent(filt)}`);
    state.tColumns = d.columns; state.tRows = d.rows; state.tOffset = d.offset;
    state.tFiltered = d.filtered;
    renderTable(d);
  } catch (e) { toast(e.message, "err"); }
}
function renderTable(d) {
  const thead = $("t-table").querySelector("thead");
  const tbody = $("t-table").querySelector("tbody");
  thead.innerHTML = "";
  tbody.innerHTML = "";
  const trh = document.createElement("tr");
  for (const c of d.columns) {
    const th = document.createElement("th");
    th.textContent = c;
    th.addEventListener("click", () => sortTableCols(c, th));
    trh.appendChild(th);
  }
  thead.appendChild(trh);
  state.tRows.forEach((r, i) => {
    const tr = document.createElement("tr");
    tr.dataset.i = r._i;
    for (const c of d.columns) {
      const td = document.createElement("td");
      td.textContent = r[c] === null || r[c] === undefined ? "" : r[c];
      tr.appendChild(td);
    }
    tr.addEventListener("click", () => {
      document.querySelectorAll("#t-table tbody tr").forEach((x) => x.classList.remove("sel"));
      tr.classList.add("sel");
      state.selRow = r; state.selIdx = r._i;
    });
    tbody.appendChild(tr);
  });
  $("t-count").textContent = `${d.filtered} matched / ${d.total} rows`;
  updatePager("t", d.filtered);
}
function sortTableCols(col, th) {
  const dir = th.dataset.dir === "asc" ? "desc" : "asc";
  document.querySelectorAll("#t-table th").forEach((h) => { delete h.dataset.dir; h.textContent = h.textContent.replace(/ [▲▼]$/, ""); });
  th.dataset.dir = dir;
  th.textContent += dir === "asc" ? " ▲" : " ▼";
  state.tRows.sort((a, b) => {
    const va = a[col], vb = b[col];
    if (va === vb) return 0;
    const na = Number(va), nb = Number(vb);
    if (!isNaN(na) && !isNaN(nb)) return dir === "asc" ? na - nb : nb - na;
    return dir === "asc" ? String(va).localeCompare(String(vb)) : String(vb).localeCompare(String(va));
  });
  renderTable({ columns: state.tColumns, rows: state.tRows, filtered: state.tRows.length, total: state.tRows.length });
}

$("t-refresh").addEventListener("click", () => loadTableRows(true));
$("t-filter-rows").addEventListener("keydown", (e) => { if (e.key === "Enter") loadTableRows(true); });
$("t-prev").addEventListener("click", () => { if (state.tOffset > 0) { state.tOffset -= PAGE; loadTableRows(); } });
$("t-next").addEventListener("click", () => { if (state.tOffset + PAGE < state.tFiltered) { state.tOffset += PAGE; loadTableRows(); } });

// ---------- edit / delete ----------
let editFields = [];
$("t-edit").addEventListener("click", () => {
  if (!state.selRow) { toast("Select a row first", "err"); return; }
  const fields = state.tColumns.filter((c) => c !== "_i" && typeof state.selRow[c] === "number");
  if (!fields.length) { toast("Row has no integer fields to edit", "err"); return; }
  editFields = fields;
  const sel = $("e-field");
  sel.innerHTML = "";
  fields.forEach((f) => {
    const o = document.createElement("option");
    o.value = f; o.textContent = f;
    sel.appendChild(o);
  });
  sel.value = fields[0];
  $("e-cur").textContent = state.selRow[fields[0]];
  $("e-value").value = state.selRow[fields[0]];
  $("edit-modal").classList.remove("hidden");
  $("e-value").focus();
});
$("e-field").addEventListener("change", () => {
  $("e-cur").textContent = state.selRow[$("e-field").value];
  $("e-value").value = state.selRow[$("e-field").value];
});
$("e-apply").addEventListener("click", async () => {
  const field = $("e-field").value;
  const value = $("e-value").value.trim();
  if (value === "" || isNaN(Number(value))) { toast("Integer required", "err"); return; }
  try {
    await apiPost("/api/edit", { table: state.tName, idx: state.selIdx, field, value: Number(value) });
    toast(`Updated ${state.tName}[${state.selIdx}].${field} = ${value}`, "ok");
    $("edit-modal").classList.add("hidden");
    loadTableRows(true);
  } catch (e) { toast(e.message, "err"); }
});
$("e-cancel").addEventListener("click", () => $("edit-modal").classList.add("hidden"));

$("t-delete").addEventListener("click", async () => {
  if (!state.selRow) { toast("Select a row first", "err"); return; }
  if (!confirm(`Delete row ${state.selIdx} from ${state.tName}?`)) return;
  try {
    await apiPost("/api/delete", { table: state.tName, idx: state.selIdx });
    toast(`Deleted row ${state.selIdx}`, "ok");
    loadTableRows(true);
  } catch (e) { toast(e.message, "err"); }
});

// ---------- pager ----------
function updatePager(kind, total) {
  $(`${kind}-pageinfo`).textContent = `page ${Math.floor(state[`${kind}Offset`] / PAGE) + 1} of ${Math.max(1, Math.ceil(total / PAGE))}`;
  $(`${kind}-prev`).disabled = state[`${kind}Offset`] === 0;
  $(`${kind}-next`).disabled = state[`${kind}Offset`] + PAGE >= total;
}

// ---------- init ----------
loadSettingsDir();
setStatus("Open a squad file to begin.");