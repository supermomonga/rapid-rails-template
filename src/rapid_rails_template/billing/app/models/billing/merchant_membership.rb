# frozen_string_literal: true

module Billing
  class MerchantMembership < ApplicationRecord
    ROLES = %w(admin editor viewer).freeze
    belongs_to :merchant_account
    belongs_to :user, class_name: '::User'
    attr_readonly :merchant_account_id, :user_id
    validates :role, inclusion: { in: ROLES }
    validates :user_id, uniqueness: { scope: :merchant_account_id }
    validate :membership_identity_is_immutable, on: :update
    around_save :save_membership
    around_destroy :remove_membership

    private

    def membership_identity_is_immutable
      errors.add(:merchant_account_id, :invalid) if will_save_change_to_merchant_account_id?
      errors.add(:user_id, :invalid) if will_save_change_to_user_id?
    end

    def save_membership
      MerchantAccess.synchronize(merchant_account) do
        raise MerchantAccess::Denied unless T.must(merchant_account).status != 'closed' && MerchantAccess.eligible?(user)

        if Current.actor && T.must(merchant_account).memberships.exists?
          MerchantAccess.authorize!(Current.authorization_actor || Current.actor, merchant_account, :manage)
        end
        ensure_administrator_remains! if persisted? && role != 'admin'
        yield
        AuditEntry.record!(merchant: merchant_account, target: self, action: 'membership.changed',
                           before_values: saved_changes.slice('role').transform_values(&:first),
                           after_values: { user_id: user_id, user_name: T.must(T.must(user).profile).display_name, role: role })
      end
    end

    def remove_membership
      MerchantAccess.synchronize(merchant_account) do
        if Current.actor && Current.actor.id != user_id
          MerchantAccess.authorize!(Current.actor, merchant_account, :manage)
        end
        ensure_administrator_remains!
        yield
        AuditEntry.record!(merchant: merchant_account, target: self, action: 'membership.removed',
                           before_values: { user_id: user_id, user_name: T.must(T.must(user).profile).display_name, role: role })
      end
    end

    def ensure_administrator_remains!
      return if T.must(merchant_account).status == 'closed'

      others = T.must(merchant_account).memberships.where(role: 'admin').where.not(id: id)
      others = others.where(user_id: ::UserRole.admin.select(:user_id)) if Setting.current.admin_only?
      return if others.exists?

      errors.add(:base, :billing_last_administrator)
      raise ActiveRecord::RecordInvalid, self
    end
  end
end
