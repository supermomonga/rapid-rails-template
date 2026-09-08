# frozen_string_literal: true

module Billing
  module Chains
    Chain = Data.define(:id, :name, :usdc, :native_symbol, :explorer, :rpc_env)
    MANAGER = "0xf85210b21cc50302f477ba56686d2019dc9b67ad"
    FACTORY = "0xba5ed110efdba3d005bfc882d75358acbbb85842"
    ALL = [
      Chain.new(42161, "Arbitrum", "0xaf88d065e77c8cc2239327c5edb3a432268e5831", "ETH", "https://arbiscan.io/tx/", "BILLING_ARBITRUM_RPC_URL"),
      Chain.new(8453, "Base", "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913", "ETH", "https://basescan.org/tx/", "BILLING_BASE_RPC_URL"),
      Chain.new(1, "Ethereum", "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48", "ETH", "https://etherscan.io/tx/", "BILLING_ETHEREUM_RPC_URL"),
      Chain.new(137, "Polygon", "0x3c499c542cef5e3811e1192ce70d8cc03d5c3359", "POL", "https://polygonscan.com/tx/", "BILLING_POLYGON_RPC_URL")
    ].to_h { |chain| [chain.id, chain] }.freeze

    def self.fetch(id)
      ALL.fetch(Integer(id))
    end

    def self.address?(value)
      value.is_a?(String) && value.match?(/\A0x[0-9a-fA-F]{40}\z/) && value.to_i(16).positive?
    end

    def self.hash?(value)
      value.is_a?(String) && value.match?(/\A0x[0-9a-fA-F]{64}\z/)
    end
  end
end
