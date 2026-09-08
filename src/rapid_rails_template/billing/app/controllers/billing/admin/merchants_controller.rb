# frozen_string_literal: true

module Billing
  module Admin
    class MerchantsController < BaseController
      def index
        @pagy, @merchants = pagy(:offset, MerchantAccount.order(id: :desc))
      end

      def show
        @merchant = MerchantAccount.find_by!(public_id: params.expect(:id))
        @pagy, @subscriptions = pagy(:offset, Subscription.where(plan_id: @merchant.plans.select(:id)).order(id: :desc))
      end

      def update
        @merchant = MerchantAccount.find_by!(public_id: params.expect(:id))
        value = params.expect(merchant_account: [:fee_percent])[:fee_percent]
        @merchant.update!(fee_basis_points: value.blank? ? nil : Amount.parse(value, decimals: 2))
        redirect_to admin_merchant_path(@merchant), notice: I18n.t('billing.saved')
      rescue ArgumentError, ActiveRecord::RecordInvalid
        redirect_to admin_merchant_path(@merchant), alert: I18n.t('billing.errors.fee')
      end
    end
  end
end
