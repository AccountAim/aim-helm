# frozen_string_literal: true

module AimHelm
  # User input as text plus image attachments. Any Message content slot accepts it directly:
  # Types::ContentBlocks coerces through `to_content`, which emits the text block first and then
  # one block per attachment.
  class Input < Dry::Struct
    attribute :attachments, Types::Array.of(Types.Instance(AimHelm::Image)).default([].freeze)
    attribute :text, Types::String.optional.default(nil)

    def to_content
      blocks = []
      blocks << { type: "text", text: } if text
      blocks.concat(attachments.map(&:to_content))
      Types::ContentBlocks[blocks]
    end
  end
end
