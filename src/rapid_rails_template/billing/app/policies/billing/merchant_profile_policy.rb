# frozen_string_literal: true

module Billing
  class MerchantProfilePolicy < ::ApplicationPolicy
    def manage?
      user.present? && record.user_id == user.id
    end
  end
end
