# frozen_string_literal: true

module Billing
  module Account
    class RefundRecordsController < BaseController
      def create
        charge = Charge.joins(:subscription).where(billing_subscriptions: { plan_id: merchant_profile.plans.select(:id) }).find(params.expect(:charge_id))
        authorize! charge, to: :manage?
        attributes = params.expect(refund_record: %i[amount_usdc reason chain_id transaction_hash]).to_h
        attributes["amount_units"] = Amount.parse(attributes.delete("amount_usdc"))
        charge.refund_records.create!(attributes)
        redirect_to account_sale_path(charge.subscription), notice: I18n.t("billing.refund_recorded")
      rescue ActiveRecord::RecordInvalid, ArgumentError
        render plain: I18n.t("billing.errors.invalid"), status: :unprocessable_content
      end
    end
  end
end
