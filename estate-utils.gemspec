# frozen_string_literal: true

require_relative "lib/estate/cache/version"

Gem::Specification.new do |spec|
  spec.name          = "estate-utils"
  spec.version       = Estate::Cache::VERSION
  spec.authors       = ["Devoun Edwards"]
  spec.summary       = "Shared caching and LLM gateway client for the estate's apps."
  spec.description   = "Estate::Cache::Answers resolves an expensive answer — a model completion, " \
                       "a scrape, a warehouse query — against a TTL and an optional " \
                       "fingerprint, re-leasing rather than rebuilding when the inputs " \
                       "have not moved, and always keeping a last-good copy so a miss is " \
                       "never a wait on the request path. Estate::Cache::Warehouse is the " \
                       "build-stamped variant; Estate::Cache::AnswerLog says what the cache did. " \
                       "Estate::Llm::Service is the one client for the shared gateway — " \
                       "completions, chat, the knowledge index — that every app used to carry " \
                       "its own byte-identical copy of."
  spec.homepage      = "https://github.com/mukco/estate-utils"
  spec.license       = "MIT"
  spec.required_ruby_version = ">= 3.2"
  spec.files = Dir["lib/**/*.rb", "README.md", "MIGRATION.md", "LICENSE"]
  spec.require_paths = ["lib"]
  spec.add_dependency "activesupport", ">= 7.1"
  spec.add_dependency "faraday", ">= 2.0"
  spec.metadata["rubygems_mfa_required"] = "true"
end
