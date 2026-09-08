# frozen_string_literal: true

module Billing
  module Account
    class SalesController < BaseController
      def index
        authorize! merchant_profile, to: :manage?
        @pagy, @subscriptions = pagy(:offset, sales.order(id: :desc))
      end

      def show
        @subscription = sales.find(params.expect(:id))
        authorize! @subscription, to: :seller?
      end

      private
        def sales
          Subscription.where(plan_id: merchant_profile.plans.select(:id))
        end
    end
  end
end
