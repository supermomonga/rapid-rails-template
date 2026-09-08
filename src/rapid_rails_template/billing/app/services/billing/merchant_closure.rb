# frozen_string_literal: true

module Billing
  module MerchantClosure
    def self.start!(merchant:, actor:, now: Time.current)
      MerchantAccess.synchronize(merchant) do
        MerchantAccess.authorize!(actor, merchant, :manage)
        raise Error, 'merchant is not active' unless merchant.status == 'active'

        Current.set(actor: actor) do
          merchant.update!(status: 'closing')
          merchant.plans.where(accepting_subscriptions: true).find_each { |plan| plan.update!(accepting_subscriptions: false) }
          Subscription.where(plan_id: merchant.plans.select(:id), ended_at: nil).order(:id).find_each do |subscription|
            Cancellation.request!(subscription, now: now)
          end
        end
      end
      ReconcileJob.perform_later
    end

    def self.complete!(merchant, now: Time.current)
      MerchantAccess.synchronize(merchant) do
        return unless merchant.status == 'closing' && !merchant.outstanding?(at: now)

        Current.set(actor: nil) { merchant.update!(status: 'closed', closed_at: now) }
      end
    end
  end
end
