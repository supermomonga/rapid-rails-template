# frozen_string_literal: true

module Billing
  class ApplicationController < ::ApplicationController
    helper ::ApplicationHelper
    before_action :prevent_billing_cache
    rescue_from ConfigurationError, with: :billing_unavailable

    private
      def prevent_billing_cache
        response.headers["Cache-Control"] = "no-store"
      end

      def billing_unavailable
        render plain: I18n.t("billing.errors.unavailable"), status: :service_unavailable
      end
  end
end
