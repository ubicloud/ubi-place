# frozen_string_literal: true

Sequel.migration do
  up do
    # Monotonic version counter for the canvas. Every applied pixel gets the next
    # value, so a client can ask for "everything since cursor N" to catch up.
    run "CREATE SEQUENCE IF NOT EXISTS canvas_seq"

    create_table(:painter) do
      String :id, primary_key: true # random id from a cookie; no real login
      String :name, null: false
      Integer :pixel_count, null: false, default: 0
      Time :last_placed_at # cooldown gate
      Time :created_at, null: false, default: Sequel::CURRENT_TIMESTAMP
    end

    create_table(:pixel) do
      Integer :x, null: false
      Integer :y, null: false
      Integer :color, null: false # palette index
      Bignum :seq, null: false
      String :painter_id
      primary_key [:x, :y]
      index :seq
    end

    # Incoming placements land here first (fast web path); the worker drains them
    # into `pixel`. This is what makes the worker genuinely load-bearing and lets
    # the queue visibly rise then drain after a worker redeploy.
    create_table(:placement) do
      primary_key :id
      Integer :x, null: false
      Integer :y, null: false
      Integer :color, null: false
      String :painter_id
      Time :created_at, null: false, default: Sequel::CURRENT_TIMESTAMP
      Time :processed_at
      index :processed_at
    end

    # Single-row packed snapshot (one byte per cell) for O(1) initial page loads.
    create_table(:snapshot) do
      Integer :id, primary_key: true # always 1
      Bignum :seq, null: false, default: 0
      File :data # bytea, length WIDTH*HEIGHT
      Time :created_at, null: false, default: Sequel::CURRENT_TIMESTAMP
    end
  end

  down do
    drop_table(:snapshot, :placement, :pixel, :painter)
    run "DROP SEQUENCE IF EXISTS canvas_seq"
  end
end
