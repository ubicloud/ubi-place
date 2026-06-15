# frozen_string_literal: true

require "securerandom"

# Identity of *this running process* — the heart of the zero-downtime demo.
module AppVersion
  # A fresh id every process start. When the platform swaps a web replica during
  # a staggered deploy, the instance behind your request changes — and so does
  # this value. That's the visible proof the swap happened with no downtime.
  INSTANCE = SecureRandom.hex(3)

  BOOT_AT = Time.now

  # Release label. Edit the VERSION file (and commit) between deploys so you can
  # watch v1 -> v2 flip across replicas live. Falls back to APP_VERSION or "dev".
  VERSION = begin
    path = File.expand_path("../VERSION", __dir__)
    file = File.exist?(path) ? File.read(path).strip : ""
    file.empty? ? (ENV["APP_VERSION"] || "dev") : file
  end
end
