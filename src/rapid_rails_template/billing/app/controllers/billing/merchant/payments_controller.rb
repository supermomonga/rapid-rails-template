# frozen_string_literal: true

module Billing
  module Merchant
    class PaymentsController < BaseController
      def index
        records = payments.where(subscription_id: filter_records(sales).select(:id))
        @pagy, @charges = pagy(:offset, records.includes(:subscription, :transactions, :refund_records).order(id: :desc))
      end
    end
  end
end
