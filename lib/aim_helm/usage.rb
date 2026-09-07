# frozen_string_literal: true

module AimHelm
  # Token counts for one provider call. The three prompt fields never overlap, so `prompt_tokens`
  # adds them; `reasoning_tokens` is already inside `output_tokens`, so no total counts it twice.
  class Usage < Dry::Struct
    attribute :cache_write_tokens, Types::Coercible::Integer.default(0)
    attribute :cached_input_tokens, Types::Coercible::Integer.default(0)
    attribute :input_tokens, Types::Coercible::Integer.default(0)
    attribute :output_tokens, Types::Coercible::Integer.default(0)
    attribute :reasoning_tokens, Types::Coercible::Integer.default(0)

    def prompt_tokens = input_tokens + cached_input_tokens + cache_write_tokens
    def total_tokens = prompt_tokens + output_tokens
  end
end
