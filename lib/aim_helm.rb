# frozen_string_literal: true

require "concurrent"
require "dry/monads"
require "dry/schema"
require "dry/struct"
require "faraday"
require "faraday/net_http_persistent"
require "zeitwerk"

require "fileutils"
require "json"
require "logger"
require "securerandom"
require "time"
require "yaml"

Dry::Schema.load_extensions(:json_schema)
require_relative "aim_helm/ext/dry_schema_json_schema_documentation"

# error.rb defines the whole error tree, which Zeitwerk cannot map onto one constant per file.
error_path = File.expand_path("aim_helm/error.rb", __dir__)
require error_path

loader = Zeitwerk::Loader.for_gem
loader.inflector.inflect(
  "jsonl" => "JSONL",
  "openai" => "OpenAI",
  "partial_json" => "PartialJSON",
  "sse" => "SSE",
)
# Rails-only adapters, required at the bottom of this file once Rails is present.
loader.ignore(
  File.expand_path("aim-helm.rb", __dir__),
  error_path,
  File.expand_path("aim_helm/ext", __dir__),
  File.expand_path("aim_helm/active_job.rb", __dir__),
  File.expand_path("aim_helm/active_job", __dir__),
  File.expand_path("aim_helm/railtie.rb", __dir__),
  File.expand_path("aim_helm/stores/active_record.rb", __dir__),
  File.expand_path("aim_helm/stores/active_record", __dir__),
)
loader.setup

# Entry point for the gem: memoizes a frozen default Config and mints agents, sessions, and
# providers from it. `agent(session:)` takes no definition attributes — it rebuilds the agent from
# the run record durably stored on that session, resolving tool identifiers through config.tools.
module AimHelm
  class << self
    def config
      @config ||= Config.new(
        providers: {
          anthropic: Config::Provider.new(base_url: Providers::Anthropic::DEFAULT_BASE_URL),
          openai: Config::Provider.new(base_url: Providers::OpenAI::DEFAULT_BASE_URL),
        },
        provider_factory: Providers.method(:build),
        model_catalog: Catalog.default,
      ).freeze
    end

    def configure
      builder = Config::Builder.new(config)
      yield builder
      @config = builder.build
    end

    def models(config: self.config) = config.model_catalog

    def provider(model_id, config: self.config, api_key: nil, **)
      Providers.resolve(model_id, config:, api_key:, **)
    end

    def agent(model = nil, session: nil, advance: nil, **attributes)
      if session
        attributes = attributes.merge(advance:) if advance
        return reconstruct_agent(session, model:, attributes:)
      end

      raise ArgumentError, "model is required" unless model

      Agent.new(model:, advance_mode: advance, **attributes)
    end

    def session(id, store: config.store)
      raise ConfigurationError, "no default session store is configured" unless store

      Session.new(store:, id: id.to_s)
    end

    def sweep(store: config.store)
      raise ConfigurationError, "no default session store is configured" unless store

      Sweep.new(store:).call
    end

    private

    def reconstruct_agent(session, model:, attributes:)
      if model || attributes.any?
        raise ArgumentError, "session reconstruction does not accept definition attributes"
      end

      run_id = session.pending_run_id
      record = if run_id
                 Agent::Record.fetch(session.entries, run_id:)
               else
                 Agent::Record.latest(session.entries)
               end
      tools = record.tools.map do
        resolver = session.config.tools || raise(
          ConfigurationError,
          "no durable tool resolver is configured",
        )
        resolver.resolve(it)
      end

      record.materialize(tools:).new(bound_session: session)
    end
  end
end

if defined?(Rails::Railtie)
  require "aim_helm/railtie"
  require "aim_helm/stores/active_record" if defined?(ActiveRecord::Base)
  require "aim_helm/active_job" if defined?(ActiveJob::Base)
end
