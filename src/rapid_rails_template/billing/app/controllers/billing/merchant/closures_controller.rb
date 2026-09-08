# frozen_string_literal: true

module Billing
  module Merchant
    class ClosuresController < BaseController
      def show
        authorize! merchant_account, to: :manage?
      end

      def create
        authorize! merchant_account, to: :manage?
        unless params[:confirmation] == merchant_account.display_name
          return redirect_to merchant_closure_path, alert: I18n.t('billing.errors.confirmation')
        end

        MerchantClosure.start!(merchant: merchant_account, actor: current_user)
        redirect_to merchant_dashboard_path, notice: I18n.t('billing.saved')
      rescue Billing::Error
        redirect_to merchant_dashboard_path, alert: I18n.t('billing.errors.closure')
      end
    end
  end
end
