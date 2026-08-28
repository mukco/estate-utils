# frozen_string_literal: true

# Carried over from baseball's spec/services/warehouse/cached_spec.rb.
#
# Two things changed in the move and both show up here. The stamp defaults to
# BY_TTL now instead of the warehouse build, so the examples that exercised
# version movement say which version they mean rather than stubbing a Manager
# the gem no longer knows about. And there is no Rails: the store is handed in.
RSpec.describe Estate::Cache::Answers do
  let(:build) { "100" }

  it "reads back what it wrote, as fresh" do
    described_class.write("thing", { a: 1 }, stamp: build)

    hit = described_class.read("thing", stamp: build)

    expect(hit).to include(value: { a: 1 }, fresh: true, stamp: "100")
    expect(hit[:generated_at]).to be_present
  end

  # The whole point: a rebuild must not leave the request path with nothing to
  # show, because the thing it would otherwise do is generate, and generating is
  # a hundred seconds.
  it "serves the previous answer as stale once the version has moved on" do
    described_class.write("thing", { a: 1 }, stamp: "100")

    hit = described_class.read("thing", stamp: "200")

    expect(hit).to include(value: { a: 1 }, fresh: false, stamp: "100")
  end

  it "remembers the fingerprint it was written with" do
    described_class.write("thing", { a: 1 }, fingerprint: "abc123")

    expect(described_class.read("thing")[:fingerprint]).to eq("abc123")
  end

  # The saving: re-lease without rebuilding, and do not pretend it is new.
  it "keeps an answer alive without claiming it was just generated" do
    described_class.write("thing", { a: 1 }, fingerprint: "abc123", expires_in: 1.hour)
    built_at = described_class.read("thing")[:generated_at]

    kept = described_class.keep("thing", expires_in: 1.hour)

    expect(kept).to eq({ a: 1 })
    hit = described_class.read("thing")
    expect(hit[:generated_at]).to eq(built_at)
    expect(hit[:fingerprint]).to eq("abc123")
  end

  it "cannot keep what was never built" do
    expect(described_class.keep("never_built", expires_in: 1.hour)).to be_nil
  end

  it "is nil only when nothing has ever been built" do
    expect(described_class.read("never_built")).to be_nil
  end

  it "reports whether the current version is already cached, so a warm run can skip it" do
    expect(described_class.current?("thing", stamp: build)).to be(false)
    described_class.write("thing", { a: 1 }, stamp: build)
    expect(described_class.current?("thing", stamp: build)).to be(true)

    expect(described_class.current?("thing", stamp: "200")).to be(false)
  end

  it "keeps each version under its own key rather than overwriting the last" do
    described_class.write("thing", { a: 1 }, stamp: "100")
    described_class.write("thing", { a: 2 }, stamp: "200")

    expect(described_class.read("thing", stamp: "100")).to include(value: { a: 1 }, fresh: true)
    expect(described_class.read("thing", stamp: "200")).to include(value: { a: 2 }, fresh: true)
  end

  # The change this extraction made. In the apps, `write` and `read` defaulted
  # to the warehouse build stamp and all thirteen callers passed BY_TTL to get
  # out of it. The default is now the thing everybody was doing.
  describe "the default stamp" do
    it "is BY_TTL, so a value is not thrown away by a rebuild nobody asked about" do
      described_class.write("thing", { a: 1 })

      expect(described_class.read("thing")).to include(value: { a: 1 }, fresh: true)
      expect(described_class.read("thing", stamp: described_class::BY_TTL))
        .to include(value: { a: 1 }, fresh: true)
    end

    it "matches what resolve already defaulted to, so the two agree" do
      described_class.resolve("thing", ttl: 1.hour) { { a: 1 } }

      expect(described_class.read("thing")).to include(value: { a: 1 }, fresh: true)
    end
  end

  describe ".resolve" do
    it "returns a current answer without generating" do
      described_class.write("thing", { a: 1 }, stamp: described_class::BY_TTL)

      called = false
      out = described_class.resolve("thing", ttl: 1.hour) { called = true; { a: 2 } }

      expect(out).to eq({ a: 1 })
      expect(called).to be(false)
    end

    it "generates when nothing is cached" do
      out = described_class.resolve("thing", ttl: 1.hour, fingerprint: "fp1") { { a: 1 } }

      expect(out).to eq({ a: 1 })
      expect(described_class.read("thing", stamp: described_class::BY_TTL)[:fingerprint]).to eq("fp1")
    end

    it "re-leases instead of generating when the fingerprint still matches" do
      described_class.resolve("thing", ttl: 1.hour, fingerprint: "fp1") { { a: 1 } }

      called = false
      out = described_class.resolve("thing", ttl: 1.hour, fingerprint: "fp1", refresh: true) do
        called = true
        { a: 2 }
      end

      expect(out).to eq({ a: 1 })
      expect(called).to be(false)
    end

    it "generates when the fingerprint has moved" do
      described_class.resolve("thing", ttl: 1.hour, fingerprint: "fp1") { { a: 1 } }

      out = described_class.resolve("thing", ttl: 1.hour, fingerprint: "fp2", refresh: true) { { a: 2 } }

      expect(out).to eq({ a: 2 })
    end

    # Unknown inputs must never read as unchanged.
    it "generates when the fingerprint cannot be computed" do
      described_class.resolve("thing", ttl: 1.hour, fingerprint: "fp1") { { a: 1 } }

      out = described_class.resolve("thing", ttl: 1.hour, fingerprint: nil, refresh: true) { { a: 2 } }

      expect(out).to eq({ a: 2 })
    end

    it "rebuilds regardless when forced" do
      described_class.resolve("thing", ttl: 1.hour, fingerprint: "fp1") { { a: 1 } }

      out = described_class.resolve("thing", ttl: 1.hour, fingerprint: "fp1", force: true) { { a: 2 } }

      expect(out).to eq({ a: 2 })
    end

    # A failed generation must not become the cached answer.
    it "returns an error without caching it" do
      out = described_class.resolve("thing", ttl: 1.hour, fingerprint: "fp1") { { error: "boom" } }

      expect(out).to eq({ error: "boom" })
      expect(described_class.read("thing", stamp: described_class::BY_TTL)).to be_nil
    end

    # Never. The previous answer is worth more than anything a failed
    # generation has to say.
    it "refuses to replace a good answer with nil" do
      described_class.resolve("thing", ttl: 1.hour, fingerprint: "fp1") { { a: 1 } }

      out = described_class.resolve("thing", ttl: 1.hour, fingerprint: "fp2", refresh: true) { nil }

      expect(out).to be_nil
      expect(described_class.read("thing", stamp: described_class::BY_TTL)[:value]).to eq({ a: 1 })
    end

    it "counts a nil generation as a failure" do
      described_class.resolve("thing", ttl: 1.hour) { nil }

      expect(Estate::Cache::AnswerLog.all["thing"]).to include("failed_count" => 1)
    end

    it "refuses a bare nil write outright" do
      described_class.write("thing", { a: 1 }, stamp: described_class::BY_TTL)
      described_class.write("thing", nil, stamp: described_class::BY_TTL)

      expect(described_class.read("thing", stamp: described_class::BY_TTL)[:value]).to eq({ a: 1 })
    end

    it "refuses an answer its own service will not vouch for" do
      out = described_class.resolve("thing", ttl: 1.hour,
                                    cacheable: ->(v) { v[:rows].any? }) { { rows: [] } }

      expect(out).to eq({ rows: [] })
      expect(described_class.read("thing")).to be_nil
    end

    it "records what it did" do
      described_class.resolve("thing", ttl: 1.hour, fingerprint: "fp1") { { a: 1 } }
      described_class.resolve("thing", ttl: 1.hour, fingerprint: "fp1", refresh: true) { { a: 2 } }

      entry = Estate::Cache::AnswerLog.all["thing"]
      expect(entry).to include("generated_count" => 1, "kept_count" => 1)
    end
  end

  describe ".resolve_detailed" do
    it "says how the answer was arrived at, which is what a Fresh badge renders" do
      first = described_class.resolve_detailed("thing", ttl: 1.hour, fingerprint: "fp1") { { a: 1 } }
      served = described_class.resolve_detailed("thing", ttl: 1.hour, fingerprint: "fp1") { { a: 2 } }
      kept = described_class.resolve_detailed("thing", ttl: 1.hour, fingerprint: "fp1", refresh: true) { { a: 2 } }

      expect(first[:outcome]).to eq(:generated)
      expect(served[:outcome]).to eq(:served)
      expect(kept[:outcome]).to eq(:kept)
    end
  end

  # The gem is not allowed to guess where to write. Silently caching into a
  # void is the failure mode this replaces.
  describe "configuration" do
    it "says so rather than inventing a store when there is neither one set nor a Rails" do
      Estate::Cache.reset!

      expect { described_class.read("thing") }
        .to raise_error(Estate::Cache::NotConfigured, /Estate::Cache.store is unset/)
    end
  end
end
