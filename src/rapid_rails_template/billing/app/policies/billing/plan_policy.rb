# frozen_string_literal: true

module Billing
  class PlanPolicy < ::ApplicationPolicy
    def manage?
      record.seller_kind == "operator" ? admin? : user.present? && record.merchant_profile&.user_id == user.id
    end

    def create?
      manage? && (record.seller_kind == "operator" || Setting.current.merchant_plan_creation_enabled?)
    end
  end
end
