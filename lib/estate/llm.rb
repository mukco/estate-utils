# frozen_string_literal: true

require_relative "llm/service"

module Estate
  # The gateway HTTP client — extracted from baseball and football the same
  # way Estate::Cache was: one file, byte-identical except for which app it
  # named itself to the gateway as.
  module Llm
    class << self
      attr_writer :instrumentation

      # Wraps every gateway call, for a timing source that is not this app's
      # own request/job instrumentation — the gateway's mean completion is
      # 14s and some endpoints sit past 20s, which would otherwise read as
      # this app simply being slow.
      #
      # Unset, the call just runs. A missing timer is not a correctness risk
      # the way an unset Estate::Cache.refresh_job is — nothing silently
      # stops working, so this does not warn the way that one does.
      def instrumentation
        @instrumentation || ->(&blk) { blk.call }
      end

      # For specs and for a boot that reconfigures.
      def reset!
        @instrumentation = nil
      end
    end
  end
end
