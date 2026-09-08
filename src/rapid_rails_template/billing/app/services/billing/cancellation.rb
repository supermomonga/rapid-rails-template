# frozen_string_literal: true

module Billing
  module Cancellation
    def self.request!(subscription, now: Time.current)
      MerchantAccess.synchronize(subscription.plan.merchant_account) do
        subscription.lock!
        return if subscription.ended_at || subscription.cancel_requested_at

        subscription.update!(cancel_requested_at: now, status: 'cancelling')
        subscription.charges.where(status: %w(pending held)).find_each do |charge|
          charge.update!(status: 'cancelled') unless charge.transactions.exists?(finalized_at: nil)
        end
      end
      ReconcileJob.perform_later
    end
  end
end
