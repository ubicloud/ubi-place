# frozen_string_literal: true

require "pg"

# Per-process pub/sub bridge over Postgres LISTEN/NOTIFY.
#
# One background thread holds a dedicated connection LISTENing on a channel and,
# whenever the worker NOTIFYs (e.g. after applying a batch of pixels), wakes every
# subscribed SSE client in *this* web process. Each web replica runs its own
# Notifier, and they all LISTEN on the same channel, so a single NOTIFY fans out
# across every replica. Subscribers also get a periodic tick from their own 1s
# queue timeout, which both drives heartbeats and covers any missed notification.
class Notifier
  def initialize(channel, logger: nil, &connect)
    @channel = channel
    @connect = connect # () -> a raw PG connection
    @log = logger
    @subs = []
    @mutex = Mutex.new
  end

  def subscribe
    Queue.new.tap { |q| @mutex.synchronize { @subs << q } }
  end

  def unsubscribe(queue)
    @mutex.synchronize { @subs.delete(queue) }
  end

  # Number of connected clients on this instance (shown as "online").
  def size
    @mutex.synchronize { @subs.size }
  end

  def start
    @thread ||= Thread.new { run }
    self
  end

  private

  def run
    conn = nil
    loop do
      conn = @connect.call
      conn.exec("LISTEN #{@channel}")
      @log&.info("notifier listening channel=#{@channel}")
      loop { conn.wait_for_notify(30) { broadcast } }
    rescue => e
      msg = "notifier(#{@channel}) #{e.class}: #{e.message}; reconnecting in 1s"
      @log ? @log.warn(msg) : warn(msg)
      begin
        conn&.close
      rescue
        nil
      end
      sleep 1
    end
  end

  def broadcast
    @mutex.synchronize { @subs.each { |q| q.push(true) } }
  end
end
