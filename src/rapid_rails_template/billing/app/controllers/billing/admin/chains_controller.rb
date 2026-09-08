# frozen_string_literal: true

module Billing
  module Admin
    class ChainsController < BaseController
      def update
        chain = ChainSetting.for_chain(Integer(params.expect(:id)))
        attributes = params.expect(chain: %i[treasury_address gas_ceiling_native]).to_h
        attributes["gas_ceiling_wei"] = Amount.parse(attributes.delete("gas_ceiling_native"), decimals: 18).to_s
        Setting.current.with_lock { chain.update!(attributes) }
        redirect_to admin_chain_settings_path, notice: I18n.t("billing.saved")
      rescue ActiveRecord::RecordInvalid, ArgumentError, KeyError
        raise ActionController::BadRequest unless chain

        @invalid_chain = chain
        chain.errors.add(:base, I18n.t("billing.errors.invalid")) if chain.errors.empty?
        @chains = Chains::ALL.keys.map { |id| id == chain.chain_id ? chain : ChainSetting.for_chain(id) }
        render "billing/admin/overview/chains", status: :unprocessable_content
      end

      def deploy
        return head :unprocessable_content unless params[:confirmed] == "1"

        chain = ChainSetting.for_chain(Integer(params.expect(:id)))
        tx = TransactionBuilder.new(chain).deploy!
        Broadcaster.call(tx)
        ReconcileJob.perform_later
        redirect_to admin_root_path, notice: I18n.t("billing.setup_submitted")
      end
    end
  end
end
