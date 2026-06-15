# frozen_string_literal: true

require "sequel"

# Database wiring shared by the web and worker processes.
module DB
  module_function

  # The platform injects DATABASE_URL (as a Secret Store key) when a Postgres is
  # attached. Locally we fall back to a dev database.
  def url
    ENV["DATABASE_URL"] || "postgres:///ubiplace"
  end

  def connect
    Sequel.connect(url, max_connections: Integer(ENV.fetch("DB_POOL", "10")))
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
