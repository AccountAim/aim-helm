# frozen_string_literal: true

module AimHelm
  module Providers
    module Streaming
      # Incrementally decodes Server-Sent Event fragments into JSON records, yielding one record
      # per data block. Transport feeds it response chunks as they arrive.
      class SSE
        def initialize
          @buffer = +""
          @data = []
        end

        def feed(fragment, &)
          @buffer << fragment

          while (newline = @buffer.index("\n"))
            line = @buffer.slice!(0..newline).delete_suffix("\n").delete_suffix("\r")
            process(line, &)
          end
        end

        def finish(&)
          process(@buffer.delete_suffix("\r"), &) unless @buffer.empty?
          dispatch(&)
        end

        private

        def process(line, &)
          return dispatch(&) if line.empty?
          return if line.start_with?(":")

          field, value = line.split(":", 2)
          @data << value.to_s.delete_prefix(" ") if field == "data"
        end

        def dispatch
          return if @data.empty?

          # Multi-line data fields concatenate; "[DONE]" terminates the stream and is not a record.
          data = @data.join("\n")
          @data.clear
          return if data == "[DONE]"

          record = JSON.parse(data)
          raise ProtocolError, "SSE data must be a JSON object" unless record.is_a?(Hash)

          yield record
        rescue JSON::ParserError => e
          raise ProtocolError, "invalid SSE JSON: #{e.message}"
        end
      end
    end
  end
end
