# frozen_string_literal: true

module AimHelm
  module Stores
    class ActiveRecord
      # Session-row locking for the host model. `hold_lease` claims the row with one conditional
      # update — unheld or expired leases only — and `interrupted?` reports a running session
      # whose holder stopped heartbeating.
      module Leaseable
        LEASE_TTL = 90.seconds

        def hold_lease(claimed_by:, now: Time.current, ttl: LEASE_TTL)
          token = SecureRandom.uuid_v7
          acquired = available_lease(now, ttl).update_all(
            claimed_by:,
            lease_token: token,
            heartbeat_at: now,
            updated_at: now,
          )
          # The token represents ownership only after this session row wins the atomic update.
          return unless acquired == 1

          Lease.new(session: self, token:, claimed_by:)
        end

        def interrupted?(status: self.status, now: Time.current, ttl: LEASE_TTL)
          status.to_sym == :running && (heartbeat_at.nil? || heartbeat_at < now - ttl)
        end

        private

        def available_lease(now, ttl)
          self.class.where(id:).where("lease_token IS NULL OR heartbeat_at < ?", now - ttl)
        end
      end
    end
  end
end
