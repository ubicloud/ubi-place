"use strict";

// ---------------------------------------------------------------------------
// Ubiplace client. Loads a packed snapshot, then streams live pixel diffs over
// SSE. All state is server-side; this file is just a viewport + input.
// ---------------------------------------------------------------------------

const state = {
  W: 0, H: 0,
  palette: [],
  cooldownMs: 200,
  seq: 0,
  color: 5,
  buf: null,          // Uint8Array of palette indices, length W*H
  off: null,          // offscreen 1:1 canvas
  offCtx: null,
  scale: 6,
  ox: 0, oy: 0,       // top-left offset of the canvas within the viewport
  hoverX: -1, hoverY: -1, // grid cell under the cursor (-1 = none)
  lastPlace: 0,
};

const GRID_MIN_SCALE = 6; // only draw gridlines once cells are this big (px)

const canvas = document.getElementById("canvas");
const ctx = canvas.getContext("2d", { alpha: false });
const wrap = document.getElementById("canvas-wrap");

// ---------- rendering ----------

function fitView() {
  const r = wrap.getBoundingClientRect();
  canvas.width = Math.floor(r.width);
  canvas.height = Math.floor(r.height);
  render();
}

function clampView() {
  const w = state.W * state.scale, h = state.H * state.scale;
  const vw = canvas.width, vh = canvas.height;
  // keep the artwork visible: allow some margin past edges
  const mx = Math.max(80, vw * 0.4), my = Math.max(80, vh * 0.4);
  state.ox = Math.min(vw - mx, Math.max(mx - w, state.ox));
  state.oy = Math.min(vh - my, Math.max(my - h, state.oy));
}

function render() {
  if (!state.off) return;
  clampView();
  const s = state.scale;
  ctx.imageSmoothingEnabled = false;
  ctx.fillStyle = "#0a0c18";
  ctx.fillRect(0, 0, canvas.width, canvas.height);
  ctx.drawImage(state.off, state.ox, state.oy, state.W * s, state.H * s);

  // gridlines — only when zoomed in enough to be legible; clipped to the viewport
  if (s >= GRID_MIN_SCALE) {
    const x0 = Math.max(0, Math.floor(-state.ox / s)), x1 = Math.min(state.W, Math.ceil((canvas.width - state.ox) / s));
    const y0 = Math.max(0, Math.floor(-state.oy / s)), y1 = Math.min(state.H, Math.ceil((canvas.height - state.oy) / s));
    ctx.strokeStyle = "rgba(255,255,255,0.08)";
    ctx.lineWidth = 1;
    ctx.beginPath();
    for (let x = x0; x <= x1; x++) {
      const px = Math.round(state.ox + x * s) + 0.5;
      ctx.moveTo(px, state.oy + y0 * s); ctx.lineTo(px, state.oy + y1 * s);
    }
    for (let y = y0; y <= y1; y++) {
      const py = Math.round(state.oy + y * s) + 0.5;
      ctx.moveTo(state.ox + x0 * s, py); ctx.lineTo(state.ox + x1 * s, py);
    }
    ctx.stroke();
  }

  // hover highlight — preview the selected color + outline the cell under the cursor
  if (state.hoverX >= 0 && state.hoverY >= 0) {
    const hx = state.ox + state.hoverX * s, hy = state.oy + state.hoverY * s;
    ctx.globalAlpha = 0.55;
    ctx.fillStyle = state.palette[state.color] || "#fff";
    ctx.fillRect(hx, hy, s, s);
    ctx.globalAlpha = 1;
    ctx.strokeStyle = "#ffffff";
    ctx.lineWidth = 2;
    ctx.strokeRect(Math.round(hx) + 1, Math.round(hy) + 1, s - 2, s - 2);
  }
}

function centerView() {
  state.ox = (canvas.width - state.W * state.scale) / 2;
  state.oy = (canvas.height - state.H * state.scale) / 2;
}

// ---------- pixel application ----------

function paint(i, c) {
  if (i < 0 || i >= state.buf.length) return;
  state.buf[i] = c;
  const x = i % state.W, y = (i / state.W) | 0;
  state.offCtx.fillStyle = state.palette[c] || "#000";
  state.offCtx.fillRect(x, y, 1, 1);
}

