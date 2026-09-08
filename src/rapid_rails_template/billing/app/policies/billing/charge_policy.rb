# frozen_string_literal: true

module Billing
  class ChargePolicy < ::ApplicationPolicy
    def manage?
      admin? || user.present? && record.subscription.plan.merchant_profile&.user_id == user.id
    end
  end
end
