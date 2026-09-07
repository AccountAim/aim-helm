# frozen_string_literal: true

module AimHelm
  class Session
    # Messages queued against a session that is already busy. `pending` returns everything
    # appended after the last folded user entry, and `fold` collapses them into one keyed user
    # entry for the next turn, joining messages with a blank line and merging adjacent text
    # blocks.
    class QueuedMessages < Dry::Struct
      attribute :session, Types.Instance(AimHelm::Session)

      def append(content:, type: :message, key: nil, **metadata)
        session.append(
          :queued_message,
          Types::JsonObject[{ type:, content: Message.user(content).content, **metadata }],
          key: key || "message:#{SecureRandom.uuid_v7}",
        )
      end

      def pending(entries: session.entries)
        consumed = entries.filter_map do
          it.payload["covers_through_entry_id"] if it.kind == "user"
        end.max.to_i

        entries.select do
          it.kind == "queued_message" && it.id > consumed
        end
      end

      def fold(run_id:, entries: session.entries)
        messages = pending(entries:)
        return if messages.empty?

        covers_through_entry_id = messages.last.id
        session.append(
          :user,
          {
            content: content_from(messages),
            covers_through_entry_id:,
          },
          key: "messages:#{covers_through_entry_id}",
          run_id:,
        )
      end

      def content(entries: session.entries)
        content_from(pending(entries:))
      end

      private

      def content_from(messages)
        blocks = messages.each_with_object([]) do |entry, content|
          content << { "type" => "text", "text" => "\n\n" } if content.any?
          content.concat(entry.payload.fetch("content"))
        end
        merge_text(blocks)
      end

      def merge_text(blocks)
        blocks.each_with_object([]) do |block, merged|
          if block.fetch("type") == "text" && merged.last&.fetch("type") == "text"
            merged[-1] = {
              "type" => "text",
              "text" => merged.last.fetch("text") + block.fetch("text"),
            }
          else
            merged << block
          end
        end
      end
    end
  end
end
