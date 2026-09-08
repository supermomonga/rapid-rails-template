# frozen_string_literal: true

module Billing
  class Plan < ApplicationRecord
    include MerchantRecord

    self.audit_fields = %w(name description amount_units period_days chain_ids accepting_subscriptions)
    belongs_to :merchant_account
    has_many :subscriptions, dependent: :restrict_with_error
    attr_readonly :merchant_account_id
    validates :name, presence: true, length: { maximum: 150 }
    validates :description, length: { maximum: 10_000 }
    validates :amount_units, numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: (2**63) - 1 }
    validates :period_days, numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: 36_500 }
    validate :valid_terms
    validate :creation_enabled, on: :create
    validate :merchant_is_immutable, on: :update

    def seller_name
      T.must(merchant_account).display_name
    end

    def available_on?(chain_id, env: ENV)
      merchant = T.must(merchant_account)
      accepting_subscriptions? && merchant.status == 'active' && chain_ids.include?(chain_id) && Setting.current.payments_enabled? &&
        ChainSetting.for_chain(chain_id).ready? && ConfigurationStatus.credentials_present?(chain_id, env: env) &&
        merchant.payout_addresses.exists?(chain_id: chain_id)
    end

    private

    def merchant_is_immutable
      errors.add(:merchant_account, :invalid) if will_save_change_to_merchant_account_id?
    end

    def valid_terms
      errors.add(:accepting_subscriptions, :invalid) if accepting_subscriptions? && merchant_account&.status != 'active'
      unless chain_ids.is_a?(Array) && chain_ids.any? && chain_ids.uniq == chain_ids && (chain_ids - Chains::ALL.keys).empty?
        errors.add(:chain_ids, :invalid)
      end
      if accepting_subscriptions? && period_days.is_a?(Integer) && period_days * 24 <= Setting.current.grace_hours
        errors.add(:period_days, :billing_period)
      end
    end

    def creation_enabled
      if !Setting.current.merchant_plan_creation_enabled? || merchant_account&.status != 'active'
        errors.add(:base, :billing_creation_disabled)
      end
    end
  end
end
