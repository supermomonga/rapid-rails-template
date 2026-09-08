# frozen_string_literal: true

module Billing
  module Merchant
    class InvitationsController < BaseController
      skip_before_action :require_merchant_account

      def index
        @pagy, @invitations = pagy(:offset, MerchantInvitation.where(recipient: current_user).includes(:merchant_account).order(id: :desc))
      end

      def accept
        respond_to_invitation('accepted')
      end

      def reject
        respond_to_invitation('rejected')
      end

      private

      def respond_to_invitation(response)
        invitation = MerchantInvitation.where(recipient: current_user).find(params.expect(:id))
        Invitations.respond!(invitation: invitation, actor: current_user, response: response)
        redirect_to merchant_invitations_path(merchant_id: nil), notice: I18n.t('billing.saved')
      rescue Billing::Error, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
        redirect_to merchant_invitations_path(merchant_id: nil), alert: I18n.t('billing.errors.invitation')
      end
    end
  end
end
