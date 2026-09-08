# frozen_string_literal: true

module Billing
  module Merchant
    class MerchantProfilesController < BaseController
      skip_before_action :require_merchant_profile, only: %i[new create]
      def new
        return redirect_to edit_merchant_profile_path if T.must(current_user).merchant_profile

        @merchant = MerchantProfile.new(user: current_user)
        authorize! @merchant, to: :manage?
      end

      def create
        return redirect_to edit_merchant_profile_path if T.must(current_user).merchant_profile&.persisted?

        @merchant = MerchantProfile.new(profile_params.merge(user: current_user))
        authorize! @merchant, to: :manage?
        if @merchant.save
          redirect_to merchant_root_path, notice: I18n.t("billing.saved")
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
          redirect_to edit_merchant_profile_path, notice: I18n.t("billing.saved")
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
