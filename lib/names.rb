# frozen_string_literal: true

# Friendly auto-generated painter names (no login required).
module Names
  ADJ = %w[swift brave tiny cosmic neon mellow funky cobalt amber jade
    crimson lunar plucky zesty turbo dapper sleepy snappy giddy bold].freeze
  ANIMAL = %w[penguin otter fox panda koala gecko narwhal yak lemur tapir
    mantis quokka axolotl ferret heron bison marmot puffin walrus dingo].freeze
  EMOJI = %w[🐧 🦊 🐼 🦎 🐙 🦉 🐢 🦄 🐝 🦕 🐳 🦦 🦔 🐌 🦩 🐡].freeze

  module_function

  def random
    "#{EMOJI.sample} #{ADJ.sample}-#{ANIMAL.sample}"
  end
end
