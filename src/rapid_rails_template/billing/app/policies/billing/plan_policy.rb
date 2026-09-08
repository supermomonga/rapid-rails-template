# frozen_string_literal: true

module Billing
  class PlanPolicy < ::ApplicationPolicy
    def manage?
      MerchantAccess.allowed?(user, record.merchant_account, :edit)
    end

    def create?
      manage? && record.merchant_account.status == 'active' && Setting.current.merchant_plan_creation_enabled?
    end
  end
end
