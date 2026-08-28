# frozen_string_literal: true

module Estate
  module Cache
    # Answers held against a data build rather than a clock.
    #
    # This is the mechanism Warehouse::Cached was named for, separated out from
    # the mechanism everybody was actually using. A build stamp goes into the
    # cache key, so a rebuild changes the key and the old answer stops being
    # current the moment its inputs do — no TTL guessing, and the value can be
    # held for hours without ever being stale. The last-good copy still outlives
    # it, so a rebuild does not leave the request path with nothing to show.
    #
    # Worth being honest about who uses it: right now, in either app, nobody.
    # Both apps' warehouse-aware services pass their build stamp as a
    # *fingerprint* and cache against a TTL — that is, they re-lease an existing
    # answer when the build has not moved rather than key on the build directly.
    # The stamped path is kept because it is a real and better answer for a value
    # that is pure derivation of the warehouse, and because "the versioned key"
    # is what the last-good machinery in Answers is built around. It is here,
    # named, and asked for explicitly — rather than being the default that
    # thirteen callers had to opt out of one by one.
    module Warehouse
      class << self
        # How the app names its current data build. Baseball and football both
        # use the mtime of the warehouse file; anything stable and cheap works,
        # as long as it changes when the data does.
        #
        #   Estate::Cache::Warehouse.stamp_provider = -> { ::Warehouse::Manager.build_stamp }
        attr_writer :stamp_provider

        def stamp_provider
          @stamp_provider ||
            raise(NotConfigured,
                  "Estate::Cache::Warehouse needs a stamp_provider — set it to a callable " \
                  "returning the current build stamp, e.g. -> { Warehouse::Manager.build_stamp }")
        end

        def configured? = !@stamp_provider.nil?

        def stamp = stamp_provider.call.to_s

        def reset! = @stamp_provider = nil

        # Answers, with the stamp filled in. Same arguments otherwise, minus the
        # one you would only ever pass the same value to.
        def resolve(name, ttl:, fingerprint: nil, refresh: false, force: false, cacheable: nil, &block)
          Answers.resolve(name, ttl: ttl, fingerprint: fingerprint, stamp: stamp,
                          refresh: refresh, force: force, cacheable: cacheable, &block)
        end

        def resolve_detailed(name, ttl:, fingerprint: nil, refresh: false, force: false, cacheable: nil, &block)
          Answers.resolve_detailed(name, ttl: ttl, fingerprint: fingerprint, stamp: stamp,
                                   refresh: refresh, force: force, cacheable: cacheable, &block)
        end

        def read(name) = Answers.read(name, stamp: stamp)

        def write(name, value, expires_in: 12.hours, fingerprint: nil, generated_at: nil)
          Answers.write(name, value, expires_in: expires_in, stamp: stamp,
                        fingerprint: fingerprint, generated_at: generated_at)
        end

        def keep(name, expires_in:) = Answers.keep(name, expires_in: expires_in, stamp: stamp)

        def current?(name) = Answers.current?(name, stamp: stamp)
      end
    end
  end
end
