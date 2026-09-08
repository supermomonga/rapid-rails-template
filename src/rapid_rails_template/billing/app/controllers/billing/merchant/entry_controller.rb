# frozen_string_literal: true

module Billing
  module Merchant
    class EntryController < BaseController
      skip_before_action :require_merchant_account

      def show
        accounts = MerchantAccess.accounts(current_user)
        available = accounts.where.not(status: 'closed')
        selected = available.find_by(id: T.must(current_user).last_billing_merchant_id) || available.order(updated_at: :desc, id: :desc).first
        if selected
          T.must(current_user).update!(last_billing_merchant: selected)
          redirect_to merchant_dashboard_path(merchant_id: selected.public_id)
        else
          @closed_merchants = accounts.where(status: 'closed').order(updated_at: :desc, id: :desc)
        end
      end

      def select
        selected = MerchantAccess.accounts(current_user).find_by!(public_id: params.expect(:selected_merchant_id))
        T.must(current_user).update!(last_billing_merchant: selected)
        redirect_to merchant_dashboard_path(merchant_id: selected.public_id)
      end
    end
  end
end
