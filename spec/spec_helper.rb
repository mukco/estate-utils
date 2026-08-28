# frozen_string_literal: true

require "active_support"
require "active_support/cache"
require "active_support/core_ext/numeric/time"

require "cache"

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.disable_monkey_patching!
  config.order = :random

  # No Rails here at all. Every example gets its own store, which is both a
  # clean slate and the standing proof that the gem does not reach for
  # Rails.cache when it has been handed one.
  config.before do
    Cache.reset!
    Cache::Warehouse.reset!
    Cache.store = ActiveSupport::Cache::MemoryStore.new
  end
end
