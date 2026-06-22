# frozen_string_literal: true

require_relative "web"

# Log one line per request (LOG is the web process logger, defined in web.rb).
use Log::Middleware, LOG
run Web.freeze.app
