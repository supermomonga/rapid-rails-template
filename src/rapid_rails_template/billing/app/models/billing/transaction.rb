# frozen_string_literal: true

module Billing
  class Transaction < ApplicationRecord
    belongs_to :chain_setting
    belongs_to :subscription, optional: true
    belongs_to :charge, optional: true
    validates :kind, inclusion: { in: %w[charge revoke deploy void] }
    validates :status, inclusion: { in: %w[prepared submitted finalized reverted review] }
    attr_readonly :chain_setting_id, :subscription_id, :charge_id, :signer_address, :nonce

    def explorer_url
      Chains.fetch(T.must(chain_setting).chain_id).explorer + transaction_hash
    end
  end
end
