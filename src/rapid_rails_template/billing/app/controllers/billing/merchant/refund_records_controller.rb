# frozen_string_literal: true

module Billing
  module Merchant
    class RefundRecordsController < BaseController
      def index
        records = RefundRecord.where(charge_id: payments.select(:id))
        records = records.where(chain_id: selected_chain) if params[:chain_id].present?
        @pagy, @refunds = pagy(:offset, records.includes(charge: :subscription).order(id: :desc))
      end

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
        redirect_to merchant_sale_path(@charge.subscription, tab: "payments"), notice: I18n.t("billing.refund_recorded")
      rescue ActiveRecord::RecordInvalid
        render :new, status: :unprocessable_content
      rescue ArgumentError
        @refund.errors.add(:amount_units, :invalid)
        render :new, status: :unprocessable_content
      end

      private
        def load_charge
          @charge = Charge.where(subscription_id: sales.select(:id)).find(params.expect(:charge_id))
          authorize! @charge, to: :manage?
          raise ActiveRecord::RecordNotFound unless @charge.status == "settled"
        end
    end
  end
end
