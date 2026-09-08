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
      Billing::Plan, Billing::PayoutAddress, Billing::AuditEntry, Billing::MerchantInvitation, Billing::MerchantMembership,
      Billing::MerchantAccount, Billing::ChainSetting, Billing::Setting,
      UserRole, Profile, User].each(&:delete_all)
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

  def test_two_administrators_cannot_both_leave
    other = User.create!(name: "Second administrator")
    @merchant.memberships.create!(user: other, role: "admin")
    ids = @merchant.memberships.order(:id).pluck(:id)
    outcomes = concurrently(2) do |index|
      concurrent_outcome { Billing::MerchantMembership.find(ids.fetch(index)).destroy! }
    end
    assert_equal [:accepted, :rejected], outcomes.sort
    assert_equal 1, @merchant.memberships.where(role: "admin").count
  end

  def test_admin_only_switch_and_app_role_removal_cannot_leave_an_ineligible_administrator
    assignment = UserRole.create!(user_id: @user.id, role: "admin")
    outcomes = concurrently(2) do |index|
      concurrent_outcome do
        index.zero? ? Billing::Setting.current.update!(admin_only: true) : UserRole.find(assignment.id).destroy!
      end
    end
    assert_equal [:accepted, :rejected], outcomes.sort
    assert Billing::MerchantAccess.administrators_present?
    assert_equal Billing::Setting.current.admin_only?, UserRole.exists?(assignment.id)
  end

  def test_two_invitation_acceptances_create_one_membership
    target = User.create!(name: "Invited")
    invitation = Billing::Invitations.create!(merchant: @merchant, actor: @user, screen_name: target.profile.screen_name, role: "editor", now: @now)
    outcomes = concurrently(2) do
      concurrent_outcome do
        Billing::Invitations.respond!(invitation: Billing::MerchantInvitation.find(invitation.id), actor: target, response: "accepted", now: @now)
      end
    end
    assert_equal [:accepted, :rejected], outcomes.sort
    assert_equal 1, @merchant.memberships.where(user: target).count
    assert_equal "accepted", invitation.reload.status
  end

  def test_closure_and_invoice_start_do_not_leave_a_new_collectable_invoice
    contract = subscription
    concurrently(2) do |index|
      if index.zero?
        Billing::ChargeBuilder.call(Billing::Subscription.find(contract.id), now: @now)
      else
        Billing::MerchantClosure.start!(merchant: Billing::MerchantAccount.find(@merchant.id), actor: @user, now: @now)
      end
    end
    assert_equal "closing", @merchant.reload.status
    assert contract.reload.cancel_requested_at
    assert_empty contract.charges.where.not(status: "cancelled")
    assert_nil Billing::ChargeBuilder.call(contract, now: @now)
  end

  def test_closure_and_subscription_creation_cannot_leave_a_renewing_contract
    concurrently(2) do |index|
      concurrent_outcome do
        if index.zero?
          subscription(plan: Billing::Plan.find(@plan.id))
        else
          Billing::MerchantClosure.start!(merchant: Billing::MerchantAccount.find(@merchant.id), actor: @user, now: @now)
        end
      end
    end
    assert_equal "closing", @merchant.reload.status
    assert_empty @plan.subscriptions.where(cancel_requested_at: nil)
    assert_raises(Billing::ConfigurationError) { subscription(plan: @plan.reload) }
  end

  private
    def concurrent_outcome
      yield
      :accepted
    rescue ActiveRecord::RecordInvalid, Billing::Error
      :rejected
    end

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
