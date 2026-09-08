# frozen_string_literal: true

module Billing
  module UserRoleGuard
    extend ActiveSupport::Concern

    included do
      T.bind(self, T.class_of(::UserRole))
      around_save :preserve_billing_administrators
      around_destroy :preserve_billing_administrators_on_destroy, prepend: true
    end

    private

    def preserve_billing_administrators
      T.bind(self, ::UserRole)
      MerchantAccess.synchronize do
        validate_billing_role_removal! if persisted? && (will_save_change_to_role? || will_save_change_to_user_id?)
        yield
      end
    end

    def preserve_billing_administrators_on_destroy
      T.bind(self, ::UserRole)
      MerchantAccess.synchronize do
        validate_billing_role_removal!
        yield
      end
    end

    def validate_billing_role_removal!
      T.bind(self, ::UserRole)
      return unless Setting.current.admin_only?

      eligible = ::UserRole.admin.where.not(id: id).select(:user_id)
      administrators = MerchantMembership.where(role: 'admin', user_id: eligible).select(:merchant_account_id)
      return unless MerchantAccount.where.not(status: 'closed').where.not(id: administrators).exists?

      errors.add(:base, :billing_last_administrator)
      raise ActiveRecord::RecordInvalid, self
    end
  end
end
