# frozen_string_literal: true

module Billing
  class ChainSetting < ApplicationRecord
    has_many :transactions, class_name: "Billing::Transaction", dependent: :restrict_with_error
    validates :chain_id, inclusion: { in: Chains::ALL.keys }
    validate :valid_addresses_and_ceiling

    def self.for_chain(chain_id)
      Chains.fetch(chain_id)
      find_by(chain_id: chain_id) || create_or_find_by!(chain_id: chain_id)
    end

    def ready?
      treasury_address.present? && collector_address.present? && executor_address.present? && gas_ceiling_wei.present? && verified_at.present?
    end

    private
      def valid_addresses_and_ceiling
        %i[treasury_address collector_address executor_address].each do |attribute|
          value = public_send(attribute)
          errors.add(attribute, :invalid) if value.present? && !Chains.address?(value)
        end
        ceiling, treasury = gas_ceiling_wei, treasury_address
        if ceiling.present? && (!ceiling.match?(/\A[1-9]\d*\z/) || ceiling.to_i > (1 << 63) - 1)
          errors.add(:gas_ceiling_wei, :invalid)
        end
        if treasury.present? && [collector_address, executor_address].compact.map(&:downcase).include?(treasury.downcase)
          errors.add(:treasury_address, :billing_separate_treasury)
        end
      end
  end
end
