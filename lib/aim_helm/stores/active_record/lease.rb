# frozen_string_literal: true

module AimHelm
  module Stores
    class ActiveRecord
      # A held session lease. Every write is scoped to `token`, so a lease that was stolen or
      # released touches no rows.
      class Lease < Dry::Struct
        attribute :claimed_by, Types::String
        attribute :session, Types.Interface(:id)
        attribute :token, Types::String

        # Mutates despite the `?`: the heartbeat is throttled to one write per interval, so a
        # zero-row update still means the lease is held, and `exists?` separates that from a
        # lost one.
        def heartbeat?(now: Time.current, interval: 30.seconds)
          updated = relation.where("heartbeat_at <= ?", now - interval)
                            .update_all(heartbeat_at: now, updated_at: now)
          updated == 1 || relation.exists?
        end

        def release(now: Time.current)
          update(claimed_by: nil, lease_token: nil, heartbeat_at: nil, updated_at: now) == 1
        end

        private

        def relation = session.class.where(id: session.id, lease_token: token)
        def update(attributes) = relation.update_all(attributes)
      end
    end
  end
end
