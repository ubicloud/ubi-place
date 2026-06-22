# frozen_string_literal: true

require "time" # Time#iso8601

require_relative "version"

# Minimal shared logging for both the web and worker processes.
#
# One line per event, written to $stdout (NOT stderr — the old `warn` lines went
# to stderr, which is why they were easy to miss; the platform's log collector
# tails stdout by default). Each line is:
#
#   <iso8601> <LEVEL> [<process> <instance>] <message>
#
# so web and worker output interleaves readably and every line is traceable to a
# specific replica via the per-process instance id. LOG_LEVEL (default "info")
# filters out lower levels — set it to "warn" to mute routine activity.
class Log
  LEVELS = { debug: 0, info: 1, warn: 2, error: 3 }.freeze

  def initialize(process, out: $stdout, level: ENV.fetch("LOG_LEVEL", "info"))
    @process = process
    @out = out
    @out.sync = true # flush each line so logs show up live
    @min = LEVELS.fetch(level.downcase.to_sym, LEVELS[:info])
    @mutex = Mutex.new # many SSE threads can log at once; keep lines whole
  end

  LEVELS.each_key do |level|
    define_method(level) { |message| write(level, message) }
  end

  private

  def write(level, message)
    return if LEVELS[level] < @min

    line = "#{Time.now.utc.iso8601(3)} #{level.to_s.upcase} " \
           "[#{@process} #{AppVersion::INSTANCE}] #{message}\n"
    @mutex.synchronize { @out.write(line) }
  end

  # Rack middleware: one line per HTTP request, emitted once the app produces a
  # response. For the SSE stream that's at connect time (the streaming body is
  # consumed by the server afterwards), so you get a line per connection. `dur`
  # is the milliseconds spent producing the response.
  class Middleware
    def initialize(app, log)
      @app = app
      @log = log
    end

    def call(env)
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      status, headers, body = @app.call(env)
      emit(env, status, start)
      [status, headers, body]
    rescue => e
      emit(env, 500, start, e)
      raise
    end

    private

    def emit(env, status, start, error = nil)
      dur = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000).round(1)
      path = env["PATH_INFO"].to_s
      path += "?#{env['QUERY_STRING']}" unless env["QUERY_STRING"].to_s.empty?
      msg = "req #{env['REQUEST_METHOD']} #{path} -> #{status} #{dur}ms"
      error ? @log.error("#{msg} #{error.class}: #{error.message}") : @log.info(msg)
    end
  end
end
