# frozen_string_literal: true

module AimHelm
  # An image attachment in one of three source forms — remote url, inline base64, or a
  # provider-hosted file id — rendered by `to_content` into the neutral block that provider
  # serializers translate per API.
  class Image < Dry::Struct
    DETAIL = Types::Coercible::Symbol.enum(:auto, :low, :high)

    attribute :detail, DETAIL.optional.default(nil)
    attribute :source, Types::JsonObject

    class << self
      def url(url, detail: nil)
        new(source: { type: "url", url: }, detail:)
      end

      def data(bytes, media_type:, detail: nil)
        new(
          source: {
            type: "base64",
            media_type:,
            data: [bytes].pack("m0"),
          },
          detail:,
        )
      end

      def provider_file(provider:, id:, detail: nil)
        new(
          source: {
            type: "file",
            provider:,
            file_id: id,
          },
          detail:,
        )
      end
    end

    def data = source["data"]
    def media_type = source["media_type"]

    def to_content
      Types::JsonObject[
        {
          type: "image",
          source:,
          detail: detail&.to_s,
        }.compact,
      ]
    end
  end
end
