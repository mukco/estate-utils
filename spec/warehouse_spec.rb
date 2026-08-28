# frozen_string_literal: true

# New. Estate::Cache::Warehouse is the build-stamped path, separated out from the
# TTL path everybody was actually using — so it needs examples of its own,
# there being none to carry over.
RSpec.describe Estate::Cache::Warehouse do
  let(:build) { "100" }

  before { described_class.stamp_provider = -> { build } }

  it "keys an answer on the current build, so a rebuild invalidates it" do
    described_class.write("movers", { rows: [1] })
    expect(described_class.read("movers")).to include(value: { rows: [1] }, fresh: true)

    described_class.stamp_provider = -> { "200" }
    expect(described_class.read("movers")).to include(fresh: false)
  end

  # The reason the versioned key is worth having at all: a rebuild must not
  # leave the request path with nothing, because the alternative is generating,
  # and generating is a hundred seconds.
  it "still hands back the last good answer after a rebuild" do
    described_class.write("movers", { rows: [1] })

    described_class.stamp_provider = -> { "200" }
    expect(described_class.read("movers")[:value]).to eq({ rows: [1] })
  end

  it "regenerates after a rebuild and serves without generating before one" do
    calls = 0
    described_class.resolve("movers", ttl: 1.hour) { calls += 1; { rows: [calls] } }
    described_class.resolve("movers", ttl: 1.hour) { calls += 1; { rows: [calls] } }
    expect(calls).to eq(1)

    described_class.stamp_provider = -> { "200" }
    described_class.resolve("movers", ttl: 1.hour) { calls += 1; { rows: [calls] } }
    expect(calls).to eq(2)
  end

  it "reports whether the current build is already cached, so a warm run can skip it" do
    expect(described_class.current?("movers")).to be(false)
    described_class.write("movers", { rows: [1] })
    expect(described_class.current?("movers")).to be(true)
  end

  it "writes where Answers can read it, under the same stamp" do
    described_class.write("movers", { rows: [1] })

    expect(Estate::Cache::Answers.read("movers", stamp: build)).to include(fresh: true)
  end

  # An unset provider must not silently fall back to something plausible: a
  # constant stamp would mean "the build never changes", which is the one
  # answer this module exists to avoid giving.
  it "refuses to guess a build stamp" do
    described_class.reset!

    expect { described_class.read("movers") }
      .to raise_error(Estate::Cache::NotConfigured, /stamp_provider/)
  end
end
