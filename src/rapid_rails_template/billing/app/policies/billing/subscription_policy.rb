# frozen_string_literal: true

module Billing
  class SubscriptionPolicy < ::ApplicationPolicy
    def manage?
      user.present? && record.user_id == user.id
    end

    def seller?
      MerchantAccess.allowed?(user, record.plan.merchant_account)
    end
  end
end
