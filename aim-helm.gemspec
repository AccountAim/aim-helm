# frozen_string_literal: true

Gem::Specification.new do
  it.name = "aim-helm"
  it.version = "0.1.0"
  it.authors = ["gauravs"]
  it.summary = "Rails-free agent runtime"
  it.description = "Provider, replay, and durable-session primitives for AI agents"
  it.license = "MIT"

  it.required_ruby_version = ">= 3.4.0"

  it.files = Dir["docs/**/*", "lib/**/*", "spec/support/**/*"] + %w[LICENSE README.md]
  it.require_paths = ["lib"]

  it.add_dependency "concurrent-ruby"
  it.add_dependency "dry-monads"
  it.add_dependency "dry-schema"
  it.add_dependency "dry-struct"
  it.add_dependency "faraday"
  it.add_dependency "faraday-net_http_persistent"
  it.add_dependency "zeitwerk"

  it.metadata["rubygems_mfa_required"] = "true"
end
