# frozen_string_literal: true

require "active_support/concern"

module Estate
  module Cache
    # Reading a cached answer on the request path, which is the only thing a
    # request path may do with one.
    #
    # A completion in baseball takes 58-124 seconds and rack-timeout ends a
    # request at 30, so an endpoint that generates cannot succeed — it can only
    # fail slowly, holding a Puma thread the whole way and surfacing as a
    # Net::ReadTimeout the gateway never caused. Every LLM-backed endpoint
    # therefore reads what a runner already built and says so when there is
    # nothing yet:
    #
    #   a current answer          200, cache.fresh
    #   the last good answer      200, cache.stale — a rebuild is queued
    #   nothing ever built        202 pending — a rebuild is queued, poll
    #
    # This is also what makes a completion timeout a single number. There is one
    # budget because, once nothing generates in a request, there is only one kind
    # of caller left to have a budget for.
    #
    # It lived in two controllers before it was a concern, and had already
    # drifted: the games one grew a `cached` flag for its badge and the Ottoneu
    # one never did. The union is kept — an extra key costs a client nothing, a
    # missing one costs it a broken badge.
    module ServesAnswers
      extend ActiveSupport::Concern

      # How long the browser and the edge may hold each kind of answer.
      #
      # A live game must not sit behind a 60-second edge cache: baseball's 825039
      # served a header saying Final 0-2 over a body still showing 1-0 in the
      # bottom of the 8th, because the two came from different cache generations.
      # Ten seconds for anything per-game, a minute for the standing summaries.
      LIVE_CACHE_CONTROL   = "public, max-age=10, stale-while-revalidate=60"
      STABLE_CACHE_CONTROL = "public, max-age=60, stale-while-revalidate=600"

      # Which `kind` prefixes count as live.
      #
      # Override the METHOD, not the constant. Ruby resolves a constant lexically,
      # so `LIVE_KINDS` inside this module always means this module's — a
      # controller that defines its own is never consulted, and the difference is
      # silent: the wrong Cache-Control, no error. Football's list is genuinely
      # longer than baseball's, so this had to be overridable to be correct.
      #
      #   def live_kinds = super + %w[fantasy_insights: team_factoids:]
      LIVE_KINDS = %w[game_insights: picks:].freeze

      # Overridable per app. See LIVE_KINDS.
      def live_kinds = LIVE_KINDS

      private

      # hit:  a Estate::Cache::Answers.read result, or nil.
      # kind: the entry in Estate::Cache.refresh_job's whitelist that rebuilds this. Not
      #       a class name off the wire — see that job.
      # live: override the prefix test when a caller knows better.
      def serve_cached(hit, kind:, refresh:, live: nil)
        # A stale answer queues its own replacement, so the first visitor after a
        # rebuild pays nothing and the next one has the new answer. enqueue_once
        # holds a lock, so a page everyone opens at once queues one rebuild
        # rather than one per visitor.
        Estate::Cache.refresh_job.enqueue_once(kind) if refresh || hit.nil? || !hit[:fresh]

        if hit.nil?
          response.headers["Cache-Control"] = LIVE_CACHE_CONTROL
          return render json: { pending: true, cached: false,
                                cache: { fresh: false, stale: false, generated_at: nil } },
                        status: :accepted
        end

        live = kind.to_s.start_with?(*live_kinds) if live.nil?
        response.headers["Cache-Control"] = live ? LIVE_CACHE_CONTROL : STABLE_CACHE_CONTROL

        # Only a generation reads as fresh: a re-leased answer is the same words
        # as before, and the badge would be lying if it said otherwise.
        meta = { fresh: hit[:fresh], stale: !hit[:fresh], generated_at: hit[:generated_at] }
        body = hit[:value].is_a?(Hash) ? hit[:value] : { value: hit[:value] }
        render json: body.merge(cached: !hit[:fresh], cache: meta)
      end
    end
  end
end
