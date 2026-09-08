# frozen_string_literal: true

require_relative "../billing_test_helper"

class BillingConcurrencyTest < BillingTest
  class ConcurrentRpc
    def verify_chain!; end

    def contract(_address, name, *)
      case name
      when "isOwnerAddress", "isApproved" then [true]
      when "isRevoked" then [false]
      else raise "Unexpected contract #{name}"
      end
    end

    def call(method, *)
      case method
      when "eth_getBlockByNumber" then { "baseFeePerGas" => "0xa" }
      when "eth_maxPriorityFeePerGas" then "0x2"
      when "eth_estimateGas"
        sleep 0.05
        "0x186a0"
      when "eth_getTransactionCount" then "0x0"
      else raise "Unexpected RPC #{method}"
      end
    end
  end

  def setup
    super
    @signer = Billing::Signer.new(env: { "BILLING_EXECUTION_PRIVATE_KEY" => "01".rjust(64, "0") })
    @chain.update!(executor_address: @signer.address)
    ActiveRecord::Base.connection.commit_transaction
  end

  def teardown
    # These tables belong only to the temporary Rails application in billing_test_helper.
    [Billing::Event, Billing::RefundRecord, Billing::Transaction, Billing::Charge, Billing::Subscription,
      Billing::Plan, Billing::PayoutAddress, Billing::MerchantProfile, Billing::ChainSetting, Billing::Setting,
      UserRole, User].each(&:delete_all)
  end

  def test_two_workers_create_one_invoice_and_one_signed_transaction_for_the_same_period
    contract = subscription
    result = concurrently(2) do
      Billing::ChargeBuilder.call(Billing::Subscription.find(contract.id), now: @now).id
    end
    assert_equal 1, result.uniq.size
    charge_id = result.first
    concurrently(2) do
      builder = Billing::TransactionBuilder.new(Billing::ChainSetting.find(@chain.id), rpc: ConcurrentRpc.new, signer: @signer)
      builder.charge!(Billing::Charge.find(charge_id), now: @now)
    end
    assert_equal 1, contract.charges.count
    assert_equal 1, contract.transactions.count
    assert_equal 0, contract.transactions.sole.nonce
  end

  def test_two_workers_allocate_distinct_nonces_without_finalized_receipts
    first = subscription
    second = subscription(user: User.create!(name: "Second"), permission_hash: "0x#{'77' * 32}")
    ids = [first, second].map { |contract| Billing::ChargeBuilder.call(contract, now: @now).id }
    transactions = concurrently(2) do |index|
      builder = Billing::TransactionBuilder.new(Billing::ChainSetting.find(@chain.id), rpc: ConcurrentRpc.new, signer: @signer)
      builder.charge!(Billing::Charge.find(ids.fetch(index)), now: @now)
    end
    assert_equal [0, 1], transactions.map(&:nonce).sort
    assert transactions.all? { |transaction| transaction.finalized_at.nil? }
    assert_equal 2, @chain.reload.next_nonce
  end

  private
    def concurrently(count)
      ready = Queue.new
      start = Queue.new
      threads = count.times.map do |index|
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            ready << true
            start.pop
            yield index
          end
        end
      end
      count.times { ready.pop }
      count.times { start << true }
      threads.map(&:value)
    ensure
      threads&.each(&:join)
    end
end
