# frozen_string_literal: true

module Billing
  class MerchantAccountPolicy < ::ApplicationPolicy
    def manage?
      MerchantAccess.allowed?(user, record, :manage)
    end

    def view?
      MerchantAccess.allowed?(user, record)
    end

    def edit?
      MerchantAccess.allowed?(user, record, :edit)
    end

    def create?
      MerchantAccess.eligible?(user)
    end
  end
end
