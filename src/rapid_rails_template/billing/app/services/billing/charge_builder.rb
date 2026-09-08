# frozen_string_literal: true

module Billing
  class ChargeBuilder
    def self.call(subscription, now: Time.current)
      settings = Setting.current
      settings.with_lock do
        subscription.lock!
        return if subscription.ended_at || subscription.cancel_requested_at || subscription.signature.blank?
        return unless settings.enabled_for?(subscription.seller_kind)
        return if subscription.unresolved_transactions?
        return if subscription.paid_until && now < subscription.paid_until

        due_at = subscription.paid_until || subscription.starts_at
        deadline = subscription.paid_until ? due_at + settings.grace_hours.hours : due_at + subscription.period_seconds
        return if now < due_at || now >= deadline

        index = subscription.period_index(due_at)
        existing = subscription.charges.find_by(period_index: index)
        return existing if existing

        chain = ChainSetting.for_chain(subscription.chain_id)
        raise ConfigurationError, "billing chain setup incomplete" unless chain.ready?

        if subscription.seller_kind == "merchant"
          fee, merchant = Amount.split(subscription.amount_units, settings.fee_basis_points)
          destination = subscription.plan.merchant_profile.payout_addresses.find_by!(chain_id: subscription.chain_id).address
        else
          fee, merchant, destination = subscription.amount_units, 0, nil
        end
        subscription.charges.create!(period_index: index,
          period_start: subscription.starts_at + index * subscription.period_seconds,
          period_end: subscription.starts_at + (index + 1) * subscription.period_seconds,
          amount_units: subscription.amount_units, operator_units: fee, merchant_units: merchant,
          fee_basis_points: subscription.seller_kind == "merchant" ? settings.fee_basis_points : 0,
          operator_address: chain.treasury_address, merchant_address: destination)
      end
    end
  end
end
