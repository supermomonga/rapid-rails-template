# frozen_string_literal: true

module Billing
  class Subscription < ApplicationRecord
    belongs_to :user, class_name: '::User', optional: true
    belongs_to :plan
    has_many :charges, dependent: :restrict_with_error
    has_many :transactions, class_name: 'Billing::Transaction', dependent: :restrict_with_error
    attr_readonly :plan_id, :chain_id, :payer_address, :amount_units, :period_seconds, :starts_at, :permission, :permission_hash
    validates :status, inclusion: { in: %w(pending active cancelling ended) }
    around_create :start_subscription

    def period_index(at)
      [(at.to_i - starts_at.to_i) / period_seconds, 0].max
    end

    def usable?(at: Time.current)
      first, last = paid_from, paid_until
      return false unless first && last && at >= first
      return true if at < last
      return false if cancel_requested_at || ended_at

      at < last + Setting.current.grace_hours.hours
    end

    def unresolved_transactions?
      transactions.exists?(finalized_at: nil)
    end

    private

    def start_subscription
      merchant = T.must(T.must(plan).merchant_account)
      MerchantAccess.synchronize(merchant) do
        unless merchant.status == 'active' && T.must(plan).reload.accepting_subscriptions? && Setting.current.payments_enabled?
          raise ConfigurationError, 'billing unavailable'
        end
        yield
      end
    end
  end
end
