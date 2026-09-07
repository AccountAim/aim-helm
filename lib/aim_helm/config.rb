# frozen_string_literal: true

module AimHelm
  # Immutable host wiring: provider credentials, model catalog, store, tool resolver, and the
  # callbacks AimHelm uses to reach its host — `advance`, `broadcast`, `authorize`, `telemetry`.
  # `AimHelm.configure` yields Builder and installs the frozen result; `with` returns a copy.
  class Config < Dry::Struct
    class Provider < Dry::Struct
      attribute :api_key, Types::String.optional.default(nil)
      attribute :base_url, Types::String.optional.default(nil)
    end

    # `with` and Builder round-trip only these names, so every attribute must be listed.
    FIELDS = %i[
      providers
      logger
      telemetry
      provider_factory
      model_catalog
      advance
      store
      tools
      subagent_host
      broadcast
      authorize
      advance_job
      root_queue
      subagent_queue
    ].freeze

    SUBAGENT_HOST = Types.Interface(:spawn, :read, :queue_message, :stop, :continue).optional

    PROVIDER = Types.Instance(Provider).constructor do
      it.is_a?(Provider) ? it : Provider.new(**it.transform_keys(&:to_sym))
    end

    PROVIDERS = Types::Hash.map(Types::Coercible::Symbol, PROVIDER)

    attribute :advance, Types.Interface(:call).optional.default(nil)
    attribute :advance_job, Types.Instance(Class).optional.default(nil)
    attribute :authorize, Types.Interface(:call).optional.default(nil)
    attribute :broadcast, Types.Interface(:call).optional.default(nil)
    attribute(:logger, Types.Interface(:error).default { ::Logger.new($stdout) })
    attribute :model_catalog, Types::Hash
    attribute :provider_factory, Types.Interface(:call)
    attribute :providers, PROVIDERS.default({}.freeze)
    attribute :root_queue, Types::Coercible::Symbol.default(:agent)
    attribute :store, Types::Store.optional.default(nil)
    attribute :subagent_host, SUBAGENT_HOST.default(nil)
    attribute :subagent_queue, Types::Coercible::Symbol.default(:agent_subagents)
    attribute(:telemetry, Types.Interface(:call).default { Telemetry })
    attribute :tools, Types.Interface(:resolve).optional.default(nil)

    def with(**changes)
      current = FIELDS.to_h { [it, public_send(it)] }
      self.class.new(**current, **changes).freeze
    end

    def provider_settings(name) = providers.fetch(name.to_sym) { Provider.new }

    class Builder
      attr_accessor(*FIELDS)

      def initialize(config)
        FIELDS.each { public_send("#{it}=", config.public_send(it)) }
      end

      def build
        Config.new(**FIELDS.to_h { [it, public_send(it)] }).freeze
      end

      def session_model=(model)
        unless Stores.const_defined?(:ActiveRecord, false)
          raise ConfigurationError,
                'Active Record support is not loaded; require "aim_helm/stores/active_record"'
        end

        self.store = Stores::ActiveRecord.new(session_model: model)
      end

      def provider(name, **settings)
        current = providers.fetch(name.to_sym) { Provider.new }
        self.providers = providers.merge(name.to_sym => current.new(**settings)).freeze
      end
    end
  end
end
