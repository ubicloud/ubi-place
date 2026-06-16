# frozen_string_literal: true

Sequel.migration do
  change do
    # Tiny key/value store for runtime-tunable settings (e.g. the ambient-bot
    # toggle). Admin actions hit the web process; the worker reads the flag from
    # here, so the toggle crosses the process/VM boundary via the shared DB.
    create_table(:setting) do
      String :key, primary_key: true
      String :value
    end
  end
end
