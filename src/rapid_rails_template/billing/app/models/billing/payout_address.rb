# frozen_string_literal: true

module Billing
  class PayoutAddress < ApplicationRecord
    belongs_to :merchant_profile
    validates :chain_id, inclusion: { in: Chains::ALL.keys }, uniqueness: { scope: :merchant_profile_id }
    validate :valid_address

    private
      def valid_address
        errors.add(:address, :invalid) unless Chains.address?(address)
        setting = ChainSetting.find_by(chain_id: chain_id)
        if setting && [setting.collector_address, setting.executor_address].compact.map(&:downcase).include?(address.to_s.downcase)
          errors.add(:address, :billing_separate_treasury)
        end
      end
  end
end
