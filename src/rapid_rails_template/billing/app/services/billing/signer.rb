# frozen_string_literal: true

require "eth"

module Billing
  class Signer
    def initialize(env: ENV)
      secret = env["BILLING_EXECUTION_PRIVATE_KEY"]
      unless secret.is_a?(String) && secret.match?(/\A(?:0x)?[0-9a-fA-F]{64}\z/)
        raise ConfigurationError, "BILLING_EXECUTION_PRIVATE_KEY"
      end
      @key = Eth::Key.new(priv: secret.delete_prefix("0x"))
    end

    def address
      @key.address.to_s.downcase
    end

    def sign(chain_id:, nonce:, to:, data:, gas_limit:, max_fee:, priority_fee:)
      tx = Eth::Tx.new(chain_id: chain_id, nonce: nonce, from: address, to: to,
        value: 0, data: data, gas_limit: gas_limit, max_gas_fee: max_fee, priority_fee: priority_fee)
      tx.sign(@key)
      { hash: "0x#{tx.hash}", raw: "0x#{tx.hex}" }
    end
  end
end
