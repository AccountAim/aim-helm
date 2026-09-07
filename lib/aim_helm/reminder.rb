# frozen_string_literal: true

module AimHelm
  # Recurring text injected back into the conversation on a turn schedule: first at `after`
  # (defaulting to `every`), then every `every` assistant turns after that.
  class Reminder < Dry::Struct
    CONTRACT = Schema.define do
      required(:text).filled(:string)
      required(:every).value(:integer, gt?: 0)
      optional(:after).maybe(:integer, gteq?: 0)
    end

    extend ClosedRecord

    attribute :after, Types::Coercible::Integer.constrained(gteq: 0).optional.default(nil)
    attribute :every, Types::Coercible::Integer.constrained(gt: 0)
    attribute :text, Types::String

    def due?(turns)
      first = after || every
      turns >= first && ((turns - first) % every).zero?
    end
  end
end
