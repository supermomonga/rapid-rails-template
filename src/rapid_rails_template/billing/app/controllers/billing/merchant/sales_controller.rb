# frozen_string_literal: true

module Billing
  module Merchant
    class SalesController < BaseController
      def index
        authorize! merchant_account, to: :view?
        @pagy, @subscriptions = pagy(:offset, filter_records(sales).order(id: :desc))
      end

      def show
        @subscription = sales.find(params.expect(:id))
        authorize! @subscription, to: :seller?
        @pagy, @charges = pagy(:offset, @subscription.charges.includes(:transactions, :refund_records).order(period_index: :desc))
      end

      private

      def sales
        Subscription.where(plan_id: merchant_account.plans.select(:id))
      end
    end
  end
end
