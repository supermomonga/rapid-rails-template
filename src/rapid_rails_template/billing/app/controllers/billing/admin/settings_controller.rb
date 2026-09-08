# frozen_string_literal: true

module Billing
  module Admin
    class SettingsController < BaseController
      def show
        @settings = Setting.current
      end

      def update
        @settings = Setting.current
        attributes = params.expect(setting: %i[operator_enabled merchants_enabled merchant_plan_creation_enabled fee_percent grace_hours]).to_h
        attributes["fee_basis_points"] = Amount.parse(attributes.delete("fee_percent"), decimals: 2)
        saved = @settings.with_lock { @settings.update(attributes) }
        if saved
          redirect_to admin_settings_path, notice: I18n.t("billing.saved")
        else
          render :show, status: :unprocessable_content
        end
      rescue ArgumentError
        @settings.errors.add(:fee_basis_points, :invalid)
        render :show, status: :unprocessable_content
      end
    end
  end
end
