# frozen_string_literal: true

module Billing
  class ChargePolicy < ::ApplicationPolicy
    def manage?
      MerchantAccess.allowed?(user, record.subscription.plan.merchant_account, :edit)
    end
  end
end
