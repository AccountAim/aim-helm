# frozen_string_literal: true

module AimHelm
  # Policy for summarizing a long transcript: `threshold` is the fraction of the model's context
  # window at which Compaction::Runner compacts, and `model`/`system` override the summarizer
  # defaults.
  class Compaction < Dry::Struct
    DEFAULT_SYSTEM = <<~TEXT.strip.freeze
      Summarize this agent transcript for a later continuation. Preserve decisions, constraints,
      unresolved work, tool outcomes, and identifiers needed to continue accurately.
    TEXT

    CONTRACT = Schema.define do
      optional(:model).maybe(:string)
      optional(:threshold).value(:float, gt?: 0, lteq?: 1)
      optional(:system).maybe(:string)
    end

    extend ClosedRecord

    attribute :model, Types::String.optional.default(nil)
    attribute :system, Types::String.optional.default(nil)
    attribute :threshold,
              Types::Coercible::Float.constrained(gt: 0, lteq: 1).default(0.8)

    def model_for(default) = model || default
    def system_prompt = system || DEFAULT_SYSTEM
  end
end
