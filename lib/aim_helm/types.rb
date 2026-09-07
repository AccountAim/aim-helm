# frozen_string_literal: true

module AimHelm
  # Shared coercions for durable and provider boundaries. JsonObject round-trips a value through
  # JSON and freezes it, so a stored payload is always string-keyed with no live object
  # references. ContentBlock accepts a String, a Hash, or anything answering `to_content` (an
  # Image); ContentBlocks normalizes one or many of those into an array of blocks.
  module Types
    include Dry.Types()

    EMPTY_HASH = {}.freeze

    Provider = Coercible::Symbol
    Role = Coercible::Symbol.enum(:system, :user, :assistant, :tool)
    Store = Interface(:append, :entries, :transaction)
    ApprovalGate = Bool | Interface(:call)

    # rubocop:disable Style/ItBlockParameter -- dropping the named param makes
    # Naming/ConstantName stop recognizing these as type constructors
    JsonObject = Hash.constructor do |value|
      ::JSON.parse(::JSON.generate(value)).freeze
    end

    JsonSchema = Hash.constructor do |value|
      JsonObject[value.is_a?(::Hash) ? value : value.json_schema]
    end

    OutputSchema = Instance(Dry::Schema::Processor) | Instance(AimHelm::Schema::Serialized)

    ContentBlock = Hash.constructor do |content|
      content = content.to_content if content.respond_to?(:to_content)

      case content
      when ::Hash then JsonObject[content]
      when ::String then { "type" => "text", "text" => content.freeze }.freeze
      else raise TypeError, "content block must be a String or Hash"
      end
    end

    ContentBlocks = Array.of(ContentBlock).constructor do |content|
      content = content.to_content if content.respond_to?(:to_content)
      content.is_a?(::Array) ? content : [content]
    end
    # rubocop:enable Style/ItBlockParameter
  end
end
