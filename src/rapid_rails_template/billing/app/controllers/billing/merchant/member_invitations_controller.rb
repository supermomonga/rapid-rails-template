# frozen_string_literal: true

module Billing
  module Merchant
    class MemberInvitationsController < BaseController
      def create
        attributes = params.expect(invitation: %i[screen_name role])
        Invitations.create!(merchant: merchant_account, actor: current_user, screen_name: attributes[:screen_name], role: attributes[:role])
        redirect_to merchant_memberships_path, notice: I18n.t('billing.saved')
      rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique, Billing::Error, ActiveRecord::RecordNotFound
        redirect_to merchant_memberships_path, alert: I18n.t('billing.errors.invitation')
      end

      def destroy
        Invitations.revoke!(invitation: merchant_account.invitations.find(params.expect(:id)), actor: current_user)
        redirect_to merchant_memberships_path, notice: I18n.t('billing.saved')
      rescue Billing::Error, ActiveRecord::RecordInvalid
        redirect_to merchant_memberships_path, alert: I18n.t('billing.errors.invitation')
      end
    end
  end
end
