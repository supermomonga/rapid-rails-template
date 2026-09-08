# frozen_string_literal: true

module Billing
  class ApplicationController < ::ApplicationController
    helper ::ApplicationHelper
    helper Billing::UiHelper
    before_action :prevent_billing_cache
    around_action :billing_actor
    rescue_from ConfigurationError, with: :billing_unavailable
    rescue_from MerchantAccess::Denied, with: :billing_forbidden

    private

    def billing_forbidden
      head :forbidden
    end

    def billing_actor(&)
      Current.set(actor: current_user, &)
    end

    def prevent_billing_cache
      response.headers['Cache-Control'] = 'no-store'
    end

    def billing_unavailable
      render plain: I18n.t('billing.errors.unavailable'), status: :service_unavailable
    end
  end
end