function applyChanges(changes) {
  for (const [i, c] of changes) paint(i, c);
  scheduleRender();
}

let rafPending = false;
function scheduleRender() {
  if (rafPending) return;
  rafPending = true;
  requestAnimationFrame(() => { rafPending = false; render(); });
}

// ---------- snapshot / boot ----------

async function boot() {
  const snap = await (await fetch("/snapshot")).json();
  state.W = snap.width;
  state.H = snap.height;
  state.palette = snap.palette;
  state.cooldownMs = snap.cooldown_ms;
  state.seq = snap.seq;
  state.color = Math.min(5, state.palette.length - 1);

  const bytes = Uint8Array.from(atob(snap.data), (ch) => ch.charCodeAt(0));
  state.buf = bytes;

  state.off = document.createElement("canvas");
  state.off.width = state.W;
  state.off.height = state.H;
  state.offCtx = state.off.getContext("2d");
  state.offCtx.fillStyle = state.palette[0];
  state.offCtx.fillRect(0, 0, state.W, state.H);
  for (let i = 0; i < bytes.length; i++) {
    if (bytes[i]) paint(i, bytes[i]);
  }

  applyBranding(snap);
  buildPalette();
  fitView();
  // initial scale: fit-to-view, then 2x for chunkier pixels (pan to see the rest)
  const fit = Math.min(canvas.width / state.W, canvas.height / state.H) * 0.82;
  state.scale = Math.max(4, Math.floor(fit) * 2);
  centerView();
  render();

  loadMe();
  initAdmin();
  connect();
}

// ---------- admin (unlocked by ?key=, validated server-side) ----------

let adminKey = null;

async function initAdmin() {
  const k = new URLSearchParams(location.search).get("key");
  if (!k) return;
  // Drop the key from the address bar so it isn't bookmarked or shared by accident.
  history.replaceState({}, "", location.pathname);
  try {
    const res = await fetch("/admin/status", { headers: { "X-Admin-Key": k } });
    if (!res.ok) { toast("admin key rejected"); return; }
    adminKey = k;
    showAdmin((await res.json()).ambient);
  } catch (_) {}
}

function showAdmin(ambient) {
  document.getElementById("admin-card").hidden = false;
  const amb = document.getElementById("admin-ambient");
  amb.checked = !!ambient;
  amb.addEventListener("change", async () => {
    try {
      const res = await fetch("/admin/ambient", {
        method: "POST",
        headers: { "X-Admin-Key": adminKey, "Content-Type": "application/json" },
        body: JSON.stringify({ enabled: amb.checked }),
      });
      amb.checked = !!(await res.json()).ambient;
      toast(`ambient bot ${amb.checked ? "on" : "off"}`);
    } catch (_) { toast("toggle failed"); }
  });
  document.getElementById("admin-clear").addEventListener("click", async () => {
    if (!confirm("Clear the entire board for everyone?")) return;
    try {
      await fetch("/admin/clear", { method: "POST", headers: { "X-Admin-Key": adminKey } });
      toast("board cleared");
    } catch (_) { toast("clear failed"); }
  });
}

// ---------- live stream ----------

// The browser fires onerror (and auto-reconnects) only when it *notices* the
// socket close. A half-open connection — e.g. when a web server is recycled and
// its VM is destroyed mid-deploy — is never noticed, so the stream silently goes
// stale and the badge stays "live" forever. Guard against that with a watchdog:
// the server sends a heartbeat every ~3s, so if nothing arrives for STALE_MS we
// treat the stream as dead and force a fresh reconnect (resuming from state.seq).
const STALE_MS = 3000; // ~3 missed 1s heartbeats => treat the stream as dead
let es = null;
let lastBeat = 0;
let watchdog = null;

function connect() {
  if (es) es.close();
  if (watchdog) clearInterval(watchdog);

  es = new EventSource(`/events?since=${state.seq}`);
  lastBeat = Date.now();
  const beat = () => { lastBeat = Date.now(); };

  es.addEventListener("pixels", (e) => {
    beat();
    if (e.lastEventId) state.seq = parseInt(e.lastEventId, 10);
    applyChanges(JSON.parse(e.data));
  });
  es.addEventListener("heartbeat", (e) => { beat(); updateBadge(JSON.parse(e.data)); });
  es.onopen = () => { beat(); setLive(true); };
  es.onerror = () => setLive(false); // EventSource auto-reconnects with Last-Event-ID

  watchdog = setInterval(() => {
    if (Date.now() - lastBeat > STALE_MS) {
      setLive(false);
      connect(); // closes the dead stream and reconnects, resuming from state.seq
    }
  }, 1000);
}

