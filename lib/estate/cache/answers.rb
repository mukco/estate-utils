# frozen_string_literal: true

module Estate
  module Cache
    # Caching for answers that cost real money or real seconds to produce.
    #
    # It was called Warehouse::Cached, in two apps, identically. The name was
    # wrong by the time it was written: of the thirteen services using it in
    # baseball, exactly one is caching warehouse data, and even that one holds
    # its value against a TTL rather than a build. The rest are caching model
    # completions. So it is Answers now, and the build-stamped variant it was
    # named after lives next door in Estate::Cache::Warehouse, where the one caller who
    # ever wants it can find it.
    #
    # Two problems this solves together, which a TTL cannot solve at all.
    #
    # A TTL is a guess about freshness, and the guess costs whoever asks next: a
    # 30-minute clock over a warehouse rebuilt every 6 hours recomputes the same
    # answer twelve times, and eleven of those are a slow page load for somebody.
    # Keying on a build stamp instead takes freshness off that dial: a rebuild
    # changes the key, so the value can be kept for hours and still never be
    # stale.
    #
    # The second problem is what a miss costs. Cache-miss-means-generate is fine
    # when generating is cheap; ottoneu_free_agents takes 102 seconds, so a miss
    # is somebody's browser hanging. Every write therefore also lands under a
    # stable key that no version change invalidates. A reader that misses the
    # current version gets the last good answer immediately, marked stale, and the
    # refresh happens in a job. Nobody waits for a generation on the request path.
    module Answers
      # For values whose freshness a warehouse build does NOT describe — which,
      # empirically, is all of them.
      #
      # A build stamp is the mtime of the warehouse file, and a rebuild rewrites
      # that whole file — so baseball's 30-minute injuries scrape moves the stamp
      # every 30 minutes. That is the right signal for something reading the
      # injuries table and quite wrong for a roster-value factoid, which would be
      # thrown away twice an hour and rebuilt at 102 seconds a time for a scrape
      # it never read.
      #
      # It is the default here, which it was not in the apps. There, `write` and
      # `read` defaulted to the warehouse build stamp and every single caller
      # overrode it — thirteen services passing `stamp: BY_TTL` to opt out of a
      # default none of them wanted, and dragging Warehouse::Manager into the
      # signature of a module that has nothing to do with a warehouse. The two
      # callers that genuinely track a build pass it as a *fingerprint*, which is
      # a different argument. So: the default is the thing everyone does, and the
      # stamped path is asked for by name.
      BY_TTL = "ttl"

      module_function

      # The whole pipeline in one place, because fifteen services doing this by
      # hand is fifteen chances to get one of the branches subtly wrong — and the
      # wrong branch here is silent, not loud.
      #
      #   resolve("ottoneu_insights", ttl: 1.hour, fingerprint: print) { generate }
      #
      # In order:
      #   a current answer is returned as-is
      #   an answer whose fingerprint still matches is re-leased, not rebuilt
      #   anything else is generated, and only a non-error result is written
      #
      # refresh re-evaluates (the fingerprint may still short-circuit it); force
      # rebuilds regardless, which is what a human pressing refresh means. A nil
      # fingerprint always rebuilds: unknown inputs must never read as unchanged.
      def resolve(name, ttl:, fingerprint: nil, stamp: BY_TTL, refresh: false, force: false, cacheable: nil, &block)
        resolve_detailed(name, ttl: ttl, fingerprint: fingerprint, stamp: stamp,
                         refresh: refresh, force: force, cacheable: cacheable, &block)[:value]
      end

      # The same, for callers that need to say how the answer was arrived at —
      # the game pages render a Cached/Fresh badge from it.
      # cacheable: an optional predicate for answers where "not nil and not an
      # error" is too weak a test. The auctions panel learned this the hard way —
      # a transient scrape failure returns a well-formed, empty payload, and
      # caching that froze the panel as "empty" for the full TTL. A service that
      # knows what a real answer looks like says so here.
      def resolve_detailed(name, ttl:, fingerprint: nil, stamp: BY_TTL, refresh: false, force: false, cacheable: nil)
        hit = read(name, stamp: stamp)

        if !refresh && !force && hit && hit[:fresh]
          AnswerLog.record(name, outcome: :served)
          return { value: hit[:value], outcome: :served }
        end

        if !force && fingerprint.present? && hit && hit[:fingerprint] == fingerprint
          kept = keep(name, expires_in: ttl, stamp: stamp)
          if kept
            AnswerLog.record(name, outcome: :kept, fingerprint: fingerprint)
            return { value: kept, outcome: :kept }
          end
        end

        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        value   = yield
        elapsed = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round

        # A generator that returns nothing has failed, whatever it thinks. It is
        # reported as a failure and not written, so the previous answer stays put
        # and .read keeps serving it. The error is still returned rather than
        # swallowed — the warm job counts these, and an outage that reports itself
        # as success is worse than the outage.
        if value.nil?
          AnswerLog.record(name, outcome: :failed, duration_ms: elapsed, error: "generator returned nil")
          return { value: value, outcome: :failed }
        end

        if value.is_a?(Hash) && value[:error]
          AnswerLog.record(name, outcome: :failed, duration_ms: elapsed, error: value[:error])
          return { value: value, outcome: :failed }
        end

        if cacheable && !cacheable.call(value)
          AnswerLog.record(name, outcome: :failed, duration_ms: elapsed, error: "generated an answer its own service will not cache")
          return { value: value, outcome: :failed }
        end

        AnswerLog.record(name, outcome: :generated, duration_ms: elapsed, fingerprint: fingerprint)
        write(name, value, expires_in: ttl, stamp: stamp, fingerprint: fingerprint)
        { value: value, outcome: :generated }
      end

      # Written by the warm jobs. Stores under the versioned key and, separately,
      # as the last known good answer.
      def write(name, value, expires_in: 12.hours, stamp: BY_TTL, fingerprint: nil, generated_at: nil)
        # Never cache nothing. A nil here replaces a good answer — including the
        # last-good copy that exists precisely to survive a bad generation — with
        # nothing at all, and the next reader gets a 202 for an answer we still
        # had a moment ago. Guarded at the primitive so no caller can do it,
        # rather than at each of the callers.
        if value.nil?
          Estate::Cache.logger.warn("Estate::Cache::Answers: refused to write nil for #{name}")
          return nil
        end

        # Both copies carry when they were built, so a reader can always say how
        # old the answer is — not only when it has fallen back to the last good
        # one. The services also stamp a generated_at inside their own payload;
        # this is the one the cache itself vouches for, and the one that stays
        # true when a value is served from a build ago.
        #
        # generated_at is passed in only by #keep, which re-stamps an answer it did
        # not rebuild: saying "generated now" about a model's work from an hour ago
        # would be the one lie this envelope exists to prevent.
        envelope = { value: value, stamp: stamp, at: generated_at || Time.current.iso8601, fingerprint: fingerprint }
        Estate::Cache.store.write(versioned_key(name, stamp), envelope, expires_in: expires_in)
        # Deliberately outlives the versioned copy: its whole job is to still be
        # there when the version has moved on and the new one is not built yet.
        Estate::Cache.store.write(last_good_key(name), envelope, expires_in: 7.days)
        value
      end

      # Read for the request path. Never generates.
      #
      #   { value:, fresh: true }   current for this version
      #   { value:, fresh: false }  the last good answer; a refresh is worth queueing
      #   nil                       nothing has ever been built
      def read(name, stamp: BY_TTL)
        current = Estate::Cache.store.read(versioned_key(name, stamp))
        return envelope_to_hit(current, fresh: true) if current.present?

        previous = Estate::Cache.store.read(last_good_key(name))
        return nil if previous.blank?

        envelope_to_hit(previous, fresh: false)
      end

      def envelope_to_hit(envelope, fresh:)
        { value: envelope[:value], fresh: fresh, stamp: envelope[:stamp],
          generated_at: envelope[:at], fingerprint: envelope[:fingerprint] }
      end

      # Give the cached answer a fresh lease without rebuilding it. For anything
      # backed by a model this is the whole saving: the warm job runs every 25
      # minutes and an Ottoneu roster changes on transactions, so most runs are
      # asking a model to say again what it said an hour ago. A caller that can
      # show its inputs have not moved calls this instead.
      #
      # Deliberately keeps the original generated_at: the answer is as old as it
      # is, and the UI says so.
      def keep(name, expires_in:, stamp: BY_TTL)
        hit = read(name, stamp: stamp)
        return nil if hit.nil?

        write(name, hit[:value], expires_in: expires_in, stamp: stamp,
              fingerprint: hit[:fingerprint], generated_at: hit[:generated_at])
        hit[:value]
      end

      # Used by the warm jobs to skip work that is already current. Without it a
      # job that runs more often than the version moves spends its time
      # regenerating an answer nothing has invalidated.
      def current?(name, stamp: BY_TTL)
        Estate::Cache.store.exist?(versioned_key(name, stamp))
      end

      def versioned_key(name, stamp = BY_TTL)
        "#{name}:v#{stamp}"
      end

      def last_good_key(name)
        "#{name}:last_good"
      end
    end
  end
end
