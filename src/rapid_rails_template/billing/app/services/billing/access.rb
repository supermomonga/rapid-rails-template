# frozen_string_literal: true

module Billing
  module Access
    def self.active?(user:, plan:, at: Time.current)
      return false unless user&.persisted?

      Subscription.where(user_id: user.id, plan_id: plan.id).where("paid_until > ?", at - Setting.current.grace_hours.hours)
        .any? { |subscription| subscription.usable?(at: at) }
    end
  end
end
