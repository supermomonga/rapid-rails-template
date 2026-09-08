# frozen_string_literal: true

module Billing
  module Admin
    class SubscriptionsController < BaseController
      def index
        @pagy, @subscriptions = pagy(:offset, Subscription.order(id: :desc))
      end

      def show
        @subscription = Subscription.find(params.expect(:id))
      end
    end
  end
end