function setLive(on) {
  const el = document.getElementById("live");
  el.className = "live " + (on ? "live--on" : "live--off");
  el.lastChild.textContent = on ? "live" : "reconnecting";
}

// ---------- badge / stats ----------

// Title/tagline come from config (the Secret Store on Ubicloud). Applied from the
// snapshot on load and from each heartbeat — so a redeploy with a new TITLE
// updates the header live as web replicas roll.
let prevTitle = null;
function applyBranding(s) {
  const title = s.title || "Ubiplace";
  const tagline = s.tagline || "";
  const el = document.getElementById("app-title");
  if (el && el.textContent !== title) {
    el.textContent = title;
    if (prevTitle !== null && prevTitle !== title) flashEl(el);
  }
  document.title = tagline ? `${title} — ${tagline}` : title;
  prevTitle = title;
}

let prev = { version: null, instance: null };
function updateBadge(s) {
  applyBranding(s);
  // Keep the admin toggle in sync with the live state (unless the user is on it).
  if (adminKey && typeof s.ambient === "boolean") {
    const amb = document.getElementById("admin-ambient");
    if (amb && document.activeElement !== amb) amb.checked = s.ambient;
  }
  setText("stat-version", s.version);
  setText("stat-instance", s.instance);
  setText("stat-uptime", fmtUptime(s.uptime));
  setText("stat-online", s.online);
  setText("stat-queue", s.queue);

  if (prev.version !== null && prev.version !== s.version) flash("chip-version");
  if (prev.instance !== null && prev.instance !== s.instance) flash("chip-instance");
  prev.version = s.version;
  prev.instance = s.instance;

  const ol = document.getElementById("leaders");
  if (!s.leaders || !s.leaders.length) {
    ol.innerHTML = '<li class="empty">no pixels yet</li>';
  } else {
    ol.innerHTML = s.leaders.map((l, i) =>
      `<li><span class="rank">${i + 1}</span><span class="lname">${escapeHtml(l.name)}</span><span class="lcount">${l.pixel_count}</span></li>`
    ).join("");
  }
}

function flash(id) { flashEl(document.getElementById(id)); }
function flashEl(el) {
  if (!el) return;
  el.classList.remove("flash");
  void el.offsetWidth; // restart animation
  el.classList.add("flash");
}

function fmtUptime(s) {
  s = Math.max(0, s | 0);
  if (s < 60) return s + "s";
  if (s < 3600) return (s / 60 | 0) + "m " + (s % 60) + "s";
  return (s / 3600 | 0) + "h " + ((s % 3600) / 60 | 0) + "m";
}

// ---------- palette ----------

function buildPalette() {
  const bar = document.getElementById("palette");
  bar.innerHTML = "";
  state.palette.forEach((hex, i) => {
    if (i === 0) return; // index 0 is the background / eraser-ish
    const sw = document.createElement("button");
    sw.className = "swatch" + (i === state.color ? " sel" : "");
    sw.style.background = hex;
    sw.title = hex;
    sw.addEventListener("click", () => selectColor(i));
    bar.appendChild(sw);
  });
}

function selectColor(i) {
  state.color = i;
  [...document.querySelectorAll(".swatch")].forEach((s, idx) =>
    s.classList.toggle("sel", idx + 1 === i));
  scheduleRender(); // refresh the hover preview to the new color
}

// ---------- input: pan / zoom / place ----------

let drag = null;

wrap.addEventListener("pointerdown", (e) => {
  drag = { x: e.clientX, y: e.clientY, ox: state.ox, oy: state.oy, moved: false };
  wrap.setPointerCapture(e.pointerId);
});

