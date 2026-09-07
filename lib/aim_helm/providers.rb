# frozen_string_literal: true

module AimHelm
  # Turns a model id into a streaming provider client. `resolve` looks the model up in the
  # catalog, layers in the configured api key and base URL for its provider, and calls
  # `config.provider_factory` — `build` by default, which validates reasoning support, falls back
  # to the provider's ENV key, and instantiates the NATIVE client.
  module Providers
    NATIVE = {
      anthropic: Anthropic,
      openai: OpenAI,
    }.freeze

    API_KEYS = {
      anthropic: "ANTHROPIC_API_KEY",
      openai: "OPENAI_API_KEY",
    }.freeze

    module_function

    def resolve(model_id, config:, api_key: nil, **attributes)
      model = model_for(model_id, catalog: config.model_catalog)
      settings = config.provider_settings(model.provider)
      config.provider_factory.call(
        model_id,
        api_key: api_key || settings.api_key,
        base_url: settings.base_url,
        catalog: config.model_catalog,
        **attributes,
      )
    end

    def build(model_id, api_key: nil, base_url: nil, reasoning: nil,
              catalog: Catalog.default,
              **attributes)
      model = model_for(model_id, catalog:)
      validate_reasoning!(model, reasoning)
      key = api_key || ENV.fetch(API_KEYS.fetch(model.provider), nil)
      raise ConfigurationError, "no API key for #{model.provider}" if key.to_s.empty?

      attributes[:base_url] = base_url if base_url
      NATIVE.fetch(model.provider).new(
        api_key: key,
        model: model_id,
        reasoning:,
        catalog:,
        **attributes,
      )
    end

    def model_for(model_id, catalog: Catalog.default)
      catalog.fetch(model_id) do
        raise ConfigurationError, "unknown model #{model_id.inspect}"
      end
    end

    def validate_reasoning!(model, reasoning)
      return unless reasoning && !model.reasoning_effort

      raise ConfigurationError, "#{model.id} does not support reasoning effort"
    end
  end
end
