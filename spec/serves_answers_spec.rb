# frozen_string_literal: true

require "spec_helper"

# The live-kinds list differs per app — football's is longer than baseball's —
# so it has to be genuinely overridable. It was a constant, and a constant is
# resolved lexically inside the module: a controller defining its own would
# never have been consulted, and nothing would have said so. The symptom is a
# 60-second Cache-Control where a 10-second one was meant, on live game data.
RSpec.describe Cache::ServesAnswers do
  let(:controller_class) do
    Class.new do
      include Cache::ServesAnswers
      public :live_kinds
      def self.name = "BaselineController"
    end
  end

  let(:overriding_class) do
    Class.new do
      include Cache::ServesAnswers
      public :live_kinds
      def live_kinds = super + %w[fantasy_insights: team_factoids:]
      def self.name = "FootballController"
    end
  end

  it "defaults to the kinds both apps agree are live" do
    expect(controller_class.new.live_kinds).to eq(%w[game_insights: picks:])
  end

  it "lets an app add its own, and still keeps the shared ones" do
    kinds = overriding_class.new.live_kinds

    expect(kinds).to include("fantasy_insights:", "team_factoids:")
    expect(kinds).to include("game_insights:", "picks:")
  end

  it "does not leak one app's list into another" do
    overriding_class.new.live_kinds

    expect(controller_class.new.live_kinds).to eq(%w[game_insights: picks:])
  end

  # The trap this replaced: a constant redefined in the including class.
  it "ignores a redefined constant, which is why the seam is a method" do
    with_constant = Class.new do
      include Cache::ServesAnswers
      public :live_kinds
      const_set(:LIVE_KINDS, %w[nope:].freeze)
      def self.name = "ConstantController"
    end

    expect(with_constant.new.live_kinds).to eq(%w[game_insights: picks:])
  end
end
