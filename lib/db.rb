# frozen_string_literal: true

require "sequel"
require "pg"

# Database wiring shared by the web and worker processes.
#
# Two connection modes, resolved automatically:
#   * DATABASE_URL set  -> use it (handy for local dev).
#   * otherwise         -> connect straight from libpq env. On Ubicloud the
#     attached Postgres uses MANAGED-IDENTITY cert auth: the deploy step uses the
#     VM's managed identity to fetch a client cert and exposes standard libpq env
#     (PGHOST/PGPORT/PGDATABASE/PGUSER + PGSSLMODE/PGSSLROOTCERT/PGSSLCERT/
#     PGSSLKEY). There is NO password and NO DATABASE_URL — the client cert is the
#     credential — so we let libpq read it all from the environment.
module DB
  module_function

  def url
    u = ENV["DATABASE_URL"]
    (u && !u.empty?) ? u : nil
  end

  # True when the platform (or the developer) has provided libpq connection env.
  def libpq_env?
    %w[PGHOST PGDATABASE PGUSER PGSSLCERT].any? { |k| ENV[k] && !ENV[k].empty? }
  end

  def connect
    opts = { max_connections: Integer(ENV.fetch("DB_POOL", "10")) }
    if (u = url)
      Sequel.connect(u, opts)
    elsif libpq_env?
      Sequel.connect(opts.merge(adapter: "postgres")) # managed-identity cert auth
    else
      Sequel.connect("postgres:///ubiplace", opts)     # bare local-dev default
    end
  end

  # Raw pg connection for LISTEN/NOTIFY, using the same auth resolution.
  def raw_pg
    if (u = url)
      PG.connect(u)
    elsif libpq_env?
      PG.connect
    else
      PG.connect("postgres:///ubiplace")
    end
  end

  # Drop canvas data that no longer fits the current board (e.g. after shrinking
  # WIDTH/HEIGHT). Out-of-bounds pixels must go: the client index is y*WIDTH+x, so
  # a stale (70,10) would collide with a valid cell once the board is 50 wide. Also
  # invalidate a stale-sized snapshot so the worker rebuilds it at the new size.
  def prune_canvas!(db, width, height)
    db[:pixel].where { (x >= width) | (y >= height) }.delete
    db[:placement].where { (x >= width) | (y >= height) }.delete
    snap = db[:snapshot].where(id: 1).first
    db[:snapshot].where(id: 1).delete if snap && snap[:data].to_s.bytesize != width * height
  end

  # Run migrations at boot, guarded by a transaction-scoped advisory lock. This
  # platform has no "release" phase, and several web/worker replicas boot at once
  # (and on every deploy) — the lock makes exactly one of them migrate while the
  # rest wait, then they all find the schema already current. The xact lock is
  # released automatically when the transaction commits.
  def migrate!(db)
    Sequel.extension :migration
    dir = File.expand_path("../db/migrate", __dir__)
    db.transaction do
      db.run("SELECT pg_advisory_xact_lock(4242)")
      Sequel::Migrator.run(db, dir, use_transactions: false)
    end
  end
end
