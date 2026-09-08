# frozen_string_literal: true

module Billing
  module Admin
    class SubscriptionsController < BaseController
      def index
        @pagy, @subscriptions = pagy(:offset, Subscription.order(id: :desc))
      end

      def show
        @subscription = Subscription.find(params.expect(:id))
        @pagy, @charges = pagy(:offset, @subscription.charges.includes(:transactions, :refund_records).order(period_index: :desc))
      end
    end
  end
end
