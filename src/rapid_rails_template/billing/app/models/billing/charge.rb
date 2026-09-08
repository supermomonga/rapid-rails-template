# frozen_string_literal: true

module Billing
  class Charge < ApplicationRecord
    belongs_to :subscription
    has_many :transactions, class_name: "Billing::Transaction", dependent: :restrict_with_error
    has_many :refund_records, dependent: :restrict_with_error
    validates :status, inclusion: { in: %w[pending submitted settled cancelled held] }
    attr_readonly :subscription_id, :period_index, :period_start, :period_end, :amount_units, :operator_units, :merchant_units, :fee_basis_points, :operator_address, :merchant_address
  end
end
