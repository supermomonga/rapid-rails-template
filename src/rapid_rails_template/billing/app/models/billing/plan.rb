# frozen_string_literal: true

module Billing
  class Plan < ApplicationRecord
    belongs_to :merchant_profile, optional: true
    has_many :subscriptions, dependent: :restrict_with_error
    attr_readonly :seller_kind, :merchant_profile_id
    validates :seller_kind, inclusion: { in: %w[operator merchant] }
    validates :name, presence: true, length: { maximum: 150 }
    validates :description, length: { maximum: 10_000 }
    validates :amount_units, numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: 2**63 - 1 }
    validates :period_days, numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: 36_500 }
    validate :valid_terms
    validate :creation_enabled, on: :create

    def seller_name
      seller_kind == "operator" ? I18n.t("billing.operator") : T.must(merchant_profile).display_name
    end

    def available_on?(chain_id, env: ENV)
      merchant = merchant_profile
      accepting_subscriptions? && chain_ids.include?(chain_id) && Setting.current.enabled_for?(seller_kind) &&
        ChainSetting.for_chain(chain_id).ready? && ConfigurationStatus.credentials_present?(chain_id, env: env) &&
        (seller_kind == "operator" || merchant && merchant.user_id.present? && merchant.payout_addresses.exists?(chain_id: chain_id))
    end

    private
      def valid_terms
        errors.add(:merchant_profile, :invalid) unless (seller_kind == "merchant") == merchant_profile.present?
        unless chain_ids.is_a?(Array) && chain_ids.any? && chain_ids.uniq == chain_ids && (chain_ids - Chains::ALL.keys).empty?
          errors.add(:chain_ids, :invalid)
        end
        if accepting_subscriptions? && period_days.is_a?(Integer) && period_days * 24 <= Setting.current.grace_hours
          errors.add(:period_days, :billing_period)
        end
      end

      def creation_enabled
        if seller_kind == "merchant" && !Setting.current.merchant_plan_creation_enabled?
          errors.add(:base, :billing_creation_disabled)
        end
      end
  end
end
