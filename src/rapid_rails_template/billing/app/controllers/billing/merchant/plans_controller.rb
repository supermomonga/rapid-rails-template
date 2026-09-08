# frozen_string_literal: true

module Billing
  module Merchant
    class PlansController < BaseController
      def index
        authorize! merchant_account, to: :view?
        @pagy, @plans = pagy(:offset, merchant_account.plans.order(:id))
      end

      def new
        @plan = merchant_account.plans.new(period_days: 30, chain_ids: [])
        authorize! @plan, to: :create?
      end

      def create
        @plan = merchant_account.plans.new
        authorize! @plan, to: :create?
        save_plan(:new)
      end

      def edit
        @plan = merchant_account.plans.find(params.expect(:id))
        authorize! @plan, to: :manage?
      end

      def update
        @plan = merchant_account.plans.find(params.expect(:id))
        authorize! @plan, to: :manage?
        save_plan(:edit)
      end

      private

      def save_plan(action)
        attributes = params.expect(plan: [:name, :description, :price_usdc, :period_days, :accepting_subscriptions, chain_ids: []])
        if PlanEditor.save(@plan, attributes)
          redirect_to merchant_plans_path, notice: I18n.t('billing.saved')
        else
          render action, status: :unprocessable_content
        end
      end
    end
  end
end
