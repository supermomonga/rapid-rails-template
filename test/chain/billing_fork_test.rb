# frozen_string_literal: true

require_relative "../billing_test_helper"

# Explicitly run against an already started localhost Anvil fork. Never sends to a remote RPC.
class BillingForkTest < BillingTest
  def test_factory_signature_atomic_distribution_and_revocation
    chain_id = Integer(ENV.fetch("BILLING_FORK_CHAIN_ID"))
    chain = Billing::Chains.fetch(chain_id)
    port = Integer(ENV.fetch("BILLING_FORK_PORT", "18545"))
    @rpc = Billing::Rpc.new(chain_id, env: { chain.rpc_env => "http://127.0.0.1:#{port}" })
    assert_match(/\Aanvil\//, @rpc.call("web3_clientVersion"))
    assert_equal chain_id, Integer(@rpc.call("eth_chainId"), 16)
    @rpc.verify_contracts!
    @rpc.call("evm_setAutomine", false)
    @operator = Eth::Key.new
    @payer_key = Eth::Key.new
    @operator_address = @operator.address.to_s.downcase
    @rpc.call("anvil_setBalance", @operator_address, "0x3635c9adc5dea00000")
    @rpc.call("anvil_impersonateAccount", @operator_address)
    settings = Billing::ChainSetting.for_chain(chain_id)
    settings.update!(collector_address: nil, executor_address: nil, verified_at: nil,
      treasury_address: "0x#{'11' * 20}", gas_ceiling_wei: "1000000000000000000", next_nonce: nil)
    signer = Billing::Signer.new(env: { "BILLING_EXECUTION_PRIVATE_KEY" => @operator.private_hex })
    builder = Billing::TransactionBuilder.new(settings, rpc: @rpc, signer: signer)
    deployment = builder.deploy!
    Billing::Broadcaster.call(deployment, rpc: @rpc)
    finalize(deployment)
    assert settings.reload.ready?

    owners = [@payer_key.address.to_s, Billing::Chains::MANAGER].map { |a| "0x#{a.delete_prefix('0x').rjust(64, '0')}" }
    payer = @rpc.contract(Billing::Chains::FACTORY, "getAddress", owners, 47).first
    send_local(Billing::Chains::FACTORY, Billing::Contracts.encode("createAccount", owners, 47))
    master = read_token(chain.usdc, "masterMinter", [], [], ["address"]).first
    @rpc.call("anvil_setBalance", master, "0x3635c9adc5dea00000")
    @rpc.call("anvil_impersonateAccount", master)
    configure = function("configureMinter", %w[address uint256], ["bool"])
    send_local(chain.usdc, configure.encode_call(@operator_address, 100_000_000), from: master)
    send_local(chain.usdc, function("mint", %w[address uint256], ["bool"]).encode_call(payer, 100_000_000))

    merchant = Billing::MerchantProfile.create!(user: @user, public_id: "fork-merchant", display_name: "Merchant")
    merchant.payout_addresses.create!(chain_id: chain_id, address: "0x#{'66' * 20}")
    plan = merchant.plans.create!(seller_kind: "merchant", name: "Fork plan", amount_units: 10_000_000, period_days: 30, chain_ids: [chain_id])
    now = Time.at(Integer(@rpc.call("eth_getBlockByNumber", "latest", false).fetch("timestamp"), 16)).utc
    contract = Billing::Checkout.prepare!(user: @user, plan: plan, chain_id: chain_id, payer_address: payer, rpc: @rpc, now: now)
    hash = Eth::Util.hex_to_bin(contract.permission_hash)
    replay = function("replaySafeHash", ["bytes32"], ["bytes32"])
    replay_hash = replay.decode_call_result(@rpc.call("eth_call", { "to" => payer, "data" => replay.encode_call(hash) }, "latest")).first
    owner_signature = "0x#{@payer_key.sign(replay_hash)}"
    wrapper = "0x#{Eth::Util.bin_to_hex(Eth::Abi.encode([Eth::Abi::Type.parse('(uint256,bytes)')], [[0, owner_signature]]))}"
    Billing::Checkout.authorize!(contract, signature: wrapper, now: now)
    charge = Billing::ChargeBuilder.call(contract, now: now)
    treasury_before = balance(chain.usdc, settings.treasury_address)
    merchant_before = balance(chain.usdc, "0x#{'66' * 20}")
    transaction = builder.charge!(charge, now: now)
    assert transaction.raw_transaction.present?
    assert_nil transaction.broadcast_started_at
    assert_equal 100_000, charge.operator_units
    assert_equal 9_900_000, charge.merchant_units
    Billing::Broadcaster.call(transaction, rpc: @rpc, now: now)
    finalize(transaction)
    assert_equal "settled", charge.reload.status
    assert_equal 90_000_000, balance(chain.usdc, payer)
    assert_equal treasury_before + 100_000, balance(chain.usdc, settings.treasury_address)
    assert_equal merchant_before + 9_900_000, balance(chain.usdc, "0x#{'66' * 20}")
    assert_equal 0, balance(chain.usdc, settings.collector_address)

    @rpc.call("evm_increaseTime", 30 * 86400)
    @rpc.call("evm_mine")
    permission = Billing::Contracts.permission_values(contract.permission)
    bad_batch = Billing::Contracts.encode("executeBatch", [
      [Billing::Chains::MANAGER, 0, Billing::Contracts.encode("spend", permission, 10_000_000)],
      [chain.usdc, 0, Billing::Contracts.encode("transfer", "0x#{'66' * 20}", 20_000_000)]
    ])
    reverted = send_local(settings.collector_address, bad_batch, success: false)
    assert_equal "0x0", reverted.fetch("status")
    assert_equal 90_000_000, balance(chain.usdc, payer)
    assert_equal 0, @rpc.contract(Billing::Chains::MANAGER, "getCurrentPeriod", permission).first.last

    contract.update!(cancel_requested_at: now, status: "cancelling")
    revocation = builder.revoke!(contract)
    Billing::Broadcaster.call(revocation, rpc: @rpc)
    finalize(revocation)
    assert contract.reload.revoked_at
    assert @rpc.contract(Billing::Chains::MANAGER, "isRevoked", permission).first
  end

  private
    def function(name, input_types, output_types)
      Eth::Contract::Function.new("name" => name, "inputs" => input_types.map { |type| { "type" => type } },
        "outputs" => output_types.map { |type| { "type" => type } })
    end

    def read_token(address, name, input_types, args, output_types)
      method = function(name, input_types, output_types)
      method.decode_call_result(@rpc.call("eth_call", { "to" => address, "data" => method.encode_call(*args) }, "latest"))
    end

    def balance(token, account)
      read_token(token, "balanceOf", ["address"], [account], ["uint256"]).first
    end

    def send_local(to, data, from: @operator_address, success: true)
      hash = @rpc.call("eth_sendTransaction", { "from" => from, "to" => to, "data" => data, "gas" => "0x989680" })
      @rpc.call("evm_mine")
      receipt = @rpc.call("eth_getTransactionReceipt", hash)
      assert receipt, "local transaction was not mined: #{hash}"
      assert_equal(success ? "0x1" : "0x0", receipt.fetch("status"), "local transaction #{hash}")
      receipt
    end

    def finalize(transaction)
      @rpc.call("anvil_mine", "0x41")
      assert Billing::ReceiptVerifier.new(transaction, rpc: @rpc).call
      assert_equal "finalized", transaction.reload.status
    end
end
