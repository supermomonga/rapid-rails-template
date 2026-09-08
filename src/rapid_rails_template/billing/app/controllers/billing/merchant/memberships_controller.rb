# frozen_string_literal: true

module Billing
  module Merchant
    class MembershipsController < BaseController
      def index
        @pagy, @memberships = pagy(:offset, merchant_account.memberships.includes(user: :profile).order(:id))
        @invitations = merchant_account.invitations.where(status: 'pending').where('expires_at > ?', Time.current).includes(recipient: :profile).order(:id)
      end

      def update
        authorize! merchant_account, to: :manage?
        merchant_account.memberships.find(params.expect(:id)).update!(params.expect(merchant_membership: [:role]))
        redirect_to merchant_memberships_path, notice: I18n.t('billing.saved')
      rescue ActiveRecord::RecordInvalid => e
        redirect_to merchant_memberships_path, alert: e.record.errors.full_messages.join('、')
      end

      def destroy
        membership = merchant_account.memberships.find(params.expect(:id))
        authorize! merchant_account, to: :manage? unless membership.user_id == T.must(current_user).id
        membership.destroy!
        redirect_to membership.user_id == T.must(current_user).id ? merchant_root_path(merchant_id: nil) : merchant_memberships_path, notice: I18n.t('billing.saved')
      rescue ActiveRecord::RecordInvalid => e
        redirect_to merchant_memberships_path, alert: e.record.errors.full_messages.join('、')
      end
    end
  end
end
