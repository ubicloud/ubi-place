# frozen_string_literal: true

# Canvas geometry + palette. Colors are stored as palette indices (one byte per
# cell) so the whole canvas packs into WIDTH*HEIGHT bytes for the snapshot.
module Canvas
  WIDTH = Integer(ENV.fetch("CANVAS_WIDTH", "100"))
  HEIGHT = Integer(ENV.fetch("CANVAS_HEIGHT", "60"))
  SIZE = WIDTH * HEIGHT

  # Index 0 is the empty/background cell. This list is intentionally easy to
  # edit: adding a swatch here and redeploying is the "visible change" you watch
  # roll out across web replicas during a staggered deploy.
  PALETTE = %w[
    #1a1c2c #5d275d #b13e53 #ef7d57
    #ffcd75 #a7f070 #38b764 #257179
    #29366f #3b5dc9 #41a6f6 #73eff7
    #f4f4f4 #94b0c2 #566c86 #333c57
  ].freeze

  module_function

  def index_for(x, y) = (y * WIDTH) + x
  def in_bounds?(x, y) = x >= 0 && x < WIDTH && y >= 0 && y < HEIGHT
  def valid_color?(c) = c.is_a?(Integer) && c >= 0 && c < PALETTE.length
end
