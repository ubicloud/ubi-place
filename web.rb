# frozen_string_literal: true

require "roda"
require "sequel"
require "json"
require "base64"
require "securerandom"

require_relative "lib/db"
require_relative "lib/canvas"
require_relative "lib/version"
require_relative "lib/names"
require_relative "lib/notifier"
require_relative "lib/settings"
require_relative "lib/log"

# Shared logger for this web process. Request lines come from Log::Middleware
# (wired in config.ru); everything else logs through this directly.
LOG = Log.new("web")

COOLDOWN_MS = Integer(ENV.fetch("COOLDOWN_MS", "200"))
PIXEL_CHANNEL = "pixel_update"
PLACE_CHANNEL = "placement_queued"

# Admin secret, from the Secret Store (injected as env at deploy). When unset,
# admin features are completely disabled. Holding it lets a client (passing it as
# ?key= in the URL) clear the board and toggle the ambient bot.
ADMIN_KEY = ENV["ADMIN_KEY"].to_s
AMBIENT_DEFAULT = ENV.fetch("AMBIENT", "on") == "on"

# Branding pulled from config. On Ubicloud these come from the app's Secret Store:
# the VM's managed identity fetches every key at deploy and the platform injects
# them as env (the Config page is just a wrapper over the store). Because TITLE is
# also sent in the SSE heartbeat, redeploying with a new TITLE updates the header
# live as web replicas roll over — the Secret Store woven into the deploy demo.
TITLE = ENV["TITLE"].to_s.empty? ? "Ubiplace" : ENV["TITLE"]
TAGLINE = ENV["TAGLINE"].to_s.empty? ? "a tiny collaborative pixel canvas" : ENV["TAGLINE"]

# Boot: connect, ensure schema, drop any now-out-of-bounds canvas data (e.g. after
# a board resize), start the LISTEN bridge.
DB_CONN = DB.connect
DB.migrate!(DB_CONN)
DB.prune_canvas!(DB_CONN, Canvas::WIDTH, Canvas::HEIGHT)
NOTIFIER = Notifier.new(PIXEL_CHANNEL, logger: LOG) { DB.raw_pg }.start
LOG.info("web up version=#{AppVersion::VERSION} cooldown_ms=#{COOLDOWN_MS} title=#{TITLE.inspect}")

# Process-wide 1s cache so a crowd of SSE heartbeats doesn't hammer the DB.
STATS_LOCK = Mutex.new
STATS_CACHE = { at: Time.at(0), data: nil }

