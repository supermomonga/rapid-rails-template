# frozen_string_literal: true

require_relative "../billing_test_helper"

class BillingTransactionTest < BillingTest
  class RpcDouble
    attr_accessor :receipt, :canonical_hash, :finalized_number, :send_error, :gas, :network_nonce, :revoked
    attr_reader :sent

    def initialize
      @sent = []
      @canonical_hash = "0x#{'aa' * 32}"
      @finalized_number = 100
      @network_nonce = 7
      @gas = 100_000
      @revoked = false
    end

    def verify_chain!; end

    def call(method, *args)
      case method
      when "eth_getBlockByNumber"
        return { "baseFeePerGas" => "0xa" } if args.first == "pending"
        { "number" => "0x#{finalized_number.to_s(16)}", "hash" => canonical_hash }
      when "eth_getTransactionReceipt" then receipt
      when "eth_maxPriorityFeePerGas" then "0x2"
      when "eth_estimateGas" then "0x#{gas.to_s(16)}"
      when "eth_getTransactionCount" then "0x#{network_nonce.to_s(16)}"
      when "eth_sendRawTransaction"
        sent << args.first
        raise send_error if send_error
        "0x#{Eth::Tx.decode(args.first).hash}"
      else raise "Unexpected RPC method #{method}"
      end
    end

    def contract(_address, name, *_args, **_options)
      case name
      when "isOwnerAddress", "isApproved" then [true]
      when "isRevoked" then [revoked]
      else raise "Unexpected contract call #{name}"
      end
    end
  end

  def setup
    super
    @signer = Billing::Signer.new(env: { "BILLING_EXECUTION_PRIVATE_KEY" => "01".rjust(64, "0") })
    @chain.update!(executor_address: @signer.address)
    @rpc = RpcDouble.new
    @builder = Billing::TransactionBuilder.new(@chain, rpc: @rpc, signer: @signer)
    @subscription = subscription
    @charge = Billing::ChargeBuilder.call(@subscription, now: @now)
  end

  def test_timeout_keeps_signed_transaction_and_resends_identical_bytes_after_reload
    transaction = @builder.charge!(@charge, now: @now)
    assert_equal 7, transaction.nonce
    assert_equal "prepared", transaction.status
    assert_nil transaction.broadcast_started_at
    @rpc.send_error = Billing::RpcError.new("timeout")
    assert_raises(Billing::RpcError) { Billing::Broadcaster.call(transaction, rpc: @rpc, now: @now) }
    assert_equal "submitted", transaction.reload.status
    assert_equal @now, transaction.broadcast_started_at
    assert_nil @builder.charge!(@charge, now: @now)
    assert_nil Billing::ChargeBuilder.call(@subscription, now: @now)
    @rpc.send_error = nil
    Billing::Broadcaster.call(Billing::Transaction.find(transaction.id), rpc: @rpc, now: @now + 1.minute)
    assert_equal [transaction.raw_transaction, transaction.raw_transaction], @rpc.sent
    assert_equal 1, @subscription.charges.count
    assert_equal 1, @subscription.transactions.count
  end

  def test_next_contract_gets_next_nonce_without_waiting_for_finality
    first = @builder.charge!(@charge, now: @now)
    other = subscription(user: User.create!(name: "Other"), permission_hash: "0x#{'77' * 32}")
    next_charge = Billing::ChargeBuilder.call(other, now: @now)
    second = @builder.charge!(next_charge, now: @now)
    assert_equal [7, 8], [first.nonce, second.nonce]
    assert_nil first.finalized_at
    assert_nil second.finalized_at
    assert_equal 9, @chain.reload.next_nonce
  end

  def test_gas_hold_does_not_consume_nonce_or_create_a_transaction
    @chain.update!(gas_ceiling_wei: "1")
    assert_raises(Billing::GasLimitExceeded) { @builder.charge!(@charge, now: @now) }
    assert_empty @subscription.transactions
    assert_nil @chain.reload.next_nonce
    assert_equal "pending", @charge.reload.status
  end

  def test_cancellation_before_broadcast_voids_the_reserved_nonce
    transaction = @builder.charge!(@charge, now: @now)
    original = transaction.raw_transaction
    Billing::Cancellation.request!(@subscription, now: @now)
    with_test_method(Billing::Signer, :new, @signer) do
      Billing::Broadcaster.call(transaction, rpc: @rpc, now: @now)
    end
    assert_equal "void", transaction.reload.kind
    assert_equal original, transaction.superseded_payload.fetch("raw")
    decoded = Eth::Tx.decode(transaction.raw_transaction)
    assert_equal 7, decoded.signer_nonce
    assert_equal 0, decoded.amount
    assert_equal "", decoded.payload
    assert_equal @signer.address.delete_prefix("0x"), decoded.destination
    assert_equal "cancelled", @charge.reload.status
    refute_includes @rpc.sent, original
  end

  def test_in_flight_charge_is_honored_after_cancellation
    transaction = @builder.charge!(@charge, now: @now)
    Billing::Broadcaster.call(transaction, rpc: @rpc, now: @now)
    Billing::Cancellation.request!(@subscription, now: @now + 1)
    @rpc.receipt = receipt_for(transaction)
    assert Billing::ReceiptVerifier.new(transaction, rpc: @rpc).call
    assert_equal "settled", @charge.reload.status
    assert_equal "cancelling", @subscription.reload.status
    assert @subscription.usable?(at: @now + 29.days)
    refute @subscription.usable?(at: @now + 30.days)
    assert_nil Billing::ChargeBuilder.call(@subscription, now: @now + 30.days)
  end

  def test_closure_waits_for_an_in_flight_success_and_the_full_paid_period
    transaction = @builder.charge!(@charge, now: @now)
    Billing::Broadcaster.call(transaction, rpc: @rpc, now: @now)
    Billing::MerchantClosure.start!(merchant: @merchant, actor: @user, now: @now + 1)
    Billing::MerchantClosure.complete!(@merchant, now: @now + 2)
    assert_equal "closing", @merchant.reload.status
    @rpc.receipt = receipt_for(transaction)
    assert Billing::ReceiptVerifier.new(transaction, rpc: @rpc).call
    assert @subscription.reload.usable?(at: @now + 29.days)
    Billing::MerchantClosure.complete!(@merchant, now: @now + 29.days)
    assert_equal "closing", @merchant.reload.status
    @subscription.update!(revoked_at: @now + 2)
    travel_to @now + 30.days do
      Billing::ReconcileJob.new.send(:process_subscription, @subscription)
      Billing::MerchantClosure.complete!(@merchant)
    end
    assert_equal "closed", @merchant.reload.status
  end

  def test_receipt_must_be_finalized_and_canonical_before_access
    transaction = @builder.charge!(@charge, now: @now)
    @rpc.receipt = receipt_for(transaction)
    verifier = Billing::ReceiptVerifier.new(transaction, rpc: @rpc)
    @rpc.finalized_number = 99
    assert_nil verifier.call
    refute @subscription.reload.usable?(at: @now)
    @rpc.finalized_number = 100
    @rpc.canonical_hash = "0x#{'bb' * 32}"
    assert_nil verifier.call
    assert_nil transaction.reload.finalized_at
    @rpc.receipt = nil
    assert_nil verifier.call
    @rpc.canonical_hash = "0x#{'aa' * 32}"
    @rpc.receipt = receipt_for(transaction)
    assert verifier.call
    assert @subscription.reload.usable?(at: @now)
    assert_nil verifier.call
    assert_equal 1, Billing::Event.where(event_key: "charge:#{@charge.id}:settled").count
  end

  def test_success_status_without_distribution_is_rejected
    transaction = @builder.charge!(@charge, now: @now)
    @rpc.receipt = receipt_for(transaction)
    @rpc.receipt.fetch("logs").pop
    assert_raises(Billing::VerificationError) { Billing::ReceiptVerifier.new(transaction, rpc: @rpc).call }
    assert_nil transaction.reload.finalized_at
    refute @subscription.reload.usable?(at: @now)
  end

  def test_finalized_revert_does_not_grant_access_and_preserves_invoice_for_retry
    transaction = @builder.charge!(@charge, now: @now)
    @rpc.receipt = receipt_for(transaction).merge("status" => "0x0", "logs" => [])
    assert Billing::ReceiptVerifier.new(transaction, rpc: @rpc).call
    assert_equal "reverted", transaction.reload.status
    assert_equal "held", @charge.reload.status
    refute @subscription.reload.usable?(at: @now)
    assert_nil @builder.charge!(@charge, now: @now)
    @charge.update!(next_attempt_at: @now)
    retry_transaction = @builder.charge!(@charge, now: @now)
    assert_equal @charge.id, retry_transaction.charge_id
    assert_equal 8, retry_transaction.nonce
    assert_equal 1, @subscription.charges.count
  end

  def test_late_receipt_uses_the_fixed_on_chain_period_and_never_shifts_the_anchor
    transaction = @builder.charge!(@charge, now: @now)
    @rpc.receipt = receipt_for(transaction, period_start: @now + 30.days)
    Billing::ReceiptVerifier.new(transaction, rpc: @rpc).call
    assert_equal @now, @subscription.reload.starts_at
    assert_equal @now + 30.days, @charge.reload.settled_period_start
    assert_equal @now + 60.days, @subscription.paid_until
    assert_nil Billing::ChargeBuilder.call(@subscription, now: @now + 31.days)
    renewal = Billing::ChargeBuilder.call(@subscription, now: @now + 60.days)
    assert_equal 2, renewal.period_index
    assert_equal @now + 90.days, renewal.period_end
  end

  def test_external_revocation_keeps_paid_term_and_stops_renewals
    @subscription.update!(paid_from: @now, paid_until: @now + 30.days, status: "active")
    @rpc.revoked = true
    with_test_method(Billing::Rpc, :new, @rpc) do
      Billing::ReconcileJob.new.send(:process_subscription, @subscription)
    end
    assert @subscription.reload.cancel_requested_at
    assert @subscription.revoked_at
    assert @subscription.usable?(at: @now + 29.days)
    refute @subscription.usable?(at: @now + 30.days)
    assert_nil Billing::ChargeBuilder.call(@subscription, now: @now + 30.days)
  end

  def test_zero_full_and_shared_destination_allocations_settle_with_exact_transfers
    [[0, false], [10_000, false], [250, true]].each_with_index do |(rate, shared), index|
      @merchant.update!(fee_basis_points: rate)
      destination = shared ? @chain.treasury_address : "0x#{'66' * 20}"
      @merchant.payout_addresses.sole.update!(address: destination)
      @subscription = subscription(user: User.create!(name: "Split #{index}"), permission_hash: "0x#{(index + 6).to_s * 64}")
      @charge = Billing::ChargeBuilder.call(@subscription, now: @now)
      transaction = @builder.charge!(@charge, now: @now)
      @rpc.receipt = receipt_for(transaction)
      assert Billing::ReceiptVerifier.new(transaction, rpc: @rpc).call
      assert_equal "settled", @charge.reload.status
      assert @subscription.reload.usable?(at: @now + 1.day)
    end
  end

  def test_closure_before_broadcast_voids_the_prepared_payment
    transaction = @builder.charge!(@charge, now: @now)
    Billing::MerchantClosure.start!(merchant: @merchant, actor: @user, now: @now)
    with_test_method(Billing::Signer, :new, @signer) do
      Billing::Broadcaster.call(transaction, rpc: @rpc, now: @now)
    end
    assert_equal 'void', transaction.reload.kind
    assert_equal 'cancelled', @charge.reload.status
    assert_equal 'closing', @merchant.reload.status
    assert @subscription.reload.cancel_requested_at
  end

  private
    def with_test_method(target, method, result)
      original = target.method(method)
      target.define_singleton_method(method) { |*| result }
      yield
    ensure
      target.define_singleton_method(method, original)
    end

    def receipt_for(transaction, period_start: @now)
      transfer = Billing::Contracts.topic("Transfer(address,address,uint256)")
      usdc = Billing::Chains.fetch(1).usdc
      logs = [{
        "address" => Billing::Chains::MANAGER,
        "topics" => [Billing::Contracts.topic("SpendPermissionUsed(bytes32,address,address,address,(uint48,uint48,uint160))"),
          @subscription.permission_hash, Billing::Contracts.address_topic(@subscription.payer_address),
          Billing::Contracts.address_topic(@chain.collector_address)],
        "data" => "0x#{Eth::Util.bin_to_hex(Eth::Abi.encode(%w[address uint48 uint48 uint160],
          [usdc, period_start.to_i, (period_start + 30.days).to_i, @charge.amount_units]))}"
      }]
      transfers = [[@subscription.payer_address, @chain.collector_address, @charge.amount_units],
        [@chain.collector_address, @charge.operator_address, @charge.operator_units],
        [@chain.collector_address, @charge.merchant_address, @charge.merchant_units]]
      transfers.each do |from, to, units|
        next if units.zero?
        logs << { "address" => usdc, "topics" => [transfer, Billing::Contracts.address_topic(from), Billing::Contracts.address_topic(to)],
          "data" => "0x#{units.to_s(16).rjust(64, '0')}" }
      end
      { "transactionHash" => transaction.transaction_hash, "from" => transaction.signer_address,
        "to" => transaction.to_address, "blockNumber" => "0x64", "blockHash" => "0x#{'aa' * 32}", "status" => "0x1", "logs" => logs }
    end
end
