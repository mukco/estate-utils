# frozen_string_literal: true

# Carried over from baseball's spec/services/warehouse/answer_log_spec.rb.
# Unchanged except for the constant name and the store being handed in.
RSpec.describe Cache::AnswerLog do
  it "counts each outcome separately" do
    described_class.record("a", outcome: :generated, duration_ms: 900)
    described_class.record("a", outcome: :kept)
    described_class.record("a", outcome: :kept)

    entry = described_class.all["a"]
    expect(entry).to include("generated_count" => 1, "kept_count" => 2, "last_outcome" => "kept")
  end

  # The failure this whole section exists for: a fingerprint that never matches
  # spends a completion every warm run and looks exactly like a healthy cache.
  it "names an answer that is always regenerated and never kept" do
    3.times { described_class.record("churning", outcome: :generated) }
    described_class.record("settled", outcome: :generated)
    described_class.record("settled", outcome: :kept)

    expect(described_class.summary[:never_kept]).to eq(["churning"])
  end

  it "does not accuse an answer generated only once" do
    described_class.record("new_today", outcome: :generated)

    expect(described_class.summary[:never_kept]).to be_empty
  end

  it "surfaces the last error for anything failing" do
    described_class.record("b", outcome: :failed, error: "gateway timeout")

    failing = described_class.summary[:failing]
    expect(failing.first).to include(name: "b", error: "gateway timeout")
  end

  it "totals across answers" do
    described_class.record("a", outcome: :generated)
    described_class.record("b", outcome: :kept)
    described_class.record("c", outcome: :failed, error: "x")

    expect(described_class.summary).to include(answers: 3, generated: 1, kept: 1, failed: 1)
  end

  # Instrumentation must never be the thing that breaks the pipeline.
  it "swallows a broken cache rather than raising into the caller" do
    allow(Cache.store).to receive(:write).and_raise(StandardError, "down")

    expect { described_class.record("a", outcome: :generated) }.not_to raise_error
  end

  it "reads as empty rather than raising when the store cannot be read" do
    allow(Cache.store).to receive(:read).and_raise(StandardError, "down")

    expect(described_class.all).to eq({})
  end
end
