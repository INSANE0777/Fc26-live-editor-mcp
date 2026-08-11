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
state.pFaces = false;
async function loadPlayers(reset) {
  if (reset) state.pOffset = 0;
  const q = $("p-search").value.trim();
  const sort = state.pSort ? `&sort=${state.pSort}&dir=${state.pDir}` : "";
  const faces = state.pFaces ? "&has_face=1" : "";
  try {
    const d = await apiGet(`/api/players?q=${encodeURIComponent(q)}&limit=${PAGE}&offset=${state.pOffset}${sort}${faces}`);
    state.pRows = d.rows; state.pTotal = d.total; state.pOffset = d.offset;
    renderPlayers();
  } catch (e) { toast(e.message, "err"); }
}
function renderPlayers() {
  const tb = $("p-table").querySelector("tbody");
  tb.innerHTML = "";
  for (const r of state.pRows) {
    const tr = document.createElement("tr");
    tr.dataset.pid = r.playerid;
    tr.className = "prow";
    tr.addEventListener("click", () => openProfile(r.playerid));
    const tdId = document.createElement("td");
    tdId.className = "pid";
    tdId.textContent = r.playerid;
    tr.appendChild(tdId);
    // face + name
    const tdName = document.createElement("td");
    const img = retryImg(API + r.face, "pface");
    const span = document.createElement("span");
    span.textContent = r.name;
    tdName.append(img, span);
    tr.appendChild(tdName);
    // club badge + team
    const tdTeam = document.createElement("td");
    if (r.club_badge) {
      const b = retryImg(API + r.club_badge, "cbadge");
      b.title = r.team;
      tdTeam.appendChild(b);
    }
    if (r.league_icon) {
      const li = retryImg(API + r.league_icon, "cicon");
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

// Asset image with state-based retry. The sidecar answers:
//   200 + image          -> cached, show it
//   404 X-Asset-State: pending  -> downloading, keep re-checking
//   404 X-Asset-State: missing  -> no face exists, stop retrying
// Cached images load instantly (normal <img>); a 404 triggers a state
// check that either stops (missing) or re-fires after a delay (pending).
function retryImg(src, cls) {
  const img = document.createElement("img");
  img.className = cls;
  img.loading = "lazy";
  img.alt = "";
  let timer = null;
  const poll = async () => {
    let state;
    try {
      const r = await fetch(src);
      state = r.ok ? "ok" : (r.headers.get("X-Asset-State") || "missing");
    } catch {
      state = "pending";
    }
    if (state === "ok") {
      img.src = src + "?r=" + Date.now(); // re-fire now that it's cached
    } else if (state === "missing") {
      img.classList.remove("pending");
      img.classList.add("missing");
    } else {
      img.classList.add("pending");
      timer = setTimeout(poll, 1500); // keep polling while downloading
    }
  };
  img.onerror = () => {
    if (img.classList.contains("missing")) return;
    img.classList.add("pending");
    if (!timer) timer = setTimeout(poll, 400);
  };
  img.src = src;
  return img;
}

// search as you type (debounced)
$("p-search").addEventListener("input", () => {
  clearTimeout(searchTimer);
  state.pSort = null;
  document.querySelectorAll("#p-table th").forEach((h) => { delete h.dataset.dir; h.textContent = h.textContent.replace(/ [▲▼]$/, ""); });
  searchTimer = setTimeout(() => loadPlayers(true), 250);
});
$("p-search-btn").addEventListener("click", () => loadPlayers(true));
$("p-faces").addEventListener("click", () => {
  state.pFaces = !state.pFaces;
  $("p-faces").classList.toggle("active", state.pFaces);
  loadPlayers(true);
});
$("p-all").addEventListener("click", () => { $("p-search").value = ""; state.pSort = null; state.pFaces = false; $("p-faces").classList.remove("active"); document.querySelectorAll("#p-table th").forEach((h) => { delete h.dataset.dir; h.textContent = h.textContent.replace(/ [▲▼]$/, ""); }); loadPlayers(true); });
$("p-prev").addEventListener("click", () => { if (state.pOffset > 0) { state.pOffset -= PAGE; loadPlayers(); } });
$("p-next").addEventListener("click", () => { if (state.pOffset + PAGE < state.pTotal) { state.pOffset += PAGE; loadPlayers(); } });

// sortable columns — server-side over the WHOLE database (not just the
// current 400-row page)
state.pSort = null;
state.pDir = "asc";
document.querySelectorAll("#p-table th").forEach((th) => {
  th.addEventListener("click", () => {
    if (th.classList.contains("no-sort")) return;
    const col = th.dataset.col;
    if (state.pSort === col) {
      state.pDir = state.pDir === "asc" ? "desc" : "asc";
    } else {
      state.pSort = col; state.pDir = "asc";
    }
    document.querySelectorAll("#p-table th").forEach((h) => { delete h.dataset.dir; h.textContent = h.textContent.replace(/ [▲▼]$/, ""); });
    th.dataset.dir = state.pDir;
    th.textContent += state.pDir === "asc" ? " ▲" : " ▼";
    loadPlayers(true);
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

// ---------- player profile drawer ----------
let pfPlayer = null;
let pfPid = null;

async function openProfile(pid) {
  pfPid = pid;
  const dr = $("profile");
  dr.classList.add("open");
  dr.classList.remove("hidden");
  $("pf-name").textContent = "Loading…";
  document.querySelectorAll(".drawer img").forEach((i) => (i.style.visibility = "hidden"));
  try {
    const d = await apiGet(`/api/player/${pid}`);
    pfPlayer = d.player;
    renderProfile(d.player);
  } catch (e) {
    toast(e.message, "err");
  }
}

function drawerImg(el, src) {
  const img = retryImg(API + src, el.className);
  img.id = el.id;
  el.replaceWith(img);
  return img;
}

const FOOT_LABELS = { 0: "Right", 1: "Left" };

function renderProfile(p) {
  const $f = (id) => $(id);
  $f("pf-name").textContent = `${p.name}  (${p.playerid})`;
  $f("pf-ovr").textContent = p.ovr;
  $f("pf-team").textContent = p.team;
  $f("pf-pos").textContent = p.positions.join(" / ");
  const age = p.birthdate ? Math.floor((Date.now() - new Date(p.birthdate)) / 31557600000) : "";
  $f("pf-age").textContent = p.birthdate ? `${age} yrs (${p.birthdate})` : "";
  $f("pf-jersey").textContent = p.jersey_number ? `#${p.jersey_number}` : "";
  $f("pf-jersey").style.display = p.jersey_number ? "" : "none";
  // images
  drawerImg($f("pf-face"), p.face);
  if (p.club_badge) drawerImg($f("pf-badge"), p.club_badge);
  if (p.league_icon) drawerImg($f("pf-icon"), p.league_icon);
  if (p.nation_flag) drawerImg($f("pf-flag"), p.nation_flag);
  document.querySelectorAll("#profile .drawer-face img, #profile .drawer-sub img").forEach((i) => (i.style.visibility = ""));
  // attributes grid
  const sec = $f("pf-attrs");
  sec.innerHTML = "";
  for (const [group, items] of Object.entries(p.attributes)) {
    const real = items.filter(([, v]) => v !== null && v !== undefined);
    if (!real.length) continue;
    const blk = document.createElement("div");
    blk.className = "attr-group";
    const h = document.createElement("h4");
    h.textContent = group;
    blk.appendChild(h);
    for (const [label, val] of real) {
      const row = document.createElement("div");
      row.className = "attr-row";
      const l = document.createElement("span");
      l.textContent = label;
      const bar = document.createElement("div");
      bar.className = "attr-bar";
      const fill = document.createElement("div");
      fill.className = "attr-fill";
      fill.style.width = Math.min(100, val) + "%";
      bar.appendChild(fill);
      const v = document.createElement("span");
      v.textContent = val;
      row.append(l, bar, v);
      blk.appendChild(row);
    }
    sec.appendChild(blk);
  }
  // meta line
  const meta = [
    ["Height", p.height_cm ? `${p.height_cm} cm` : ""],
    ["Weight", p.weight_kg ? `${p.weight_kg} kg` : ""],
    ["Foot", FOOT_LABELS[p.preferred_foot] ?? ""],
    ["Skill moves", p.skill_moves ?? ""],
    ["Weak foot", p.weak_foot ?? ""],
    ["Retiring", p.is_retiring ? "Yes" : ""],
    ["Loaned out", p.loaned ? "Yes" : "No"],
  ].filter(([, v]) => v !== "" && v !== null && v !== undefined);
  $f("pf-meta").innerHTML = meta.map(([k, v]) => `<span class="meta"><b>${k}</b> ${v}</span>`).join("");
  // action buttons
  $f("pf-terminate").style.display = p.loaned ? "" : "none";
  $f("pf-transfer").style.display = p.loaned ? "none" : "";
  $f("pf-loan").style.display = p.loaned ? "none" : "";
  $f("pf-release").style.display = p.loaned ? "none" : "";
  // direct-write row mirrors the same visibility
  $f("pf-terminate-direct").style.display = p.loaned ? "" : "none";
  $f("pf-release-direct").style.display = p.loaned ? "none" : "";
}

$("pf-close").addEventListener("click", () => {
  $("profile").classList.add("hidden");
  $("profile").classList.remove("open");
});

// ---------- team picker modal ----------
let tmKind = "transfer";
let tmTimer = null;

async function pickTeam(kind) {
  tmKind = kind;
  $("tm-title").textContent = kind === "transfer" ? "Choose destination club" : "Choose loan club";
  $("tm-search").value = "";
  $("tm-list").innerHTML = "<div class='team-row muted'>Type to search…</div>";
  $("team-modal").classList.remove("hidden");
  $("tm-search").focus();
  loadTeams("");
}

async function loadTeams(q) {
  try {
    const d = await apiGet(`/api/teams?q=${encodeURIComponent(q)}`);
    const list = $("tm-list");
    list.innerHTML = "";
    const cur = pfPlayer ? pfPlayer.team_id : null;
    for (const t of d.rows) {
      if (t.teamid === cur) continue;
      const div = document.createElement("div");
      div.className = "team-row";
      const b = retryImg(API + `/assets/club/${t.teamid}`, "cbadge");
      div.append(b, document.createTextNode(` ${t.teamid} | ${t.name}`));
      div.addEventListener("click", () => selectTeam(t));
      list.appendChild(div);
    }
    if (!d.rows.length) list.innerHTML = "<div class='team-row muted'>No clubs match</div>";
  } catch (e) {
    toast(e.message, "err");
  }
}

let tmTeam = null;
function selectTeam(t) {
  tmTeam = t;
  $("tm-method").classList.remove("hidden");
  $("tm-method-label").textContent =
    `${tmKind === "loan" ? "Loan" : "Transfer"} ${pfPlayer ? pfPlayer.name : ""} → ${t.name} (${t.teamid})`;
}

$("tm-search").addEventListener("input", () => {
  clearTimeout(tmTimer);
  tmTimer = setTimeout(() => loadTeams($("tm-search").value.trim()), 250);
});
$("tm-cancel").addEventListener("click", () => $("team-modal").classList.add("hidden"));

async function runAction(kind, team) {
  $("team-modal").classList.add("hidden");
  const body = { kind, pid: pfPid, tid: team ? team.teamid : undefined };
  try {
    const d = await apiPost("/api/action", body);
    showActionResult(d);
  } catch (e) {
    toast(e.message, "err");
  }
}

async function applyDirect(kind, team) {
  $("team-modal").classList.add("hidden");
  const body = { kind, pid: pfPid, tid: team ? team.teamid : undefined };
  try {
    const d = await apiPost("/api/direct", body);
    if (!d.ok) { toast(d.error || "apply failed", "err"); return; }
    const lbl = { transfer: "Transfer", loan: "Loan", terminate: "Loan terminated", release: "Released" }[kind];
    const who = pfPlayer ? pfPlayer.name : `#${pfPid}`;
    if (kind === "terminate") {
      toast(`${lbl}: ${who} (any loan row removed)`, "ok");
    } else {
      toast(`${lbl}: ${who} → ${team ? team.name : "Free Agents"}`, "ok");
    }
    alert(
      `${lbl} applied DIRECTLY to the squads file:\n\n` +
      `Player: ${who}\n` +
      (team ? `Club: ${team.name} (${team.teamid})\n` : `Club: Free Agents\n`) +
      `\nBackup: ${d.backup}\n` +
      `Tables OK: ${d.tables}` +
      `\n\n⚠️ This affects NEW careers only. ` +
      `Start a fresh career (or load the squads file) to see the change. ` +
      `Your current in-progress career is NOT modified.`
    );
  } catch (e) {
    toast(e.message, "err");
  }
}

function showActionResult(d) {
  const kindNames = { transfer: "Transfer", loan: "Loan", terminate: "Terminate loan", release: "Release" };
  toast(`${kindNames[d.kind]} script generated for ${d.player}`, "ok");
  const msg =
    `${kindNames[d.kind]} script ready for <b>${d.player}</b>.\n\n` +
    `Script: <code>${d.script}</code>\n\n` +
    `1. Open Live Editor → Lua Engine\n` +
    `2. Run <i>${d.script.replace(/\\/g, "/")}</i>\n` +
    `3. SAVE THE CAREER in-game\n\n` +
    `Result is logged in <code>${d.log}</code> — ` +
    `script is idempotent, rerunning after a crash is safe.`;
  alert(msg);
}

$("pf-transfer").addEventListener("click", () => pickTeam("transfer"));
$("pf-loan").addEventListener("click", () => pickTeam("loan"));
$("tm-direct").addEventListener("click", () => applyDirect(tmKind, tmTeam));
$("tm-lua").addEventListener("click", () => runAction(tmKind, tmTeam));
$("pf-terminate").addEventListener("click", async () => {
  if (!confirm(`Terminate the loan of ${pfPlayer ? pfPlayer.name : ""}? (player returns to parent club — contract untouched)`)) return;
  try {
    const d = await apiPost("/api/action", { kind: "terminate", pid: pfPid });
    showActionResult(d);
  } catch (e) { toast(e.message, "err"); }
});
$("pf-release").addEventListener("click", async () => {
  if (!confirm(`Release ${pfPlayer ? pfPlayer.name : ""} to free agents?`)) return;
  try {
    const d = await apiPost("/api/action", { kind: "release", pid: pfPid });
    showActionResult(d);
  } catch (e) { toast(e.message, "err"); }
});
$("pf-terminate-direct").addEventListener("click", async () => applyDirect("terminate", null));
$("pf-release-direct").addEventListener("click", async () => {
  if (!confirm(`Release ${pfPlayer ? pfPlayer.name : ""} to free agents in the SQUADS FILE?`)) return;
  applyDirect("release", null);
});