# frozen_string_literal: true

module Billing
  module Account
    class PlansController < BaseController
      def index
        authorize! merchant_profile, to: :manage?
        @pagy, @plans = pagy(:offset, merchant_profile.plans.order(:id))
      end

      def new
        @plan = merchant_profile.plans.new(seller_kind: "merchant", period_days: 30, chain_ids: [])
        authorize! @plan, to: :create?
      end

      def create
        @plan = merchant_profile.plans.new(seller_kind: "merchant")
        authorize! @plan, to: :create?
        save_plan(:new)
      end

      def edit
        @plan = merchant_profile.plans.find(params.expect(:id))
        authorize! @plan, to: :manage?
      end

      def update
        @plan = merchant_profile.plans.find(params.expect(:id))
        authorize! @plan, to: :manage?
        save_plan(:edit)
      end

      private
        def save_plan(action)
          attributes = params.expect(plan: [:name, :description, :price_usdc, :period_days, :accepting_subscriptions, chain_ids: []])
          if PlanEditor.save(@plan, attributes)
            redirect_to account_plans_path, notice: I18n.t("billing.saved")
          else
            render action, status: :unprocessable_content
          end
        end
    end
  end
end
