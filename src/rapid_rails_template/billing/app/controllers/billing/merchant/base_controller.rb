# frozen_string_literal: true

module Billing
  module Merchant
    class BaseController < Billing::ApplicationController
      layout "billing/merchant"
      before_action :authenticate_user!
      before_action :require_merchant_profile

      private
        def merchant_profile
          @merchant_profile ||= MerchantProfile.find_by!(user_id: T.must(current_user).id)
        end

        def require_merchant_profile
          return redirect_to new_merchant_profile_path unless T.must(current_user).merchant_profile

          authorize! merchant_profile, to: :manage?
        end

        def sales
          Subscription.where(plan_id: merchant_profile.plans.select(:id))
        end

        def payments
          Charge.where(subscription_id: sales.select(:id))
        end

        def filter_records(records)
          if params[:chain_id].present?
            records = records.where(chain_id: selected_chain)
          end
          if params[:status].present?
            raise ActionController::BadRequest unless %w[pending active cancelling ended].include?(params[:status])

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
