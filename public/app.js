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
  lastPlace: 0,
};

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
  ctx.imageSmoothingEnabled = false;
  ctx.fillStyle = "#0a0c18";
  ctx.fillRect(0, 0, canvas.width, canvas.height);
  ctx.drawImage(state.off, state.ox, state.oy, state.W * state.scale, state.H * state.scale);
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
  // initial scale: fit the canvas comfortably in view
  state.scale = Math.max(2, Math.floor(Math.min(canvas.width / state.W, canvas.height / state.H) * 0.82));
  centerView();
  render();

  loadMe();
  connect();
}

// ---------- live stream ----------

function connect() {
  const es = new EventSource(`/events?since=${state.seq}`);
  es.addEventListener("pixels", (e) => {
    if (e.lastEventId) state.seq = parseInt(e.lastEventId, 10);
    applyChanges(JSON.parse(e.data));
  });
  es.addEventListener("heartbeat", (e) => updateBadge(JSON.parse(e.data)));
  es.onopen = () => setLive(true);
  es.onerror = () => setLive(false); // EventSource auto-reconnects with Last-Event-ID
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
}

// ---------- input: pan / zoom / place ----------

let drag = null;

wrap.addEventListener("pointerdown", (e) => {
  drag = { x: e.clientX, y: e.clientY, ox: state.ox, oy: state.oy, moved: false };
  wrap.setPointerCapture(e.pointerId);
});

wrap.addEventListener("pointermove", (e) => {
  if (!drag) return;
  const dx = e.clientX - drag.x, dy = e.clientY - drag.y;
  if (Math.abs(dx) + Math.abs(dy) > 4) drag.moved = true;
  if (drag.moved) {
    state.ox = drag.ox + dx;
    state.oy = drag.oy + dy;
    scheduleRender();
  }
});

wrap.addEventListener("pointerup", (e) => {
  if (drag && !drag.moved) placeAt(e.clientX, e.clientY);
  drag = null;
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