class Web < Roda
  plugin :public, root: File.expand_path("public", __dir__)
  plugin :streaming
  plugin :cookies # response.set_cookie for the painter id

  # ----- helpers (run in the route's instance context) -----

  private

  def db = DB_CONN

  def json(data)
    response["Content-Type"] = "application/json"
    JSON.generate(data)
  end

  # Identify a painter by a long-lived cookie (no login). Created lazily.
  def painter_id
    id = request.cookies["pid"]
    unless id&.match?(/\A[a-f0-9]{16}\z/)
      id = SecureRandom.hex(8)
      response.set_cookie("pid", value: id, path: "/", max_age: 31_536_000, same_site: :lax)
    end
    id
  end

  def ensure_painter(id)
    db[:painter].insert_conflict.insert(id: id, name: Names.random, created_at: Time.now)
  end

  # All pixels with seq greater than the client's cursor, plus the new cursor.
  def diff_since(cursor)
    rows = db[:pixel].where { seq > cursor }.order(:seq).limit(8000).select(:x, :y, :color, :seq).all
    return [[], cursor] if rows.empty?

    [rows.map { |r| [Canvas.index_for(r[:x], r[:y]), r[:color]] }, rows.last[:seq]]
  end

  def stats
    STATS_LOCK.synchronize do
      if Time.now - STATS_CACHE[:at] > 1
        STATS_CACHE[:at] = Time.now
        STATS_CACHE[:data] = {
          title: TITLE,
          tagline: TAGLINE,
          ambient: ambient_enabled?,
          instance: AppVersion::INSTANCE,
          version: AppVersion::VERSION,
          uptime: (Time.now - AppVersion::BOOT_AT).round,
          online: NOTIFIER.size,
          queue: db[:placement].where(processed_at: nil).count,
          pixels: (db[:pixel].max(:seq) || 0),
          leaders: db[:painter].where { pixel_count > 0 }
            .order(Sequel.desc(:pixel_count)).limit(8).select(:name, :pixel_count).all
        }
      end
      STATS_CACHE[:data]
    end
  end

  def sse_event(event, data)
    "event: #{event}\ndata: #{JSON.generate(data)}\n\n"
  end

  # ----- admin -----

  def ambient_enabled?
    Settings.get_bool(db, "ambient_enabled", AMBIENT_DEFAULT)
  end

  # Constant-time check of the key sent in the X-Admin-Key header. False when no
  # ADMIN_KEY is configured, so admin is off by default.
  def admin_ok?
    return false if ADMIN_KEY.empty?

    provided = request.env["HTTP_X_ADMIN_KEY"].to_s
    !provided.empty? && Rack::Utils.secure_compare(ADMIN_KEY, provided)
  end

  # Wipe the board for everyone. Repaints every non-empty cell back to background
  # with a fresh seq (so it flows out through the normal diff/SSE path — clients
  # need no special handling), drops the pending queue, and resets the leaderboard.
  def clear_board!
    db.transaction do
      db[:placement].where(processed_at: nil).delete
      db.run("UPDATE pixel SET color = 0, seq = nextval('canvas_seq'), painter_id = NULL WHERE color <> 0")
      db[:painter].update(pixel_count: 0)
    end
    db.run("NOTIFY #{PIXEL_CHANNEL}")
  end

  # ----- routes -----

  route do |r|
    r.public # static assets (style.css, app.js) from ./public

    r.root do
      response["Content-Type"] = "text/html"
      File.read(File.expand_path("public/index.html", __dir__))
    end

    # TCP health check is all the LB needs, but a real body is handy for debugging.
    r.get "healthz" do
      response["Content-Type"] = "text/plain"
      "ok #{AppVersion::VERSION} #{AppVersion::INSTANCE}"
    end

    # Packed full canvas for a fast first paint.
    r.get "snapshot" do
      row = db[:snapshot].where(id: 1).first
      # Ignore a stale-sized snapshot (left over from a board resize until the
      # worker rebuilds it): serve an empty board and let the client backfill.
      if row && row[:data].to_s.bytesize == Canvas::SIZE
        data = row[:data]
        seq = row[:seq]
      else
        data = "\x00".b * Canvas::SIZE
        seq = 0
      end
      json(
        title: TITLE, tagline: TAGLINE,
        width: Canvas::WIDTH, height: Canvas::HEIGHT, palette: Canvas::PALETTE,
        cooldown_ms: COOLDOWN_MS, seq: seq, data: Base64.strict_encode64(data)
      )
    end

    r.get "diff" do
      changes, cur = diff_since(request.params["since"].to_i)
      json(seq: cur, changes: changes)
    end

    r.get "stats" do
      json(stats)
    end

    r.get "me" do
      id = painter_id
      ensure_painter(id)
      p = db[:painter].where(id: id).first
      json(id: id, name: p[:name], count: p[:pixel_count])
    end

    # Admin actions, gated by the X-Admin-Key header (the secret from the store).
    r.on "admin" do
      unless admin_ok?
        response.status = 403
        next json(error: "forbidden")
      end

      # Probe used by the client to verify ?key= and learn current state.
      r.get "status" do
        json(ok: true, ambient: ambient_enabled?)
      end

      r.post "clear" do
        clear_board!
        json(ok: true)
      end

      r.post "ambient" do
        body = (JSON.parse(request.body.read) rescue {})
        enabled = body["enabled"] ? true : false
        Settings.set(db, "ambient_enabled", enabled)
        json(ok: true, ambient: enabled)
      end
    end

    # Enqueue a pixel. Cheap and fast: cooldown gate + insert into the queue; the
    # worker applies it. The client renders optimistically so it feels instant.
    r.post "place" do
      body = (JSON.parse(request.body.read) rescue {})
      x = body["x"].to_i
      y = body["y"].to_i
      color = body["color"].to_i
      unless Canvas.in_bounds?(x, y)
        response.status = 422
        next json(error: "out of bounds")
      end
      unless Canvas.valid_color?(color)
        response.status = 422
        next json(error: "bad color")
      end

      id = painter_id
      ensure_painter(id)
      now = Time.now
      threshold = now - (COOLDOWN_MS / 1000.0)
      allowed = db[:painter].where(id: id)
        .where(Sequel.|({ last_placed_at: nil }, (Sequel[:last_placed_at] < threshold)))
        .update(last_placed_at: now) == 1
      unless allowed
        response.status = 429
        next json(error: "cooldown", cooldown_ms: COOLDOWN_MS)
      end

      db[:placement].insert(x: x, y: y, color: color, painter_id: id, created_at: now)
      db.run("NOTIFY #{PLACE_CHANNEL}")
      json(ok: true)
    end

    # Server-Sent Events: live pixel diffs + periodic heartbeat (instance/version/
    # online/queue). The `id:` line is the seq cursor — on reconnect the browser
    # sends it back as Last-Event-ID, so a client whose connection is dropped
    # mid-deploy (its replica was swapped) resumes exactly where it left off with
    # no lost pixels. THIS is what makes a rolling deploy invisible.
    r.get "events" do
      response["Content-Type"] = "text/event-stream"
      response["Cache-Control"] = "no-cache"
      response["X-Accel-Buffering"] = "no"

      cursor = (request.env["HTTP_LAST_EVENT_ID"] || request.params["since"] || "0").to_i
      queue = NOTIFIER.subscribe
      stream(loop: false) do |out|
        out << "retry: 250\n\n" # reconnect ~250ms after a drop (browser default is ~3s)
        out << sse_event("heartbeat", stats)
        last_beat = Time.now
        loop do
          queue.pop(timeout: 1) # woken by NOTIFY, or 1s tick
          changes, cursor = diff_since(cursor)
          out << "id: #{cursor}\nevent: pixels\ndata: #{JSON.generate(changes)}\n\n" unless changes.empty?
          if Time.now - last_beat >= 1 # heartbeat every ~1s so the client watchdog can detect a dead stream fast
            out << sse_event("heartbeat", stats)
            last_beat = Time.now
          end
        end
      rescue IOError, Errno::EPIPE, Errno::ECONNRESET
        # client disconnected
      ensure
        NOTIFIER.unsubscribe(queue)
      end
    end
  end
end
