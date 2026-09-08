# frozen_string_literal: true

module Billing
  module Admin
    class BaseController < ::Admin::BaseController
      helper ::ApplicationHelper
      helper Billing::UiHelper
      layout "billing/admin"
      before_action :authorize_billing_administration
      before_action :prevent_billing_cache
      rescue_from ConfigurationError, RpcError, VerificationError, GasLimitExceeded, with: :setup_failed

      private
        def prevent_billing_cache
          response.headers["Cache-Control"] = "no-store"
        end

        def authorize_billing_administration
          authorize! Setting.current, to: :manage?
        end

        def setup_failed
          render plain: I18n.t("billing.errors.setup"), status: :unprocessable_content
        end
    end
  end
end
