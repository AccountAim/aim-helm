# frozen_string_literal: true

module AimHelm
  module Providers
    module Streaming
      # Persistent HTTP connection for streaming provider calls: posts the body, feeds the
      # response through SSE, and maps connection failures and non-2xx statuses onto AimHelm's
      # provider error classes.
      class Transport < Dry::Struct
        ERROR_PREVIEW_BYTES = 500

        attribute :base_url, Types::String
        attribute :open_timeout, Types::Coercible::Float.default(15.0)
        attribute :read_timeout, Types::Coercible::Float.default(300.0)
        attribute :write_timeout, Types::Coercible::Float.default(60.0)

        def stream_post(path, body:, headers: {}, &)
          with_connection_errors do
            parser = SSE.new
            error_body = +""
            callback = stream_callback(parser, error_body, &)
            response = stream_response(path, body, headers, callback)
            raise_for_status(response.status, response.headers, error_body)
            parser.finish(&)
          end
        end

        def close = @connection&.close

        private

        # Endpoint paths are relative, so a base URL carrying a path — an `/v1` suffix or a proxy
        # mounted on a subpath — is kept rather than discarded.
        def base = @base ||= "#{base_url.delete_suffix("/")}/"

        def connection
          @connection ||= Faraday.new(url: base) do
            it.options.open_timeout = open_timeout
            it.options.read_timeout = read_timeout
            it.options.write_timeout = write_timeout
            it.adapter :net_http_persistent
          end
        end

        def with_connection_errors
          yield
        rescue Faraday::TimeoutError => e
          raise RequestTimeoutError, e.message
        rescue Faraday::ConnectionFailed, Faraday::SSLError => e
          raise ConnectionError, e.message
        end

        def stream_response(path, body, headers, callback)
          connection.post(URI.join(base, path)) do
            configure(it, body, headers.merge("Accept" => "text/event-stream"))
            it.options.on_data = callback
          end
        end

        def stream_callback(parser, error_body, &)
          lambda do |chunk, _bytes, env|
            if env.success?
              parser.feed(chunk, &)
            else
              append_error(error_body, chunk)
            end
          end
        end

        def configure(request, body, headers)
          request.headers["Content-Type"] = "application/json"
          # Identity encoding keeps SSE chunks readable as they arrive.
          request.headers["Accept-Encoding"] = "identity"
          request.headers.update(headers)
          request.body = JSON.generate(body)
        end

        # A failed response still streams through on_data; keep a bounded preview for the error.
        def append_error(error_body, chunk)
          remaining = ERROR_PREVIEW_BYTES - error_body.bytesize
          error_body << chunk.byteslice(0, remaining) if remaining.positive?
        end

        def raise_for_status(status, headers, body)
          return if (200..299).cover?(status)

          raise status_error(status, headers, body)
        end

        def status_error(status, headers, body)
          options = { status:, body: body.to_s.force_encoding(Encoding::UTF_8).scrub }

          case status
          when 401, 403 then AuthenticationError.new("authentication failed", **options)
          when 408 then RequestTimeoutError.new("request timed out", **options)
          when 429 then RateLimitError.new(retry_after: retry_after(headers), **options)
          when 529 then OverloadedError.new("provider overloaded", **options)
          when 500..599 then ServerError.new("provider server error", **options)
          else ProviderError.new(status:, body: options[:body])
          end
        end

        def retry_after(headers)
          value = headers["retry-after"]
          value.to_f if value&.match?(/\A\d+(\.\d+)?\z/)
        end
      end
    end
  end
end
