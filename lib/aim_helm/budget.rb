# frozen_string_literal: true

module AimHelm
  # Per-run ceilings on tokens, cost, and wall clock; a nil field means no limit. `narrow` keeps
  # the tighter of two budgets field by field, so a subagent never outspends its parent.
  # `exhaustion` reports the first limit the session has reached, or nil.
  class Budget < Dry::Struct
    CONTRACT = Schema.define do
      optional(:tokens).value(:integer, gt?: 0)
      optional(:cost).value(:float, gt?: 0)
      optional(:wall_clock).value(:float, gt?: 0)
    end

    extend ClosedRecord

    attribute :cost, Types::Coercible::Float.constrained(gt: 0).optional.default(nil)
    attribute :tokens, Types::Coercible::Integer.constrained(gt: 0).optional.default(nil)
    attribute :wall_clock, Types::Coercible::Float.constrained(gt: 0).optional.default(nil)

    def narrow(other)
      return self unless other

      limits = self.class.record_fields.to_h do
        [it, narrowest(public_send(it), other.public_send(it))]
      end
      self.class.new(**limits)
    end

    def exhaustion(entries, live_wall_clock: 0.0)
      spent = Spend.from(entries, live_wall_clock:)
      exceeded = self.class.record_fields.find do
        limit = public_send(it)
        limit && spent.public_send(it) >= limit
      end
      return unless exceeded

      Types::JsonObject[{ limit: dump, spent: spent.to_h, exceeded: }]
    end

    class << self
      private

      def record_label = "budget"
    end

    private

    def narrowest(parent, subagent)
      return subagent unless parent
      return parent unless subagent

      [parent, subagent].min
    end

    # Running totals folded from the log: `usage` entries plus the usage attached to `assistant`
    # entries. `live_wall_clock` adds the in-flight turn's elapsed time, not yet appended.
    class Spend < Dry::Struct
      TOKEN_FIELDS = %w[input_tokens output_tokens cached_input_tokens cache_write_tokens].freeze

      attribute :cost, Types::Coercible::Float.default(0.0)
      attribute :tokens, Types::Coercible::Integer.default(0)
      attribute :wall_clock, Types::Coercible::Float.default(0.0)

      def self.from(entries, live_wall_clock: 0.0)
        usage = entries.filter_map do
          next it.payload if it.kind == "usage"
          next it.payload["usage"] if it.kind == "assistant"
        end
        new(
          tokens: usage.sum { token_total(it) },
          cost: usage.sum { it.fetch("cost", 0.0) },
          wall_clock: usage.sum { it.fetch("wall_clock", 0.0) } + live_wall_clock,
        )
      end

      def self.token_total(payload) = TOKEN_FIELDS.sum { payload.fetch(it, 0) }
    end
  end
end
