# frozen_string_literal: true

module Billing
  class PayoutAddress < ApplicationRecord
    include MerchantRecord

    self.audit_fields = %w(chain_id address)
    belongs_to :merchant_account
    attr_readonly :merchant_account_id, :chain_id
    validates :chain_id, inclusion: { in: Chains::ALL.keys }, uniqueness: { scope: :merchant_account_id }
    validate :valid_address

    private

    def billing_permission
      :manage
    end

    def valid_address
      errors.add(:address, :invalid) unless Chains.address?(address)
      setting = ChainSetting.find_by(chain_id: chain_id)
      if setting && [setting.collector_address, setting.executor_address].compact.map(&:downcase).include?(address.to_s.downcase)
        errors.add(:address, :billing_separate_treasury)
      end
    end
  end
end
