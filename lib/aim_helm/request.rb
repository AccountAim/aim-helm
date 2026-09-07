# frozen_string_literal: true

module AimHelm
  # Builds one provider request from the session log: replayed messages, system prompt, tool
  # specs, and output schema. Due reminders are appended as a trailing `<system-reminder>` user
  # message, with the turn count taken from assistant messages in the replay. Runner memoizes one
  # and calls it per iteration.
  class Request < Dry::Struct
    attribute :output_schema, Types::JsonSchema.optional.default(nil)
    attribute :reminders,
              Types::Array.of(Types.Instance(Reminder)).default([].freeze)
    attribute :system, Types::String.optional.default(nil)
    attribute :tools, Types::Array.of(Types.Interface(:spec)).default([].freeze)

    def call(entries:)
      messages = Replay.messages(entries)
      {
        system:,
        messages: with_reminders(messages),
        tools: tools.map(&:spec),
        output_schema:,
      }
    end

    private

    def with_reminders(messages)
      turns = messages.count {  it.role == :assistant }
      due = reminders.select {  it.due?(turns) }
      return messages if due.empty?

      body = "<system-reminder>\n#{due.map(&:text).join("\n\n")}\n</system-reminder>"
      Replay.merge_users([*messages, Message.user(body)])
    end
  end
end
