# frozen_string_literal: true

module Billing
  module Account
    class MerchantProfilesController < BaseController
      def new
        @merchant = MerchantProfile.new(user: current_user)
        authorize! @merchant, to: :manage?
      end

      def create
        @merchant = MerchantProfile.new(profile_params.merge(user: current_user))
        authorize! @merchant, to: :manage?
        if @merchant.save
          redirect_to edit_account_merchant_profile_path, notice: I18n.t("billing.saved")
        else
          render :new, status: :unprocessable_content
        end
      end

      def edit
        @merchant = merchant_profile
        authorize! @merchant, to: :manage?
      end

      def update
        @merchant = merchant_profile
        authorize! @merchant, to: :manage?
        if @merchant.update(profile_params)
          redirect_to edit_account_merchant_profile_path, notice: I18n.t("billing.saved")
        else
          render :edit, status: :unprocessable_content
        end
      end

      private
        def profile_params
          params.expect(merchant_profile: %i[public_id display_name introduction image_upload])
        end
    end
  end
end
