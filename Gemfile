# frozen_string_literal: true

source "https://rubygems.org"
gemspec
gem "rspec"
# The specs drive the modules directly against an ActiveSupport::Cache::MemoryStore
# — there is no Rails here, and that is the point: the gem reads through to
# Rails.cache when a Rails exists and takes a store when one does not, so the
# extraction can be shown to be clean without an application to lean on.
