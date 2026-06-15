# Puma config for the `web` process.
#
# The app-service deploy script publishes the container's port 8080 to the
# per-app load balancer, so we bind there by default (PORT is honored if the
# buildpack happens to set it). We run a SINGLE process with many threads:
# every SSE client holds a thread for its lifetime, and the in-process
# LISTEN/NOTIFY fan-out (lib/notifier.rb) lives in this one process. Horizontal
# scale comes from the platform's *web replica count*, not from Puma workers.

port Integer(ENV.fetch("PORT", 8080))
threads Integer(ENV.fetch("PUMA_MIN_THREADS", 8)), Integer(ENV.fetch("PUMA_MAX_THREADS", 64))
workers Integer(ENV.fetch("WEB_CONCURRENCY", 0))
environment ENV.fetch("RACK_ENV", "production")
rackup "config.ru"
