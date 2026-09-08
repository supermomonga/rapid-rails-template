# frozen_string_literal: true

module Billing
  module Merchant
    class PayoutAddressesController < BaseController
      def index
        @merchant = merchant_account
      end

      def create
        authorize! merchant_account, to: :manage?
        address = merchant_account.payout_addresses.new(address_params)
        save_address(address)
      end

      def update
        authorize! merchant_account, to: :manage?
        address = merchant_account.payout_addresses.find(params.expect(:id))
        address.assign_attributes(address_params.except(:chain_id))
        save_address(address)
      end

      private

      def address_params
        params.expect(payout_address: %i[chain_id address])
      end

      def save_address(address)
        Setting.current.with_lock { address.save! }
        redirect_to merchant_payout_addresses_path, notice: I18n.t('billing.saved')
      rescue ActiveRecord::RecordInvalid
        @merchant = merchant_account
        @payout_errors = address.errors.full_messages
        @invalid_payout = address
        render :index, status: :unprocessable_content
      end
    end
  end
end
