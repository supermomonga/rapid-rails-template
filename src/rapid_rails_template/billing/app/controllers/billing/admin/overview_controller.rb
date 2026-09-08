# frozen_string_literal: true

module Billing
  module Admin
    class OverviewController < BaseController
      def show
        @settings = Setting.current
        @chains = Chains::ALL.keys.map { |id| ChainSetting.for_chain(id) }
        @transactions = Transaction.where(finalized_at: nil).includes(:chain_setting).order(:id).limit(100)
        @held_charges = Charge.where(status: "held").includes(:subscription).order(:id).limit(100)
        @missing_configuration = ConfigurationStatus.missing
      end
    end
  end
end
