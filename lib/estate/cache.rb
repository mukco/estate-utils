# frozen_string_literal: true

require "logger"

require "active_support"
require "active_support/core_ext/object/blank"
require "active_support/core_ext/integer/time"
require "active_support/core_ext/numeric/time"

require_relative "cache/version"
require_relative "cache/answer_log"
require_relative "cache/answers"
require_relative "cache/warehouse"
require_relative "cache/serves_answers"

# Caching for answers that are expensive to produce — a model completion, a
# scrape, a warehouse query — extracted from baseball and football, where the
# same file lived twice and was byte-identical once the comments were stripped.
#
# What it is not: a general-purpose cache. Rails has one of those and this is
# built on it. This is the part that sits above it — the decision about whether
# an answer needs producing again at all.
#
# Everything the gem needs from an application is set here, and there are only
# three things. Two of them read through to Rails when Rails is present, so a
# Rails app configures nothing at all unless it wants the third.
module Estate
  module Cache
    # Raised when something the gem cannot guess has not been set. Loud on
    # purpose: the alternative is caching into a void and never knowing.
    class NotConfigured < StandardError; end

    class << self
      attr_writer :store, :logger, :refresh_job

      # The backing store. Rails.cache when there is a Rails, and read through
      # rather than memoised — apps and specs swap Rails.cache under us, and a
      # cached reference here would quietly keep writing to the old store.
      def store
        @store || rails_cache ||
          raise(NotConfigured, "Estate::Cache.store is unset and there is no Rails.cache to fall back to")
      end

      def logger
        @logger || (defined?(::Rails) && ::Rails.logger) || Logger.new(IO::NULL)
      end

      # Who rebuilds an answer that a request path found missing or stale.
      #
      # This is the one thing the gem genuinely cannot supply. The apps enqueue a
      # job — RefreshCachedInsightJob, in both of them — and that job knows a
      # whitelist of rebuildable answer names, which is app knowledge and also a
      # security boundary: the name arrives from a controller and must never be
      # a class name off the wire.
      #
      # Unset, it warns rather than raising or going quiet. Raising would turn a
      # missed configuration into a 500 on a page that could still have served
      # the last good answer; silence would mean an app whose answers simply
      # never refresh, which is exactly the kind of failure that hides for weeks.
      def refresh_job
        @refresh_job || NullRefreshJob
      end

      # For specs and for a boot that reconfigures.
      def reset!
        @store = @logger = @refresh_job = nil
      end

      private

      def rails_cache
        return nil unless defined?(::Rails) && ::Rails.respond_to?(:cache)

        ::Rails.cache
      end
    end

    # Says what it is not doing, every time, in the app's own log.
    module NullRefreshJob
      def self.enqueue_once(kind, priority: nil)
        Estate::Cache.logger.warn(
          "Estate::Cache.refresh_job is unset: nothing will rebuild #{kind.inspect}. " \
          "Set it to the job class that owns your rebuild whitelist."
        )
        false
      end
    end
  end
end
