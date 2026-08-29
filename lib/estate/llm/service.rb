# frozen_string_literal: true

require "securerandom"
require "faraday"
require "cgi"

module Estate
  module Llm
    # The one gateway client for the estate. Baseball's and football's copies
    # were identical except for which client_id each sent and some comments
    # one of them never carried over — this is the union.
    class Service
      GATEWAY_URL = -> { ENV["LLM_GATEWAY_URL"].presence || "http://127.0.0.1:8090" }
      DEFAULT_MODEL = "auto".freeze

      # Anything the gateway did that this app could not use.
      Error = Class.new(StandardError)

      # A completion that ran out of budget, told apart from every other failure
      # because it is the one nobody may retry. The work started and did not finish;
      # asking again pays for all of it a second time and waits all of it again.
      #
      # It needs its own class because the callers that retry cannot otherwise tell.
      # Every Faraday failure used to arrive as `raise "LLM gateway error: ..."` — a
      # RuntimeError carrying a string — so a `rescue => e` around a completion
      # retried a 400 and a three-minute timeout identically, and two services did
      # exactly that.
      TimedOut = Class.new(Error)

      # OpenAI refuses `response_format: json_object` outright unless the word
      # "json" appears somewhere in the messages, and our prompts describe the
      # shape they want without ever using it. The clause is added here rather than
      # in each of the thirty-odd prompts because this is where the format is asked
      # for — a prompt that has to remember an unrelated provider rule is a prompt
      # that will eventually forget.
      JSON_MODE_CLAUSE = "Reply with JSON: a single JSON object, no prose around it and no markdown fence.".freeze

      # How long a completion may take. One number for every completion an app
      # makes, and no way for a caller to pass a different one.
      #
      # It used to be six per app: 25 here, and 30/60/60/90/90 in the five
      # services that had been found painful in production one at a time. Every
      # one of those was below what the work measurably takes (58s insights,
      # 102s free agents, 124s start/sit), so all they really did was choose
      # which answers failed. And the 25 was passed *explicitly* into
      # #connection, overriding the connection-level default — which is how
      # raising that default from 60 to 180 changed nothing at all, while the
      # three per-service overrides actually carrying the load were deleted in
      # the same commit.
      #
      # There is one number because there is now only one kind of caller. Nothing
      # a person waits on generates a completion: LLM-backed endpoints read cache
      # and answer 202, and generating happens in a job. So "how long may this
      # take?" has a single answer — as long as the work takes — with no request
      # budget to reconcile it against.
      #
      # 180 sits deliberately ABOVE the gateway's own ceiling. mukco/gateway gives
      # a provider 150s (Providers::Http::READ_TIMEOUT) and then gives up. Timing
      # out first would replace the gateway's account of what failed with our own
      # blank Net::ReadTimeout; timing out second means the gateway always answers
      # first and names the provider and the reason. The gap is the point — so
      # raising this without raising that buys nothing.
      COMPLETION_TIMEOUT = Integer(ENV.fetch("LLM_COMPLETION_TIMEOUT", 180))

      # The knowledge index is not the model. Nothing generates, these answer in
      # milliseconds or they are not worth waiting for, and they sit inline in front
      # of work that is itself cached — so they keep their own small budgets rather
      # than inheriting the completion one. A lookup that hangs for three minutes is
      # a bug; a completion that takes three minutes is Tuesday.
      LOOKUP_TIMEOUT = 8
      INGEST_TIMEOUT = 30

      # Time spent in here is still the family's wait, but it is not this app
      # working. The gateway's mean completion is fourteen seconds, and some
      # endpoints routinely sit past twenty — enough that, undivided, every
      # percentile of this app would only ever be saying "an LLM call
      # happened". The reporter counts it apart.
      #
      # Middleware rather than one call site per method: the retry below means
      # one call can be three, and a site added later would otherwise go
      # uncounted. Wraps Estate::Llm.instrumentation rather than naming
      # Estate::Monitor directly — this gem does not depend on that one; an
      # app wires the two together in its own initializer.
      #
      # Defined at the class level rather than inside `class << self` — a
      # nested `class` there lands under the singleton class, not
      # Estate::Llm::Service, and Service::MeasuredWait needs to resolve from
      # outside for specs to reach it directly.
      class MeasuredWait < Faraday::Middleware
        def call(env)
          Estate::Llm.instrumentation.call { @app.call(env) }
        end
      end

      class << self
        # Structured JSON completion. Returns { request_id:, model:, output: <parsed Hash>, usage: {...}, prompt_chars: }.
        # There is deliberately no `timeout:` parameter. It existed, five callers
        # used it, and every one of them used it to ask for *less* than the work
        # needs. A caller cannot know better than this file how long a completion
        # takes, because the answer does not vary by caller — it varies by model,
        # and the model is the gateway's choice, not ours.
        def json_completion(system_prompt:, user_payload:, interaction_type:, metadata: {}, temperature: 0.2)
          request_id   = SecureRandom.uuid
          user_content = JSON.generate(user_payload)

          body = {
            model: ENV["LLM_MODEL"].presence || DEFAULT_MODEL,
            response_format: { type: "json_object" },
            temperature: temperature,
            messages: [
              { role: "system", content: [ system_prompt, JSON_MODE_CLAUSE ].join("\n\n") },
              { role: "user",   content: user_content }
            ]
          }

          response = connection(timeout: COMPLETION_TIMEOUT).post("/v1/chat/completions") do |req|
            req.headers["Content-Type"] = "application/json"
            req.headers["X-Client-Id"]  = ENV["LLM_CLIENT_ID"]
            # Which of this app's jobs the call is. The gateway bills, caps and
            # switches off by X-Client-Id — one app, one bill — and may route by
            # X-Client-Call, so a short structured answer need not use the model
            # that writes an analysis. Nothing here chooses a model; the gateway
            # does, from a row, which is still the whole point.
            req.headers["X-Client-Call"] = interaction_type if interaction_type.present?
            req.headers["Authorization"] = "Bearer #{ENV["LLM_API_KEY"]}" if ENV["LLM_API_KEY"].present?
            req.body = JSON.generate(body)
          end

          response_json = JSON.parse(response.body)
          content       = response_json.dig("choices", 0, "message", "content").to_s.strip
          content       = content.gsub(/\A```(?:json)?\n?/, "").gsub(/\n?```\z/, "").strip
          parsed        = JSON.parse(content)
          usage         = response_json["usage"] || {}

          {
            request_id:   request_id,
            model:        response_json["model"] || body[:model],
            output:       parsed,
            prompt_chars: system_prompt.length + user_content.length,
            usage: {
              input_tokens:  usage["prompt_tokens"],
              output_tokens: usage["completion_tokens"],
              total_tokens:  usage["total_tokens"]
            }
          }
        rescue JSON::ParserError
          # Worth retrying: the model produced prose where JSON was asked for, and
          # the next attempt is a fresh roll of the same dice.
          raise Error, "LLM gateway returned non-JSON content"
        rescue Faraday::TimeoutError => e
          raise TimedOut, "LLM gateway exceeded #{COMPLETION_TIMEOUT}s on #{interaction_type}: #{e.message}"
        rescue Faraday::Error => e
          raise Error, "LLM gateway error: #{e.message}"
        end

        # Multi-turn chat with optional tool use — used by AssistantService.
        # Returns the raw OpenAI-shaped response hash.
        def chat(messages:, tools: nil, interaction_type: "assistant")
          body = {
            model:       ENV["LLM_MODEL"].presence || DEFAULT_MODEL,
            messages:    messages,
            tool_choice: "auto",
            temperature: 0.2
          }
          body[:tools] = tools if tools.present?

          response = connection(timeout: COMPLETION_TIMEOUT).post("/v1/chat/completions") do |req|
            req.headers["Content-Type"] = "application/json"
            req.headers["X-Client-Id"]  = ENV["LLM_CLIENT_ID"]
            req.headers["X-Client-Call"] = interaction_type if interaction_type.present?
            req.headers["Authorization"] = "Bearer #{ENV["LLM_API_KEY"]}" if ENV["LLM_API_KEY"].present?
            req.body = JSON.generate(body)
          end

          JSON.parse(response.body)
        rescue Faraday::TimeoutError => e
          raise TimedOut, "LLM gateway exceeded #{COMPLETION_TIMEOUT}s on #{interaction_type}: #{e.message}"
        rescue Faraday::Error => e
          raise Error, "LLM gateway error: #{e.message}"
        end

        def ingest_chunks(chunks, batch_size: 100)
          return { indexed: 0 } if chunks.blank?

          total = 0
          chunks.each_slice(batch_size) do |batch|
            body = JSON.generate({ client_id: ENV["LLM_CLIENT_ID"], chunks: batch })
            response = connection(timeout: INGEST_TIMEOUT).post("/knowledge/ingest") do |req|
              req.headers["Content-Type"] = "application/json"
              req.headers["X-Client-Id"]  = ENV["LLM_CLIENT_ID"]
              req.headers["Authorization"] = "Bearer #{ENV["LLM_API_KEY"]}" if ENV["LLM_API_KEY"].present?
              req.body = body
            end
            result = JSON.parse(response.body)
            total += (result["indexed"] || 0).to_i
          end
          { "indexed" => total }
        rescue Faraday::Error => e
          { error: e.message }
        end

        def search_knowledge(query)
          response = connection(timeout: LOOKUP_TIMEOUT).get("/knowledge/search") do |req|
            req.params["q"] = query
            req.headers["X-Client-Id"] = ENV["LLM_CLIENT_ID"]
            req.headers["Authorization"] = "Bearer #{ENV["LLM_API_KEY"]}" if ENV["LLM_API_KEY"].present?
          end
          response.status == 200 ? { results: response.body.strip.presence } : { results: nil }
        rescue Faraday::Error
          { results: nil }
        end

        def fetch_knowledge(interaction_type)
          query = CGI.escape(interaction_type.tr("_", " "))
          response = connection(timeout: LOOKUP_TIMEOUT).get("/knowledge/#{interaction_type}?q=#{query}") do |req|
            req.headers["X-Client-Id"] = ENV["LLM_CLIENT_ID"]
            req.headers["Authorization"] = "Bearer #{ENV["LLM_API_KEY"]}" if ENV["LLM_API_KEY"].present?
          end
          response.status == 200 ? response.body.strip.presence : nil
        rescue Faraday::Error
          nil
        end

        # timeout: is required, not defaulted. A default here is what caused the
        # outage: this method had `timeout || 180` and looked authoritative, while
        # every completion passed an explicit 25 that silently won. Two numbers, one
        # of them decorative, and no way to tell from either call site which was in
        # force. Making the caller say it means the budget is always the one written
        # next to the request — and there are only three callers, each naming a
        # constant declared at the top of this file.
        def connection(timeout:)
          Faraday.new(url: GATEWAY_URL.call) do |f|
            f.use MeasuredWait
            # Retries a gateway that is not there — a deploy restarting the
            # accessory, a refused or dropped connection — and nothing else.
            #
            # It used to retry on timeout too, which is the default. That turned one
            # slow completion into three, so a call already over budget spent 3× the
            # wall clock and billed the provider three times for work we then threw
            # away. mukco/gateway does not retry, for exactly this reason, and says
            # so in a comment naming the app as the retrier: "the app on the other
            # side of this gateway is already doing its own retrying." A completion
            # that timed out did not fail to start — it failed to finish, and asking
            # again just starts it over.
            f.request :retry, max: 2, interval: 0.5, exceptions: [ Faraday::ConnectionFailed ]
            f.response :raise_error
            f.options.timeout      = timeout
            # Connecting is not generating. The gateway is a container on the same
            # Docker network; if it has not accepted a socket in 8 seconds it is not
            # going to, and that is worth failing fast on however long the
            # completion behind it would have taken.
            f.options.open_timeout = 8
          end
        end
      end
    end
  end
end
