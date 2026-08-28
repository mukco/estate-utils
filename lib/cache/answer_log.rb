# frozen_string_literal: true

module Cache
  # What the answer cache actually did, kept where a human can look at it.
  #
  # The failure this exists for has no other symptom: a fingerprint that never
  # matches spends a completion on every warm run and looks, from the outside,
  # exactly like a healthy cache. Same pages, same answers, same latency — just
  # a bill. `never_kept` is the line that names it.
  module AnswerLog
    KEY = "cache:answer_log"
    TTL = 7.days
    MAX_ANSWERS = 200

    module_function

    def record(name, outcome:, duration_ms: nil, fingerprint: nil, error: nil)
      entries = all
      entry = entries[name.to_s] ||= blank_entry
      entry["#{outcome}_count"] = entry["#{outcome}_count"].to_i + 1
      entry["last_outcome"]     = outcome.to_s
      entry["last_at"]          = Time.current.iso8601
      entry["fingerprint"]      = fingerprint if fingerprint
      entry["last_duration_ms"] = duration_ms if duration_ms
      if outcome == :failed
        entry["last_error"]    = error.to_s[0, 300]
        entry["last_error_at"] = Time.current.iso8601
      end

      write(entries)
      entry
    rescue StandardError => e
      # Instrumentation must never be the thing that breaks the pipeline.
      Cache.logger.warn("Cache::AnswerLog: #{e.class}: #{e.message}")
      nil
    end

    def all
      Cache.store.read(KEY) || {}
    rescue StandardError
      {}
    end

    def clear!
      Cache.store.delete(KEY)
    end

    # Shaped for a human reading a dashboard, not for a machine: the question is
    # "is anything not being generated, and is anything being generated that
    # should not be".
    def summary
      entries = all
      {
        answers: entries.size,
        generated: entries.sum { |_, e| e["generated_count"].to_i },
        kept: entries.sum { |_, e| e["kept_count"].to_i },
        failed: entries.sum { |_, e| e["failed_count"].to_i },
        # A fingerprint that never matches is invisible except here.
        never_kept: entries.select { |_, e| e["generated_count"].to_i > 1 && e["kept_count"].to_i.zero? }.keys.sort,
        failing: entries.select { |_, e| e["last_outcome"] == "failed" }
                        .map { |name, e| { name: name, error: e["last_error"], at: e["last_error_at"] } },
        entries: entries
      }
    end

    def blank_entry
      { "generated_count" => 0, "kept_count" => 0, "served_count" => 0, "failed_count" => 0 }
    end

    def write(entries)
      # Oldest-touched go first if this ever grows past the cap.
      if entries.size > MAX_ANSWERS
        entries = entries.sort_by { |_, e| e["last_at"].to_s }.last(MAX_ANSWERS).to_h
      end

      Cache.store.write(KEY, entries, expires_in: TTL)
    end
  end
end
