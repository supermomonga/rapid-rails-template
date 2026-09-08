# frozen_string_literal: true

module Billing
  module PlanEditor
    def self.save(plan, attributes)
      values = attributes.to_h.symbolize_keys
      price = values.delete(:price_usdc)
      values[:amount_units] = Amount.parse(price) if price
      values[:chain_ids] = Array(values.fetch(:chain_ids, [])).compact_blank.map { |id| Integer(id) }
      Setting.current.with_lock do
        plan.assign_attributes(values)
        plan.save
      end
    rescue ArgumentError
      plan.errors.add(:amount_units, :invalid)
      false
    end
  end
end
