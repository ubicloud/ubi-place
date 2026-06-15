# frozen_string_literal: true

# The `worker` process. Started by the buildpack as the Procfile `worker:` entry.
#
# It is genuinely load-bearing — the web process only *enqueues* placements; the
# worker is what:
#   1. drains the placement queue into the canvas (assigning each pixel a seq),
#   2. NOTIFYs web replicas so SSE clients see changes within ~a frame,
#   3. rebuilds the packed snapshot for fast first paints,
#   4. keeps the leaderboard (per-painter pixel counts),
#   5. optionally runs an "ambient bot" so the canvas is alive with zero visitors
#      — which makes every deploy a live "it never stopped" demo.
#
# It's a singleton and is recreated on deploy. Because the queue lives in Postgres
# and draining is idempotent, a worker restart never loses a pixel: the queue just
# rises for a moment and then drains. State is 100% in the DB.

require "sequel"
require "pg"
require_relative "lib/db"
require_relative "lib/canvas"
require_relative "lib/names"

SNAPSHOT_INTERVAL = Float(ENV.fetch("SNAPSHOT_INTERVAL", "3"))
AMBIENT = ENV.fetch("AMBIENT", "on") == "on"
AMBIENT_INTERVAL = Float(ENV.fetch("AMBIENT_INTERVAL", "0.4"))
AMBIENT_ID = "ambient"

DB_CONN = DB.connect
DB.migrate!(DB_CONN)

# Apply many placements in one statement each: nextval('canvas_seq') is evaluated
# once per row and reused via EXCLUDED.seq, so the new pixel's seq is strictly
# greater than every previously committed seq.
UPSERT_SQL = <<~SQL
  INSERT INTO pixel (x, y, color, seq, painter_id)
  VALUES (?, ?, ?, nextval('canvas_seq'), ?)
  ON CONFLICT (x, y) DO UPDATE
    SET color = EXCLUDED.color, seq = EXCLUDED.seq, painter_id = EXCLUDED.painter_id
SQL

def drain(db)
  rows = db[:placement].where(processed_at: nil).order(:id).limit(1000).all
  return 0 if rows.empty?

  db.transaction do
    rows.each do |p|
      db.dataset.with_sql(UPSERT_SQL, p[:x], p[:y], p[:color], p[:painter_id]).update
      db[:painter].where(id: p[:painter_id]).update(pixel_count: Sequel[:pixel_count] + 1) if p[:painter_id]
    end
    db[:placement].where(id: rows.map { |r| r[:id] }).update(processed_at: Time.now)
  end
  db.run("NOTIFY pixel_update")
  rows.size
end

def build_snapshot(db)
  max = db[:pixel].max(:seq) || 0
  bytes = ("\x00".b * Canvas::SIZE)
  db[:pixel].select(:x, :y, :color).each do |r|
    bytes.setbyte(Canvas.index_for(r[:x], r[:y]), r[:color] & 0xff)
  end
  blob = Sequel.blob(bytes)
  db[:snapshot]
    .insert_conflict(target: :id, update: { seq: max, data: blob, created_at: Time.now })
    .insert(id: 1, seq: max, data: blob, created_at: Time.now)
  max
end

# A drifting, color-cycling spray so the canvas is never static.
def ambient_tick(db, tick)
  3.times do |k|
    t = tick + (k * 7)
    x = (Canvas::WIDTH / 2.0 + (Math.sin(t / 9.0) * Canvas::WIDTH * 0.42)).round.clamp(0, Canvas::WIDTH - 1)
    y = (Canvas::HEIGHT / 2.0 + (Math.cos(t / 13.0) * Canvas::HEIGHT * 0.42)).round.clamp(0, Canvas::HEIGHT - 1)
    color = 4 + (t % (Canvas::PALETTE.length - 4))
    db[:placement].insert(x: x, y: y, color: color, painter_id: AMBIENT_ID, created_at: Time.now)
  end
  db.run("NOTIFY placement_queued")
end

db = DB_CONN
db[:painter].insert_conflict.insert(id: AMBIENT_ID, name: "🤖 ambient-bot", created_at: Time.now) if AMBIENT

# Dedicated raw connection to wake instantly when the web process enqueues work.
listener = PG.connect(DB.url)
listener.exec("LISTEN placement_queued")

warn "worker up: ambient=#{AMBIENT} snapshot_interval=#{SNAPSHOT_INTERVAL}s"

last_snapshot = Time.now
last_ambient = Time.now
ambient_tick_n = 0

loop do
  listener.wait_for_notify(0.2) # returns on NOTIFY or after the timeout
  drain(db)

  now = Time.now
  if AMBIENT && (now - last_ambient) >= AMBIENT_INTERVAL
    last_ambient = now
    ambient_tick(db, ambient_tick_n += 1)
  end
  if (now - last_snapshot) >= SNAPSHOT_INTERVAL
    last_snapshot = now
    build_snapshot(db)
  end
rescue => e
  warn "worker error: #{e.class}: #{e.message}"
  sleep 0.5
end
