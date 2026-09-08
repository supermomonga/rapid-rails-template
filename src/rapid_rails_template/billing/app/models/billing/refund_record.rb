# frozen_string_literal: true

module Billing
  class RefundRecord < ApplicationRecord
    belongs_to :charge
    validates :amount_units, numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: 2**63 - 1 }
    validates :reason, presence: true, length: { maximum: 5000 }
    validates :chain_id, inclusion: { in: Chains::ALL.keys }
    validate :valid_transaction_hash

    def explorer_url
      Chains.fetch(chain_id).explorer + transaction_hash
    end

    private
      def valid_transaction_hash
        errors.add(:transaction_hash, :invalid) unless Chains.hash?(transaction_hash)
        errors.add(:charge, :invalid) unless charge&.status == "settled"
      end
  end
end
