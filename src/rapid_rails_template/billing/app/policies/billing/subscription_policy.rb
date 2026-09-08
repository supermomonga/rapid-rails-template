# frozen_string_literal: true

module Billing
  class SubscriptionPolicy < ::ApplicationPolicy
    def manage?
      user.present? && record.user_id == user.id
    end

    def seller?
      admin? || user.present? && record.plan.merchant_profile&.user_id == user.id
    end
  end
end
