# frozen_string_literal: true

module Billing
  module Account
    class SubscriptionsController < BaseController
      rate_limit to: 10, within: 1.minute, only: :create

      def index
        subscriptions = Subscription.where(user_id: T.must(current_user).id)
        subscriptions = params[:scope] == "ended" ? subscriptions.where.not(ended_at: nil) : subscriptions.where(ended_at: nil)
        @pagy, @subscriptions = pagy(:offset, subscriptions.order(id: :desc))
      end

      def show
        @subscription = own_subscription
        @pagy, @charges = pagy(:offset, @subscription.charges.includes(:transactions, :refund_records).order(period_index: :desc))
      end

      def cancellation
        @subscription = own_subscription
      end

      def create
        input = params.expect(subscription: %i[plan_id chain_id payer_address])
        contract = Checkout.prepare!(user: current_user, plan: Plan.find(input.fetch(:plan_id)),
          chain_id: Integer(input.fetch(:chain_id)), payer_address: input.fetch(:payer_address))
        render json: { id: contract.id, typed_data: Checkout.typed_data(contract), review: Checkout.review(contract),
          authorize_path: authorize_account_subscription_path(contract), subscription_path: account_subscription_path(contract) }, status: :created
      rescue ActiveRecord::RecordNotUnique
        render json: { error: I18n.t("billing.errors.duplicate") }, status: :conflict
      rescue ArgumentError
        render json: { error: I18n.t("billing.errors.invalid") }, status: :unprocessable_content
      rescue RpcError, VerificationError
        billing_unavailable
      end

      def authorize
        contract = own_subscription
        Checkout.authorize!(contract, signature: params.expect(:signature))
        render json: { subscription_path: account_subscription_path(contract) }, status: :accepted
      rescue ArgumentError, Error
        render json: { error: I18n.t("billing.errors.authorization") }, status: :unprocessable_content
      end

      def cancel
        contract = own_subscription
        Cancellation.request!(contract)
        redirect_to account_subscription_path(contract), notice: I18n.t("billing.cancel_requested")
      end

      private
        def own_subscription
          contract = Subscription.where(user_id: T.must(current_user).id).find(params.expect(:id))
          authorize! contract, to: :manage?
          contract
        end
    end
  end
end
