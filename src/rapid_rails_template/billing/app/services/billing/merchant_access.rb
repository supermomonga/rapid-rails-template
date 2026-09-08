# frozen_string_literal: true

module Billing
  module MerchantAccess
    class Denied < Billing::Error; end

    def self.app_admin?(user)
      user && ::UserRole.admin.exists?(user_id: user.id)
    end

    def self.eligible?(user, setting: Setting.current)
      user && ::User.exists?(id: user.id) && (!setting.admin_only? || app_admin?(user))
    end

    def self.allowed?(user, merchant, permission = :view)
      return false unless eligible?(user)

      role = merchant.memberships.find_by(user_id: user.id)&.role
      return role.present? if permission == :view
      return false if MerchantAccount.exists?(id: merchant.id, status: 'closed')

      case permission
      when :edit then %w(admin editor).include?(role)
      when :manage then role == 'admin'
      else raise ArgumentError, 'unknown merchant permission'
      end
    end

    def self.authorize!(user, merchant, permission = :view)
      raise Denied, 'merchant access denied' unless allowed?(user, merchant, permission)
    end

    def self.accounts(user)
      return MerchantAccount.none unless eligible?(user)

      MerchantAccount.where(id: MerchantMembership.where(user_id: user.id).select(:merchant_account_id))
    end

    # All merchant governance and billing-start writes take these locks in this order.
    # The settings row serializes cross-merchant eligibility changes as well.
    def self.synchronize(merchant = nil)
      Setting.current.with_lock do
        merchant.lock! if merchant&.persisted?
        yield
      end
    end

    def self.administrators_present?(setting: Setting.current)
      administrators = MerchantMembership.where(role: 'admin')
      administrators = administrators.where(user_id: ::UserRole.admin.select(:user_id)) if setting.admin_only?
      !MerchantAccount.where.not(status: 'closed').where.not(id: administrators.select(:merchant_account_id)).exists?
    end

    def self.validate_administrators!(record, setting: Setting.current)
      return if administrators_present?(setting: setting)

      record.errors.add(:base, :billing_last_administrator)
      raise ActiveRecord::RecordInvalid, record
    end
  end
end
