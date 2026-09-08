# frozen_string_literal: true

module Billing
  class SettingPolicy < ::ApplicationPolicy
    def manage?
      admin?
    end
  end
end
