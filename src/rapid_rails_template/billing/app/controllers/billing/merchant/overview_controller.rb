# frozen_string_literal: true

module Billing
  module Merchant
    class OverviewController < BaseController
      def show
        @merchant = merchant_profile
        settled = payments.where(status: "settled")
        @gross_units = settled.sum(:amount_units)
        @fee_units = settled.sum(:operator_units)
        @net_units = settled.sum(:merchant_units)
        @refund_units = RefundRecord.where(charge_id: payments.select(:id)).sum(:amount_units)
        @open_count = sales.where(ended_at: nil).count
        @held_count = payments.where(status: "held").count
        @missing_payouts = Chains::ALL.keys - merchant_profile.payout_addresses.pluck(:chain_id)
      end
    end
  end
end
