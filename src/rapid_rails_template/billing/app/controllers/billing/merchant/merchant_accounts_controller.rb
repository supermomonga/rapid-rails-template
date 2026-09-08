# frozen_string_literal: true

module Billing
  module Merchant
    class MerchantAccountsController < BaseController
      skip_before_action :require_merchant_account, only: %i[new create]
      def new
        @merchant = MerchantAccount.new(creator: current_user)
        authorize! @merchant, to: :create?
      end

      def create
        @merchant = MerchantAccount.new(profile_params.merge(creator: current_user))
        authorize! @merchant, to: :create?
        if @merchant.save
          T.must(current_user).update!(last_billing_merchant: @merchant)
          redirect_to merchant_dashboard_path(merchant_id: @merchant.public_id), notice: I18n.t('billing.saved')
        else
          render :new, status: :unprocessable_content
        end
      end

      def edit
        @merchant = merchant_account
        authorize! @merchant, to: :view?
      end

      def update
        @merchant = merchant_account
        authorize! @merchant, to: :edit?
        if @merchant.update(profile_params)
          redirect_to edit_merchant_profile_path(merchant_id: @merchant.public_id), notice: I18n.t('billing.saved')
        else
          render :edit, status: :unprocessable_content
        end
      end

      private

      def profile_params
        params.expect(merchant_account: %i[public_id display_name introduction image_upload])
      end
    end
  end
end
