# frozen_string_literal: true

module Billing
  module Merchant
    class BaseController < Billing::ApplicationController
      layout 'billing/merchant'
      before_action :authenticate_user!
      before_action :require_merchant_account
      helper_method :merchant_account, :merchant_editable?, :merchant_manageable?

      def default_url_options
        super.merge(merchant_id: params[:merchant_id])
      end

      private

      def merchant_account
        @merchant_account ||= MerchantAccess.accounts(current_user).find_by!(public_id: params.expect(:merchant_id))
      end

      def require_merchant_account
        authorize! merchant_account, to: :view?
      end

      def merchant_editable?
        params[:merchant_id].present? && MerchantAccess.allowed?(current_user, merchant_account, :edit)
      end

      def merchant_manageable?
        params[:merchant_id].present? && MerchantAccess.allowed?(current_user, merchant_account, :manage)
      end

      def sales
        Subscription.where(plan_id: merchant_account.plans.select(:id))
      end

      def payments
        Charge.where(subscription_id: sales.select(:id))
      end

      def filter_records(records)
        if params[:chain_id].present?
          records = records.where(chain_id: selected_chain)
        end
        if params[:status].present?
          raise ActionController::BadRequest unless %w(pending active cancelling ended).include?(params[:status])

          records = records.where(status: params[:status])
        end
        records
      end

      def selected_chain
        raise ActionController::BadRequest unless params[:chain_id].is_a?(String)

        chain = Integer(params[:chain_id], 10)
        raise ActionController::BadRequest unless Chains::ALL.key?(chain)

        chain
      rescue ArgumentError
        raise ActionController::BadRequest
      end
    end
  end
end
