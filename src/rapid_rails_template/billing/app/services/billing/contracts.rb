# frozen_string_literal: true

require "eth"

module Billing
  module Contracts
    extend T::Sig
    # ABI fragments from coinbase/spend-permissions and coinbase/smart-wallet.
    PERMISSION_FIELDS = [
      ["account", "address"], ["spender", "address"], ["token", "address"],
      ["allowance", "uint160"], ["period", "uint48"], ["start", "uint48"],
      ["end", "uint48"], ["salt", "uint256"], ["extraData", "bytes"]
    ].map { |name, type| { "name" => name, "type" => type }.freeze }.freeze
    PERMISSION = { "name" => "spendPermission", "type" => "tuple", "components" => PERMISSION_FIELDS }.freeze
    PERIOD = { "name" => "periodSpend", "type" => "tuple", "components" => [
      { "name" => "start", "type" => "uint48" }, { "name" => "end", "type" => "uint48" },
      { "name" => "spend", "type" => "uint160" }
    ] }.freeze
    CALLS = { "name" => "calls", "type" => "tuple[]", "components" => [
      { "name" => "target", "type" => "address" }, { "name" => "value", "type" => "uint256" },
      { "name" => "data", "type" => "bytes" }
    ] }.freeze
    ABI = {
      "getHash" => [[PERMISSION], [{ "type" => "bytes32" }]],
      "isApproved" => [[PERMISSION], [{ "type" => "bool" }]],
      "isRevoked" => [[PERMISSION], [{ "type" => "bool" }]],
      "getCurrentPeriod" => [[PERMISSION], [PERIOD]],
      "approveWithSignature" => [[PERMISSION, { "type" => "bytes", "name" => "signature" }], [{ "type" => "bool" }]],
      "spend" => [[PERMISSION, { "type" => "uint160", "name" => "value" }], []],
      "revokeAsSpender" => [[PERMISSION], []],
      "executeBatch" => [[CALLS], []],
      "transfer" => [[{ "type" => "address", "name" => "to" }, { "type" => "uint256", "name" => "amount" }], [{ "type" => "bool" }]],
      "getAddress" => [[{ "type" => "bytes[]", "name" => "owners" }, { "type" => "uint256", "name" => "nonce" }], [{ "type" => "address" }]],
      "createAccount" => [[{ "type" => "bytes[]", "name" => "owners" }, { "type" => "uint256", "name" => "nonce" }], [{ "type" => "address" }]],
      "isOwnerAddress" => [[{ "type" => "address", "name" => "account" }], [{ "type" => "bool" }]],
      "getL1Fee" => [[{ "type" => "bytes", "name" => "data" }], [{ "type" => "uint256" }]]
    }.freeze

    def self.function(name)
      inputs, outputs = ABI.fetch(name)
      Eth::Contract::Function.new("name" => name, "inputs" => inputs, "outputs" => outputs)
    end

    sig { params(name: String, args: T.untyped).returns(String) }
    def self.encode(name, *args)
      function(name).encode_call(*args)
    end

    def self.decode(name, data)
      raise VerificationError, "empty contract result" if data == "0x"

      function(name).decode_call_result(data)
    end

    def self.permission_values(permission)
      PERMISSION_FIELDS.map do |field|
        value = permission.fetch(field.fetch("name"))
        field.fetch("type").start_with?("uint") ? Integer(value) : value
      end
    end

    def self.topic(signature)
      "0x#{Eth::Util.bin_to_hex(Eth::Util.keccak256(signature))}"
    end

    def self.address_topic(address)
      "0x#{address.delete_prefix('0x').downcase.rjust(64, '0')}"
    end
  end
end
