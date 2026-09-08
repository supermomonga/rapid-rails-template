# frozen_string_literal: true

require "securerandom"

module Billing
  class Checkout
    def self.prepare!(user:, plan:, chain_id:, payer_address:, rpc: Rpc.new(chain_id), now: Time.current)
      raise ArgumentError, "invalid payer" unless Chains.address?(payer_address)

      rpc.verify_contracts!
      Setting.current.with_lock do
        plan.reload
        raise ConfigurationError, "billing unavailable" unless plan.available_on?(chain_id)

        chain = Chains.fetch(chain_id)
        settings = ChainSetting.for_chain(chain_id)
        start = Time.at(now.to_i).utc
        permission = {
          "account" => payer_address.downcase, "spender" => settings.collector_address.downcase,
          "token" => chain.usdc, "allowance" => plan.amount_units.to_s,
          "period" => (plan.period_days * 86400).to_s, "start" => start.to_i.to_s,
          "end" => (2**48 - 1).to_s, "salt" => SecureRandom.random_number(2**256).to_s, "extraData" => "0x"
        }
        hash_bytes = rpc.contract(Chains::MANAGER, "getHash", Contracts.permission_values(permission)).first
        hash = hash_bytes.start_with?("0x") ? hash_bytes : "0x#{Eth::Util.bin_to_hex(hash_bytes)}"
        raise VerificationError, "invalid permission hash" unless Chains.hash?(hash)

        Subscription.create!(user: user, plan: plan, seller_kind: plan.seller_kind,
          buyer_name: user.profile.display_name, seller_name: plan.seller_name, plan_name: plan.name,
          chain_id: chain_id, payer_address: payer_address.downcase, amount_units: plan.amount_units,
          period_seconds: plan.period_days * 86400, starts_at: start, permission: permission, permission_hash: hash)
      end
    end

    def self.typed_data(subscription)
      {
        "domain" => { "name" => "Spend Permission Manager", "version" => "1",
          "chainId" => subscription.chain_id, "verifyingContract" => Chains::MANAGER },
        "types" => {
          "EIP712Domain" => [
            { "name" => "name", "type" => "string" }, { "name" => "version", "type" => "string" },
            { "name" => "chainId", "type" => "uint256" }, { "name" => "verifyingContract", "type" => "address" }
          ],
          "SpendPermission" => Contracts::PERMISSION_FIELDS
        },
        "primaryType" => "SpendPermission", "message" => subscription.permission
      }
    end

    def self.review(subscription)
      I18n.t("billing.ui.permission_review", amount: Amount.format(subscription.amount_units),
        days: subscription.period_seconds / 86400, chain: Chains.fetch(subscription.chain_id).name,
        wallet: subscription.payer_address, starts_at: I18n.l(subscription.starts_at, format: :long))
    end

    def self.authorize!(subscription, signature:, now: Time.current)
      unless signature.is_a?(String) && signature.bytesize <= 131_074 && signature.match?(/\A0x(?:[0-9a-fA-F]{2})+\z/)
        raise ArgumentError, "invalid signature"
      end
      subscription.with_lock do
        raise Error, "contract cannot be authorized" unless subscription.status == "pending" &&
          !subscription.cancel_requested_at && now < subscription.starts_at + subscription.period_seconds
        raise Error, "contract already authorized" if subscription.signature.present?

        subscription.update!(signature: signature)
      end
      ReconcileJob.perform_later
    end
  end
end
