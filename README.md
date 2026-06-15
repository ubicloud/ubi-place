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

## Configuration (set as app config / Secret Store keys)

| Key | Default | Meaning |
| --- | --- | --- |
| `DATABASE_URL` | — | Injected automatically when you attach Postgres. |
| `APP_VERSION` | contents of `VERSION` file, else `dev` | Release label in the badge. |
| `COOLDOWN_MS` | `200` | Per-painter cooldown between placements. |
| `AMBIENT` | `on` | Set to `off` to silence the ambient bot. |
| `AMBIENT_INTERVAL` | `0.4` | Seconds between ambient spray ticks. |
| `SNAPSHOT_INTERVAL` | `3` | Seconds between snapshot rebuilds. |
| `CANVAS_WIDTH` / `CANVAS_HEIGHT` | `100` | Grid size (set before first deploy). |

---

## Deploy on Ubicloud

1. **Create the app** pointing at the public repo + branch:
   `https://github.com/ubicloud/ubi-place` · `main`.
2. **Attach Postgres** (one click) — this injects `DATABASE_URL`.
3. **Scale `web` to ≥ 2 replicas** so the staggered rollout is visible
   (worker stays a singleton).
4. **Click Deploy.** Each replica clones the commit, `pack build`s, and comes up
   behind the load balancer. Open `https://<app>.ubicloud.app`.

## The zero-downtime demo

1. Open the app. Note the **`ver`** (e.g. `v1`) and **`⬢ inst`** chips up top, and
   the ambient bot keeping the canvas alive. Draw a few pixels.
2. Make a *visible* change and commit it — the most legible options:
   - bump `VERSION` from `v1` to `v2`, and/or
   - add a new color to `PALETTE` in `lib/canvas.rb`.
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
