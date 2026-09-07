# frozen_string_literal: true

module AimHelm
  module Events
    # Writes one line per event: the type, then the remaining fields as normalized JSON. Passed to
    # Agent#run(events:).
    class Logger < Dry::Struct
      attribute :logger, Types.Interface(:info)
      attribute :prefix, Types::String.default("[aim_helm]")

      def call(event)
        logger.info("#{prefix} #{event.type} #{JSON.generate(normalize(event.to_h.except(:type)))}")
      end

      def to_proc = method(:call).to_proc

      private

      def normalize(value)
        case value
        when Hash then value.to_h { |key, item| [key, normalize(item)] }
        when Array then value.map { normalize(it) }
        else value.respond_to?(:to_h) ? normalize(value.to_h) : value
        end
      end
    end
  end
end
