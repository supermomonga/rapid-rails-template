# frozen_string_literal: true

module Billing
  module AccountDeletion
    def self.blocked?(user)
      Subscription.exists?(user_id: user.id, ended_at: nil) ||
        Subscription.joins(plan: :merchant_profile).exists?(ended_at: nil, billing_merchant_profiles: { user_id: user.id })
    end
  end
end