wrap.addEventListener("pointermove", (e) => {
  // track the hovered cell for the highlight
  const c = cellAt(e.clientX, e.clientY);
  const hx = (c.x >= 0 && c.y >= 0 && c.x < state.W && c.y < state.H) ? c.x : -1;
  const hy = hx >= 0 ? c.y : -1;
  if (hx !== state.hoverX || hy !== state.hoverY) {
    state.hoverX = hx; state.hoverY = hy;
    scheduleRender();
  }

  if (!drag) return;
  const dx = e.clientX - drag.x, dy = e.clientY - drag.y;
  if (Math.abs(dx) + Math.abs(dy) > 4) drag.moved = true;
  if (drag.moved) {
    state.ox = drag.ox + dx;
    state.oy = drag.oy + dy;
    scheduleRender();
  }
});

function clearHover() {
  if (state.hoverX !== -1 || state.hoverY !== -1) {
    state.hoverX = -1; state.hoverY = -1;
    scheduleRender();
  }
}
wrap.addEventListener("pointerleave", clearHover);

wrap.addEventListener("pointerup", (e) => {
  if (drag && !drag.moved) placeAt(e.clientX, e.clientY);
  drag = null;
  if (e.pointerType !== "mouse") clearHover(); // touch: don't leave a stuck highlight
});

wrap.addEventListener("wheel", (e) => {
  e.preventDefault();
  const r = canvas.getBoundingClientRect();
  const cx = e.clientX - r.left, cy = e.clientY - r.top;
  const factor = e.deltaY < 0 ? 1.15 : 1 / 1.15;
  const ns = Math.min(40, Math.max(1, state.scale * factor));
  // zoom toward the cursor
  state.ox = cx - (cx - state.ox) * (ns / state.scale);
  state.oy = cy - (cy - state.oy) * (ns / state.scale);
  state.scale = ns;
  scheduleRender();
}, { passive: false });

function cellAt(clientX, clientY) {
  const r = canvas.getBoundingClientRect();
  const x = Math.floor((clientX - r.left - state.ox) / state.scale);
  const y = Math.floor((clientY - r.top - state.oy) / state.scale);
  return { x, y };
}

async function placeAt(clientX, clientY) {
  const { x, y } = cellAt(clientX, clientY);
  if (x < 0 || y < 0 || x >= state.W || y >= state.H) return;

  const now = Date.now();
  const wait = state.cooldownMs - (now - state.lastPlace);
  if (wait > 0) { cooldown(wait); return; }
  state.lastPlace = now;
  if (state.cooldownMs > 250) cooldown(state.cooldownMs);

  // optimistic: paint immediately, server diff confirms
  paint(y * state.W + x, state.color);
  scheduleRender();

  try {
    const res = await fetch("/place", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ x, y, color: state.color }),
    });
    if (res.status === 429) {
      const j = await res.json();
      cooldown(j.cooldown_ms || state.cooldownMs);
    } else if (res.ok) {
      bump("you-count");
    }
  } catch (_) {
    toast("offline — placement not saved");
  }
}

// ---------- cooldown UI ----------

let cdTimer = null;
function cooldown(ms) {
  const box = document.getElementById("cooldown");
  const bar = document.getElementById("cooldown-bar");
  box.hidden = false;
  const start = Date.now();
  clearInterval(cdTimer);
  cdTimer = setInterval(() => {
    const p = Math.max(0, 1 - (Date.now() - start) / ms);
    bar.style.setProperty("--p", p.toFixed(3));
    if (p <= 0) { clearInterval(cdTimer); box.hidden = true; }
  }, 30);
}

// ---------- you ----------

async function loadMe() {
  try {
    const me = await (await fetch("/me")).json();
    setText("you-name", me.name);
    setText("you-count", me.count);
  } catch (_) {}
}

// ---------- helpers ----------

function setText(id, v) { const el = document.getElementById(id); if (el) el.textContent = v; }
function bump(id) { const el = document.getElementById(id); if (el) el.textContent = (parseInt(el.textContent, 10) || 0) + 1; }
function escapeHtml(s) { return String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c])); }

let toastTimer = null;
function toast(msg) {
  const t = document.getElementById("toast");
  t.textContent = msg; t.hidden = false;
  requestAnimationFrame(() => t.classList.add("show"));
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { t.classList.remove("show"); setTimeout(() => (t.hidden = true), 250); }, 2200);
}

window.addEventListener("resize", fitView);
boot().catch((e) => { console.error(e); toast("failed to load canvas"); });
