# ▦ Ubiplace

A tiny **collaborative pixel canvas** (think r/place) built to showcase
[Ubicloud's app service](https://www.ubicloud.com). Everyone shares one grid;
click to drop a pixel; the canvas updates live for everyone.

It exists to demonstrate four things at once:

1. **It needs a database.** The whole canvas, the placement queue, painters and
   the leaderboard live in PostgreSQL. Nothing is kept in process memory.
2. **It needs web *and* worker processes.** The `web` process serves the page and
   *enqueues* placements; the `worker` applies them, rebuilds snapshots, keeps the
   leaderboard, and runs an ambient "bot" so the canvas is never static.
3. **It shows off zero-downtime staggered deploys.** A live **`ver`** and
   **`⬢ inst`** badge tell you which release and which replica are serving you.
   Redeploy and watch them flip *one replica at a time* while pixels keep landing
   and not a single one is lost.
4. **It's fun.** It's a pixel canvas.

---

## Architecture

```
                 ┌──────────── per-app load balancer (TCP :8080) ───────────┐
                 │                                                           │
        ┌────────▼────────┐   ┌─────────────────┐            ┌──────────────▼─┐
 you ──▶│  web replica 1  │   │  web replica 2  │   ...      │   web replica N │
        │   Roda + SSE    │   │   Roda + SSE    │            │   Roda + SSE    │
        └───┬────────▲────┘   └───┬────────▲────┘            └───┬────────▲────┘
            │ enqueue│ LISTEN     │        │                     │        │
            ▼        │ pixel_update                              ▼        │
        ┌───────────────────────────── PostgreSQL ──────────────────────────┐
        │  pixel · placement(queue) · snapshot · painter   (+ canvas_seq)    │
        └───────────────────────────────▲───────────────────────────────────┘
                                         │ drain queue, NOTIFY, snapshot, leaderboard, ambient
                                  ┌──────┴───────┐
                                  │    worker    │  (singleton)
                                  └──────────────┘
```

- **Placement is optimistic + queued.** The browser paints your pixel instantly
  and `POST /place` just drops a row in the `placement` queue. The worker drains
  it (within ~a frame, NOTIFY-driven), assigns a monotonic `seq`, and `NOTIFY`s.
- **Live updates via SSE with a cursor.** `GET /events` streams pixel diffs and
  sets `id: <seq>` on each one. If your connection drops mid-deploy because your
  web replica was swapped, the browser reconnects and sends `Last-Event-ID`, so
  you resume exactly where you left off — **no pixel is ever missed.** This is the
  core trick that makes a rolling deploy invisible.
- **Fast first paint.** The worker keeps a packed one-byte-per-cell `snapshot`;
  the page loads it in one request, then catches up via the stream.

## Process model (Procfile)

```
web:    bundle exec puma -C config/puma.rb     # binds :8080 (or $PORT)
worker: bundle exec ruby worker.rb             # singleton background process
```

On Deploy, Ubicloud clones this repo onto the app VM and builds it there with
**Cloud Native Buildpacks** (`pack`) — there's no Dockerfile and nothing
Heroku-specific in this repo. (The platform happens to use the open
`heroku/builder:24` builder image — a standard, vendor-neutral CNB build toolchain;
despite the name it has nothing to do with deploying *to* Heroku. That choice lives
in the platform, in `rhizome/app_service/bin/deploy`, not here.) The builder
auto-detects Ruby from `Gemfile` + `.ruby-version` (pinned to **Ruby 4.0.5**); the
stack is **Roda + Sequel + Puma + pg** — the same web framework Ubicloud itself is
built on. The `web` process listens on **8080** (the port the per-app load balancer
forwards to, with a TCP health check). Migrations run automatically at boot under a
Postgres advisory lock (this platform has no release phase).

## Configuration — and how it uses the Secret Store

On Ubicloud the **Config page is a thin wrapper over the app's Secret Store**. At
each deploy the app VM's **managed identity** fetches every Secret Store key and
the platform injects them as environment variables (at build *and* run time). So
"using the Secret Store" simply means reading config from `ENV` — which this app
does for everything below.

| Key | Default | Meaning |
| --- | --- | --- |
| `TITLE` | `Ubiplace` | Header + page title. **Try this one to see the Secret Store in action** — it's sent in the SSE heartbeat, so a redeploy with a new `TITLE` updates the header *live as replicas roll*. |
| `TAGLINE` | `a tiny collaborative pixel canvas` | Subtitle (used in the document title). |
| `ADMIN_KEY` | — | Secret that unlocks admin actions. Unset ⇒ admin disabled. See [Admin](#admin). |
| `APP_VERSION` | contents of `VERSION` file, else `dev` | Release label in the badge. |
| `COOLDOWN_MS` | `200` | Per-painter cooldown between placements. |
| `AMBIENT` | `on` | *Initial* ambient-bot state; admin can toggle it live (persisted in the DB). |
| `AMBIENT_INTERVAL` | `0.4` | Seconds between ambient spray ticks. |
| `SNAPSHOT_INTERVAL` | `3` | Seconds between snapshot rebuilds. |
| `CANVAS_WIDTH` / `CANVAS_HEIGHT` | `100` | Grid size (set before first deploy). |

### Admin

Set **`ADMIN_KEY`** in the Config page (it lands in the Secret Store and is
injected as env at deploy — a real *secret* gating real actions, vs. `TITLE`'s
plain config). Then open the app with that key as a query param:

```
https://<app>.ubicloud.app/?key=YOUR_ADMIN_KEY
```

The client validates the key server-side, removes it from the address bar, and
reveals an **Admin** panel with:

- **Clear the board** — wipes every cell back to background for all connected
  clients (and drops the pending queue + resets the leaderboard). It flows through
  the normal seq/diff/SSE pipeline, so everyone's canvas clears live.
- **Ambient bot on/off** — toggles the worker's ambient painter at runtime (stored
  in a `setting` row the worker reads; takes effect within ~1s, no redeploy).

Server-side, every `/admin/*` route requires the key in an `X-Admin-Key` header and
checks it with a constant-time compare; with no `ADMIN_KEY` configured, admin is
fully disabled (all admin routes return 403). Note: passing a secret in a URL is
convenient but not airtight (it can land in browser history / proxy logs), so treat
`ADMIN_KEY` as a low-stakes demo control, not production-grade authz.

### Database connection (no secret needed)

The attached Postgres uses **managed-identity cert auth**, not a password. On
attach, the platform uses the VM's managed identity to fetch a client cert and
injects standard libpq env — `PGHOST`, `PGPORT`, `PGDATABASE`, `PGUSER`,
`PGSSLMODE=verify-full`, `PGSSLROOTCERT`, `PGSSLCERT`, `PGSSLKEY` — with **no
stored credential**, so there's no `DATABASE_URL` in the Secret Store. `lib/db.rb`
connects straight from that env (and falls back to `DATABASE_URL` for local dev).

---

## Deploy on Ubicloud

1. **Create the app** pointing at the public repo + branch:
   `https://github.com/ubicloud/ubi-place` · `main`.
2. **Attach Postgres** (one click) — the platform wires the DB to the app via the
   VM's managed identity (mTLS client cert); no password or `DATABASE_URL` is stored.
3. *(Optional)* set **`TITLE`** in the Config page to see the Secret Store feed the app.
4. **Scale `web` to ≥ 2 replicas** so the staggered rollout is visible
   (worker stays a singleton).
5. **Click Deploy.** Each replica clones the commit, `pack build`s, and comes up
   behind the load balancer. Open `https://<app>.ubicloud.app`.

## The zero-downtime demo

1. Open the app. Note the **`ver`** (e.g. `v1`) and **`⬢ inst`** chips up top, and
   the ambient bot keeping the canvas alive. Draw a few pixels.
2. Make a *visible* change — the most legible options:
   - bump `VERSION` from `v1` to `v2`, and/or
   - add a new color to `PALETTE` in `lib/canvas.rb`, and/or
   - change `TITLE` in the Config page (no code change) — it lives in the Secret
     Store and updates the header *live* as replicas roll, no full reload.
3. **Deploy again.** Keep the canvas in view and watch the top bar: as the
   platform swaps web replicas one at a time, the **`⬢ inst`** chip flips to new
   instance ids (it flashes on change) and **`ver`** rolls `v1 → v2`. The canvas
   never freezes, your cursor keeps painting, and the ambient bot never stops.
4. (Bonus) Watch the **`queue`** chip during the worker's recreate: it ticks up
   for a second, then drains to zero — the worker restarted and caught up without
   losing a placement.

## Run locally

```bash
createdb ubiplace                 # needs PostgreSQL
bundle install
# terminal 1
DATABASE_URL=postgres:///ubiplace bundle exec puma -C config/puma.rb
# terminal 2
DATABASE_URL=postgres:///ubiplace bundle exec ruby worker.rb
# open http://localhost:8080
```

To rehearse the deploy demo locally, run two web processes on different ports and
put them behind any load balancer, then restart them one at a time.
