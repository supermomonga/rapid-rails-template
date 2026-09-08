# frozen_string_literal: true

module Billing
  module Admin
    class PlansController < BaseController
      def index
        @pagy, @plans = pagy(:offset, Plan.where(seller_kind: "operator").order(:id))
      end

      def new
        @plan = Plan.new(seller_kind: "operator", period_days: 30, chain_ids: [])
        authorize! @plan, to: :create?
      end

      def create
        @plan = Plan.new(seller_kind: "operator")
        authorize! @plan, to: :create?
        save_plan(:new)
      end

      def edit
        @plan = Plan.where(seller_kind: "operator").find(params.expect(:id))
        authorize! @plan, to: :manage?
      end

      def update
        @plan = Plan.where(seller_kind: "operator").find(params.expect(:id))
        authorize! @plan, to: :manage?
        save_plan(:edit)
      end

      private
        def save_plan(action)
          attributes = params.expect(plan: [:name, :description, :price_usdc, :period_days, :accepting_subscriptions, chain_ids: []])
          if PlanEditor.save(@plan, attributes)
            redirect_to admin_plans_path, notice: I18n.t("billing.saved")
          else
            render action, status: :unprocessable_content
          end
        end
    end
  end
end
