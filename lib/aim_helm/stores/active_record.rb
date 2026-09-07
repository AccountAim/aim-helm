# frozen_string_literal: true

module AimHelm
  module Stores
    # Durable session store backed by a host Active Record model, installed through
    # `Config::Builder#session_model=`. Never loaded unless the host has Active Record:
    # `lib/aim_helm.rb` ignores this path in the gem loader and requires it only under Rails with
    # `ActiveRecord::Base` defined.
    class ActiveRecord < Dry::Struct
      # Names the host's partial unique index on (session_id, key); entry inserts dedupe on it.
      KEY_INDEX = :index_agent_session_entries_on_session_id_and_key
      STALE_AFTER = 5.minutes

      attribute :key_index, Types::Coercible::Symbol.default(KEY_INDEX)
      attribute :session_model, Types.Instance(Class)

      # Construction mutates the host model: Leaseable lands on it so `bind` can lease its rows.
      def initialize(...)
        super
        session_model.include(Leaseable) unless session_model < Leaseable
      end

      def append(session_id, kind, payload, key: nil, run_id: nil, turn_id: nil)
        append_in_transaction(
          session_id:,
          kind: kind.to_s,
          payload:,
          key:,
          run_id:,
          turn_id:,
          created_at: Time.current,
        )
      end

      def entries(session_id, after_id: nil)
        # Uncached: a turn appends entries mid-request and must read back its own writes.
        entry_model.uncached do
          scope = entry_model.where(session_id:)
          scope = scope.where("id > ?", after_id) if after_id
          scope.order(:id).map {  build_entry(it) }
        end
      end

      def transaction(&) = session_model.transaction(&)
      def record(id) = session_model.find(id)
      def context(id) = record(id).aim_helm_context
      def subagent?(id) = record(id).parent_session_id.present?
      def subagent_host = SubagentHost.new(store: self)

      def create_session(context:, id: nil, parent: nil, name: nil)
        session_model.aim_helm_create!(context:, id:, parent:, name:)
      end

      def bind(session:, claimed_by:, final_attempt:, config:)
        record = record(session.id)
        lease = record.hold_lease(claimed_by:) or return
        context = record.aim_helm_context
        spawn_record = Subagents::Record.latest(session.entries) if record.parent_session_id
        verifier = Verifier.new(store: self, record:, session:, spawn_record:) if spawn_record
        authorization = if config.authorize
                          Authorization.new(callback: config.authorize, context:)
                        end

        Execution::Binding.new(
          session:,
          lease:,
          context:,
          authorize: authorization || Tools::Batch::NO_AUTHORIZATION,
          on_interrupted_tool: Subagents::Reaper.new(parent: session),
          subagent_host: config.subagent_host || subagent_host,
          subagent_record: spawn_record,
          verifier:,
          final_attempt:,
        )
      end

      def interrupted?(id, status:, now: Time.current)
        record(id).interrupted?(status:, now:)
      end

      def stale_session_ids(now: Time.current)
        cutoff = now - STALE_AFTER
        running = session_model.where(status: :running)
                               .where("heartbeat_at IS NULL OR heartbeat_at < ?", cutoff)
        queued = session_model.where(status: :queued).where(updated_at: ...cutoff)

        running.or(queued).filter_map do
          # An inline subagent is driven by its parent's turn; the parent's own sweep reruns it.
          it.id unless inline_subagent?(it)
        end
      end

      def terminal_subagent_ids
        terminal_subagents.pluck(:id)
      end

      def terminal_subagents
        terminal_ids = entry_model.where(kind: "terminal").select(:session_id)
        session_model.where.not(parent_session_id: nil).where(id: terminal_ids)
      end

      def entry_model
        session_model.reflect_on_association(:entries)&.klass || raise(
          ConfigurationError,
          "#{session_model.name} must define an entries association",
        )
      end

      private

      def append_in_transaction(attributes)
        session_model.transaction do
          record = insert(attributes)
          next unless record

          entry = build_entry(record)
          update_status(attributes.fetch(:session_id), attributes.fetch(:created_at))
          entry
        end
      end

      def insert(attributes)
        # A key conflict returns no row — the entry already exists and the append is a no-op.
        inserted = entry_model.insert_all(
          [attributes],
          unique_by: key_index,
          returning: %w[id],
        )
        entry_model.find(inserted.rows.first.fetch(0)) unless inserted.rows.empty?
      end

      def build_entry(record)
        Session::Record.new(
          id: record.id,
          session_id: record.session_id,
          kind: record.kind,
          payload: record.payload,
          key: record.key,
          run_id: record.run_id,
          turn_id: record.turn_id,
          created_at: record.created_at,
        )
      end

      def update_status(session_id, now)
        status = Session.status_from(entries(session_id))
        session_model.where(id: session_id).update_all(status: status.to_s, updated_at: now)
      end

      def inline_subagent?(record)
        return false unless record.parent_session_id

        session = Session.new(store: self, id: record.id.to_s)
        Subagents::Record.latest(session.entries).mode == :inline
      end
    end
  end
end

# The gem loader ignores this subtree, so it gets its own loader once required.
loader = Zeitwerk::Loader.new
loader.tag = "aim_helm-active-record"
loader.push_dir(
  File.expand_path("active_record", __dir__),
  namespace: AimHelm::Stores::ActiveRecord,
)
loader.setup
