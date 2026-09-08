# frozen_string_literal: true

module Billing
  module AccountDeletion
    def self.blocked?(user)
      contracts = Subscription.where(user_id: user.id)
      MerchantMembership.exists?(user_id: user.id) || contracts.exists?(ended_at: nil) ||
        contracts.exists?(['paid_until > ?', Time.current]) ||
        Transaction.exists?(subscription_id: contracts.select(:id), finalized_at: nil)
    end
  end
end
