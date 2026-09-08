# frozen_string_literal: true

module Billing
  module Account
    class PayoutAddressesController < BaseController
      def create
        authorize! merchant_profile, to: :manage?
        address = merchant_profile.payout_addresses.new(address_params)
        save_address(address)
      end

      def update
        authorize! merchant_profile, to: :manage?
        address = merchant_profile.payout_addresses.find(params.expect(:id))
        address.assign_attributes(address_params.except(:chain_id))
        save_address(address)
      end

      private
        def address_params
          params.expect(payout_address: %i[chain_id address])
        end

        def save_address(address)
          Setting.current.with_lock { address.save! }
          redirect_to edit_account_merchant_profile_path, notice: I18n.t("billing.saved")
        rescue ActiveRecord::RecordInvalid
          @merchant = merchant_profile
          @payout_errors = address.errors.full_messages
          render "billing/account/merchant_profiles/edit", status: :unprocessable_content
        end
    end
  end
end
