# frozen_string_literal: true

module AimHelm
  module Providers
    # Converts a normalized image block into provider wire form: an OpenAI input_image (url, data
    # URI, or file id) or an Anthropic image source. A file source names the provider hosting it
    # and cannot be sent to the other one.
    class Image < Dry::Struct
      DETAIL = Types::Coercible::Symbol.enum(:auto, :low, :high)

      attribute :detail, DETAIL.optional.default(nil)
      attribute :source, Types::JsonObject

      def self.from(content)
        new(**content.except("type").transform_keys(&:to_sym))
      end

      def openai
        image = { type: "input_image" }
        image[:detail] = detail.to_s if detail

        case source.fetch("type")
        when "url" then image[:image_url] = source.fetch("url")
        when "base64"
          image[:image_url] = "data:#{source.fetch("media_type")};base64,#{source.fetch("data")}"
        when "file" then image[:file_id] = file_id(:openai)
        else raise ConfigurationError, "unknown image source #{source.fetch("type").inspect}"
        end

        image
      end

      def anthropic
        native = case source.fetch("type")
                 when "url", "base64" then source
                 when "file" then source.merge("file_id" => file_id(:anthropic))
                 else raise ConfigurationError,
                            "unknown image source #{source.fetch("type").inspect}"
                 end
        # `provider` names the host holding an uploaded file; it is bookkeeping, not wire.
        { type: "image", source: native.except("provider").transform_keys(&:to_sym) }
      end

      private

      def file_id(expected)
        provider = source.fetch("provider").to_sym

        unless provider == expected
          raise ConfigurationError, "#{provider} file cannot be sent to #{expected}"
        end

        source.fetch("file_id")
      end
    end
  end
end
