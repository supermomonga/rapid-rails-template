# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

module Billing
  class Rpc
    extend T::Sig
    def initialize(chain_id, env: ENV)
      @chain = Chains.fetch(chain_id)
      endpoint = env[@chain.rpc_env]
      raise ConfigurationError, @chain.rpc_env if endpoint.blank?

      @uri = URI.parse(endpoint)
      local_test = Rails.env.test? && @uri.instance_of?(URI::HTTP) && @uri.host == "127.0.0.1"
      raise ConfigurationError, @chain.rpc_env unless (@uri.is_a?(URI::HTTPS) && @uri.host.present?) || local_test
    rescue URI::InvalidURIError
      raise ConfigurationError.new(@chain.rpc_env), cause: nil
    end

    def call(method, *params)
      request = Net::HTTP::Post.new(@uri)
      request["Content-Type"] = "application/json"
      request.body = JSON.generate(jsonrpc: "2.0", id: 1, method: method, params: params)
      response = Net::HTTP.start(@uri.host, @uri.port, use_ssl: @uri.is_a?(URI::HTTPS), open_timeout: 5, read_timeout: 20) do |http|
        http.request(request)
      end
      raise RpcError, "RPC HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      body = response.body
      raise RpcError, "invalid RPC response" unless body

      payload = JSON.parse(body)
      raise RpcError, "invalid RPC response" unless payload.is_a?(Hash) && payload["jsonrpc"] == "2.0" && payload["id"] == 1
      if payload.key?("error")
        error = payload.fetch("error")
        raise RpcError, "invalid RPC response" unless error.is_a?(Hash) && error["code"].is_a?(Integer)
        raise RpcError, "RPC error #{error.fetch('code')}"
      end

      payload.fetch("result")
    rescue JSON::ParserError, KeyError
      raise RpcError.new("invalid RPC response"), cause: nil
    rescue Timeout::Error, IOError, SocketError, SystemCallError, OpenSSL::SSL::SSLError
      # Do not put credential-bearing RPC URLs, response bodies or signatures in logs.
      raise RpcError.new("RPC transport failed"), cause: nil
    end

    sig { params(address: String, name: String, args: T.untyped, block: String).returns(T::Array[T.untyped]) }
    def contract(address, name, *args, block: "latest")
      function = Contracts.function(name)
      result = call("eth_call", { "to" => address, "data" => function.encode_call(*args) }, block)
      Contracts.decode(name, result)
    end

    def verify_chain!
      raise VerificationError, "RPC chain mismatch" unless call("eth_chainId").to_i(16) == @chain.id
    end

    def verify_contracts!
      verify_chain!
      [@chain.usdc, Chains::MANAGER, Chains::FACTORY].each do |address|
        code = call("eth_getCode", address, "finalized")
        raise VerificationError, "contract is not deployed: #{address}" unless code.match?(/\A0x[0-9a-fA-F]+\z/) && code != "0x0"
      end
      raise VerificationError, "finalized block unavailable" unless call("eth_getBlockByNumber", "finalized", false).is_a?(Hash)
    end
  end
end
