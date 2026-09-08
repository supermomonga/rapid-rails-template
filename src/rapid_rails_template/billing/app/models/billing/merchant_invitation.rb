# frozen_string_literal: true

module Billing
  class MerchantInvitation < ApplicationRecord
    belongs_to :merchant_account
    belongs_to :recipient, class_name: '::User', optional: true
    belongs_to :inviter, class_name: '::User', optional: true
    attr_readonly :merchant_account_id, :recipient_id, :inviter_id, :role, :expires_at
    validates :role, inclusion: { in: MerchantMembership::ROLES }
    validates :status, inclusion: { in: %w(pending accepted rejected revoked expired) }
    validates :expires_at, presence: true
  end
end
