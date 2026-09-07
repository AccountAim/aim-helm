# frozen_string_literal: true

module AimHelm
  module Providers
    # Shared provider streaming lifecycle: posts the body the including class builds, feeds SSE
    # records to its assembler, and retries transient failures. Including classes supply
    # `build_assembler`, `body`, `headers`, and `stream_path`.
    module Streaming
      def stream(system: nil, messages: [], tools: [], output_schema: nil, &emit)
        attempt = 0

        begin
          # Per attempt: `retry` re-enters here, so a fresh assembler and a cleared emitted gate
          # replace the aborted attempt's state.
          emitted = false
          assembler = build_assembler
          visible_emit = emit && lambda do
            emitted = true
            emit.call(Event.build(**it))
          end
          transport.stream_post(
            stream_path,
            body: body(system, messages, tools, output_schema),
            headers:,
          ) { assembler.feed(it, &visible_emit) }
          assembler.finish(&visible_emit)
        rescue ProviderError => e
          attempt += 1

          if retry_policy.retry?(e, attempt:, emitted:)
            sleep retry_policy.delay(e, attempt:)
            retry
          end

          emit&.call(Event.build(type: :"provider.failed", error: e.message))
          raise
        end
      end

      def close = transport.close

      private

      def transport
        @transport ||= Transport.new(base_url:, open_timeout:, read_timeout:, write_timeout:)
      end
    end
  end
end
