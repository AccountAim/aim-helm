# frozen_string_literal: true

module AimHelm
  module Providers
    module Streaming
      # Parses a truncated JSON prefix into the value so far, so streaming tool arguments can be
      # rendered before the call closes. Fragments that cannot be salvaged are dropped, and any
      # failure yields {} rather than raising.
      module PartialJSON
        class << self
          def parse(text)
            source = text.to_s.strip
            return {} if source.empty?

            value = Parser.new(source).parse
            value.equal?(Parser::NOTHING) ? {} : value
          rescue StandardError
            {}
          end
        end

        class Parser
          # Distinct from nil, which is a legitimate parsed value (JSON null).
          NOTHING = Object.new
          LITERALS = { "true" => true, "false" => false, "null" => nil }.freeze
          MAX_DEPTH = 256

          def initialize(source)
            @source = source
            @length = source.length
            @index = 0
            @partial = false
            @depth = 0
          end

          def parse = value

          private

          def value
            skip_whitespace
            return truncated if eof?

            case @source[@index]
            when '"' then string
            when "{" then nested { object }
            when "[" then nested { array }
            else scalar
            end
          end

          def nested
            raise RangeError, "JSON exceeds maximum depth" if @depth >= MAX_DEPTH

            @depth += 1

            begin
              yield
            ensure
              @depth -= 1
            end
          end

          def object
            @index += 1
            result = {}

            until @partial
              skip_whitespace
              break truncated if eof?
              break @index += 1 if @source[@index] == "}"
              break unless @source[@index] == '"'

              key, item = pair
              result[key] = item unless key.equal?(NOTHING) || item.equal?(NOTHING)
              skip_whitespace
              @index += 1 if !eof? && @source[@index] == ","
            end

            result
          end

          def pair
            key = string
            return [NOTHING, NOTHING] if @partial

            skip_whitespace
            return [NOTHING, truncated] if eof?
            return [NOTHING, NOTHING] unless @source[@index] == ":"

            @index += 1
            [key, value]
          end

          def array
            @index += 1
            result = []

            until @partial
              skip_whitespace
              break truncated if eof?
              break @index += 1 if @source[@index] == "]"

              item = value
              result << item unless item.equal?(NOTHING)
              skip_whitespace
              @index += 1 if !eof? && @source[@index] == ","
            end

            result
          end

          def string
            start = @index
            @index += 1
            escaped = false

            while @index < @length
              case
              when escaped then escaped = false
              when @source[@index] == "\\" then escaped = true
              when @source[@index] == '"'
                @index += 1
                return decode(@source[start...@index])
              end

              @index += 1
            end

            truncated
            salvage_string(@source[start..])
          end

          # Close an unterminated string: drop a partial \uXXXX escape and a dangling backslash,
          # then quote it. `"ab\u00` becomes `"ab"`.
          def salvage_string(fragment)
            candidate = fragment.sub(/\\u[0-9a-fA-F]{0,3}\z/, "")
            trailing = candidate[/\\+\z/]
            candidate = candidate[0..-2] if trailing&.length&.odd?
            decode(%(#{candidate}"))
          end

          def scalar
            start = @index
            @index += 1 while @index < @length && !"},] \n\r\t".include?(@source[@index])
            token = @source[start...@index]
            # Unrecognized delimiter: consume it so the enclosing loop advances.
            return (@index += 1) && NOTHING if token.empty?

            truncated if eof?
            literal(token) { number(token) }
          end

          def literal(token)
            return LITERALS[token] if LITERALS.key?(token)

            if @partial
              match = LITERALS.keys.find { it.start_with?(token) }
              return LITERALS[match] if match
            end

            yield
          end

          def number(token)
            Integer(token)
          rescue ArgumentError
            begin
              finite(Float(token))
            rescue ArgumentError
              trimmed_number(token)
            end
          end

          def trimmed_number(token)
            trimmed = token.sub(/[eE][+-]?\z/, "").sub(/\.\z/, "")
            return NOTHING if trimmed.empty? || trimmed == "-"

            finite(Float(trimmed))
          rescue ArgumentError
            NOTHING
          end

          def finite(number) = number.finite? ? number : NOTHING

          def decode(json_string)
            JSON.parse(json_string)
          rescue JSON::ParserError
            NOTHING
          end

          def skip_whitespace
            @index += 1 while @index < @length && " \n\r\t".include?(@source[@index])
          end

          def eof? = @index >= @length

          def truncated
            @partial = true
            NOTHING
          end
        end
      end
    end
  end
end
