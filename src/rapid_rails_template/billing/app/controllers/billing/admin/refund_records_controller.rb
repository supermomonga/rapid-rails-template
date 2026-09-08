# frozen_string_literal: true

module Billing
  module Admin
    class RefundRecordsController < BaseController
      def new
        load_charge
        @refund = @charge.refund_records.new(chain_id: @charge.subscription.chain_id)
      end

      def create
        load_charge
        attributes = params.expect(refund_record: %i[amount_usdc reason chain_id transaction_hash]).to_h
        @refund = @charge.refund_records.new(attributes.except("amount_usdc"))
        @refund.amount_units = Amount.parse(attributes.fetch("amount_usdc"))
        @refund.save!
        redirect_to admin_subscription_path(@charge.subscription, tab: "payments"), notice: I18n.t("billing.refund_recorded")
      rescue ActiveRecord::RecordInvalid
        render :new, status: :unprocessable_content
      rescue ArgumentError
        @refund.errors.add(:amount_units, :invalid)
        render :new, status: :unprocessable_content
      end

      private
        def load_charge
          @charge = Charge.find(params.expect(:charge_id))
          authorize! @charge, to: :manage?
          raise ActiveRecord::RecordNotFound unless @charge.status == "settled"
        end
    end
  end
end
