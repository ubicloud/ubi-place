# frozen_string_literal: true

# Tiny key/value settings store shared between the web and worker processes,
# used for admin toggles (the ambient bot) that one process sets and another reads.
module Settings
  module_function

  def get(db, key)
    db[:setting].where(key: key).get(:value)
  end

  def get_bool(db, key, default)
    v = get(db, key)
    v.nil? ? default : (v == "true")
  end

  def set(db, key, value)
    v = value.to_s
    db[:setting].insert_conflict(target: :key, update: { value: v }).insert(key: key, value: v)
  end

  # Seed a value only if it's missing — preserves any admin override on restart.
  def default!(db, key, value)
    db[:setting].insert_conflict.insert(key: key, value: value.to_s)
  end
end
