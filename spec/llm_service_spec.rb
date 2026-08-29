# frozen_string_literal: true

require "spec_helper"

RSpec.describe Estate::Llm::Service do
  let(:answer) { { "verdict" => "yes" } }

  around do |example|
    original = ENV["LLM_CLIENT_ID"]
    ENV["LLM_CLIENT_ID"] = "estate-test"
    example.run
    ENV["LLM_CLIENT_ID"] = original
  end

  # Capture the body that would go over the wire, without one.
  def captured_body
    request = double("request", headers: {}) # rubocop:disable RSpec/VerifiedDoubles
    body = nil
    allow(request).to receive(:body=) { |value| body = value }
    connection = double("connection") # rubocop:disable RSpec/VerifiedDoubles
    allow(connection).to receive(:post) do |_path, &block|
      block.call(request)
      double("response", body: JSON.generate(choices: [ { message: { content: JSON.generate(answer) } } ])) # rubocop:disable RSpec/VerifiedDoubles
    end
    allow(described_class).to receive(:connection).and_return(connection)

    yield
    JSON.parse(body)
  end

  it "asks for a JSON object so callers never have to scrape prose" do
    body = captured_body do
      described_class.json_completion(system_prompt: "s", user_payload: {}, interaction_type: "t")
    end

    expect(body["response_format"]).to eq("type" => "json_object")
  end

  # OpenAI rejects json_object mode outright when the word is missing from the
  # messages, and a prompt describing its shape without ever using the word is
  # the common case — every structured call 400'd the moment it stopped
  # bypassing the gateway.
  it "says the word `json`, which json_object mode requires" do
    body = captured_body do
      described_class.json_completion(system_prompt: "describe the shape", user_payload: {}, interaction_type: "t")
    end

    expect(body["messages"].first["content"].downcase).to include("json")
  end

  it "keeps the caller's own prompt" do
    body = captured_body do
      described_class.json_completion(system_prompt: "be helpful", user_payload: {}, interaction_type: "t")
    end

    expect(body["messages"].first["content"]).to start_with("be helpful")
  end

  # The gateway decides which model each app gets; naming one here would put
  # that decision in a deploy instead of a config file.
  it "asks for `auto` rather than naming a model" do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("LLM_MODEL").and_return(nil)

    body = captured_body do
      described_class.json_completion(system_prompt: "s", user_payload: {}, interaction_type: "t")
    end

    expect(body["model"]).to eq("auto")
  end

  # The headers that would go over the wire, without one. Same shape as
  # captured_body above, kept separate because that one throws the headers away
  # and this one is entirely about them.
  def captured_headers
    request = double("request", headers: {}) # rubocop:disable RSpec/VerifiedDoubles
    allow(request).to receive(:body=)
    connection = double("connection") # rubocop:disable RSpec/VerifiedDoubles
    allow(connection).to receive(:post) do |_path, &block|
      block.call(request)
      double("response", body: JSON.generate(choices: [ { message: { content: JSON.generate(answer) } } ])) # rubocop:disable RSpec/VerifiedDoubles
    end
    allow(described_class).to receive(:connection).and_return(connection)

    yield
    request.headers
  end

  describe "telling the gateway which call this is" do
    # X-Client-Id is the bill, the cap and the off switch; X-Client-Call is only
    # which model answers. One app stays one consumer. The client id comes from
    # ENV — the one thing that still varies per app now that this file is
    # shared — set by the `around` block above.
    it "names the app and the call" do
      headers = captured_headers do
        described_class.json_completion(system_prompt: "s", user_payload: {}, interaction_type: "daily_summary_sql")
      end

      expect(headers["X-Client-Id"]).to eq("estate-test")
      expect(headers["X-Client-Call"]).to eq("daily_summary_sql")
    end

    # The assistant is one kind of work and had no name of its own, so it was
    # given one — a call name, not a model.
    it "names the assistant's chat too" do
      headers = captured_headers { described_class.chat(messages: [ { role: "user", content: "hi" } ]) }

      expect(headers["X-Client-Call"]).to eq("assistant")
    end

    it "sends no call header when the caller did not name one" do
      headers = captured_headers do
        described_class.json_completion(system_prompt: "s", user_payload: {}, interaction_type: nil)
      end

      expect(headers["X-Client-Call"]).to be_nil
      expect(headers["X-Client-Id"]).to eq("estate-test")
    end

    # Nothing here may name a model. Changing one is a row in the gateway, not
    # a deploy, and a constant here would quietly end that.
    it "still asks for auto, never for a model by name" do
      body = captured_body do
        described_class.json_completion(system_prompt: "s", user_payload: {}, interaction_type: "t")
      end

      expect(body["model"]).to eq("auto")
    end
  end

  describe "timeouts" do
    def stubbed_connection
      connection = double("connection") # rubocop:disable RSpec/VerifiedDoubles
      allow(connection).to receive(:post).and_return(
        double("response", body: JSON.generate(choices: [ { message: { content: JSON.generate(answer) } } ])) # rubocop:disable RSpec/VerifiedDoubles
      )
      connection
    end

    it "gives every completion the one completion budget" do
      connection = stubbed_connection
      expect(described_class).to receive(:connection)
        .with(timeout: described_class::COMPLETION_TIMEOUT).and_return(connection)

      described_class.json_completion(system_prompt: "s", user_payload: {}, interaction_type: "t")
    end

    it "gives the assistant's chat the same one" do
      connection = stubbed_connection
      allow(connection).to receive(:post).and_return(
        double("response", body: JSON.generate(choices: [])) # rubocop:disable RSpec/VerifiedDoubles
      )
      expect(described_class).to receive(:connection)
        .with(timeout: described_class::COMPLETION_TIMEOUT).and_return(connection)

      described_class.chat(messages: [ { role: "user", content: "hi" } ])
    end

    # The parameter does not exist, not merely unused. Two apps used to let
    # callers pass it, every one of them to ask for less time than the work
    # needs, and one of them took production down over it. There is no way to
    # ask for a different budget because the budget is a property of the
    # operation, not a guess at each call site.
    it "gives a caller no way to ask for a different budget" do
      expect {
        described_class.json_completion(system_prompt: "s", user_payload: {}, interaction_type: "t", timeout: 90)
      }.to raise_error(ArgumentError, /unknown keyword: :timeout/)
    end

    # #connection had `timeout: nil` and defaulted to 180, which read as the
    # policy while json_completion silently overrode it with a smaller number
    # on every call. Two numbers where one was decorative, and no call site
    # showed which won.
    it "makes every caller of #connection name its own budget" do
      expect { described_class.connection }.to raise_error(ArgumentError, /missing keyword: :timeout/)
    end

    # A completion that timed out did not fail to start, it failed to finish.
    # Retrying it starts the whole thing over: 3x the wall clock on a call that
    # was already over budget, and 3x the provider bill for work then discarded.
    # mukco/gateway deliberately does not retry, naming the app on the other
    # side as the retrier.
    it "retries a gateway that is not there, and never one that is merely slow" do
      retry_options = nil
      builder = double("builder", options: double("options").as_null_object) # rubocop:disable RSpec/VerifiedDoubles
      allow(builder).to receive(:use)
      allow(builder).to receive(:response)
      allow(builder).to receive(:request) { |_mw, opts| retry_options = opts }
      allow(Faraday).to receive(:new).and_yield(builder)

      described_class.connection(timeout: 1)

      expect(retry_options[:exceptions]).to eq([ Faraday::ConnectionFailed ])
      expect(retry_options[:exceptions]).not_to include(Faraday::TimeoutError)
    end

    # mukco/gateway gives a provider 150s (Providers::Http::READ_TIMEOUT) and
    # then gives up. This must outlast that, or its clean "provider X failed"
    # becomes a blank Net::ReadTimeout and the reason is lost. If this fails
    # because the gateway's ceiling moved, raise the gateway first.
    it "outlasts the gateway's own ceiling, so the gateway reports the failure" do
      expect(described_class::COMPLETION_TIMEOUT).to be > 150
    end
  end

  # Some services retry a failed completion, and until this existed they could
  # not tell what they were retrying: every Faraday failure arrived as a
  # RuntimeError carrying a string, so a 400 and a three-minute timeout looked
  # identical and both were tried again.
  describe "telling a timeout apart from every other failure" do
    def connection_raising(error)
      connection = double("connection") # rubocop:disable RSpec/VerifiedDoubles
      allow(connection).to receive(:post).and_raise(error)
      allow(described_class).to receive(:connection).and_return(connection)
    end

    it "raises TimedOut when the budget ran out" do
      connection_raising(Faraday::TimeoutError.new("execution expired"))

      expect {
        described_class.json_completion(system_prompt: "s", user_payload: {}, interaction_type: "game_picks")
      }.to raise_error(described_class::TimedOut, /exceeded 180s on game_picks/)
    end

    it "raises the plain Error for a failure that is worth another attempt" do
      connection_raising(Faraday::BadRequestError.new("400"))

      expect {
        described_class.json_completion(system_prompt: "s", user_payload: {}, interaction_type: "t")
      }.to raise_error(described_class::Error, /LLM gateway error/)
    end

    # So `rescue Estate::Llm::Service::Error` still catches both, and a caller
    # opts out of retrying timeouts by naming the narrower one.
    it "makes TimedOut a kind of Error, not a separate hierarchy" do
      expect(described_class::TimedOut.ancestors).to include(described_class::Error)
    end
  end

  describe "MeasuredWait, against Estate::Llm.instrumentation directly" do
    after { Estate::Llm.reset! }

    it "runs the request through whatever an app configured" do
      calls = []
      Estate::Llm.instrumentation = ->(&blk) { calls << :wrapped; blk.call }
      middleware = described_class::MeasuredWait.new(->(env) { env[:ran] = true; env })

      result = middleware.call({})

      expect(calls).to eq([ :wrapped ])
      expect(result[:ran]).to eq(true)
    end

    it "runs the request plain when nothing has configured it" do
      Estate::Llm.reset!
      middleware = described_class::MeasuredWait.new(->(env) { env[:ran] = true; env })

      result = middleware.call({})

      expect(result[:ran]).to eq(true)
    end
  end
end
