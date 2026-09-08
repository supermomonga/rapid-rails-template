# frozen_string_literal: true

require_relative "../billing_test_helper"

class BillingDomainTest < BillingTest
  def test_usdc_integer_arithmetic_and_fractional_fee
    assert_equal 10_000_001, Billing::Amount.parse("10.000001")
    assert_equal [100_000, 9_900_001], Billing::Amount.split(10_000_001, 100)
    assert_equal "10.000001", Billing::Amount.format(10_000_001)
    %w[1e6 -1 1.0000001 NaN].each { |value| assert_raises(ArgumentError) { Billing::Amount.parse(value) } }
  end

  def test_only_native_usdc_on_four_chains
    assert_equal [1, 137, 8453, 42161], Billing::Chains::ALL.keys.sort
    Billing::Chains::ALL.each_value { |chain| assert Billing::Chains.address?(chain.usdc), chain.name }
    assert_raises(KeyError) { Billing::Chains.fetch(10) }
  end

  def test_unpaid_contract_has_no_access_and_grace_is_usable
    contract = subscription
    refute contract.usable?(at: @now)
    contract.update!(paid_from: @now, paid_until: @now + 30.days, status: "active")
    assert contract.usable?(at: @now + 30.days + 71.hours)
    refute contract.usable?(at: @now + 33.days)
    contract.update!(cancel_requested_at: @now + 1.day)
    assert contract.usable?(at: @now + 29.days)
    refute contract.usable?(at: @now + 30.days)
  end

  def test_database_rejects_duplicate_open_plan_but_allows_different_plan
    subscription
    assert_raises(ActiveRecord::RecordNotUnique) { subscription(permission_hash: "0x#{'66' * 32}") }
    other = @plan.dup
    other.name = "Other"
    other.save!
    assert subscription(plan: other, permission_hash: "0x#{'66' * 32}").persisted?
  end

  def test_grace_changes_cannot_cross_plan_or_existing_contract_period
    contract = subscription
    @plan.update!(accepting_subscriptions: false)
    @setting.grace_hours = 30 * 24
    refute @setting.valid?
    assert @setting.errors.added?(:grace_hours, :billing_period)
    contract.update!(ended_at: @now, status: "ended")
    assert @setting.valid?
  end

  def test_runtime_switches_are_independent_and_block_open_contracts
    subscription
    @setting.assign_attributes(payments_enabled: false)
    refute @setting.valid?
    @setting.assign_attributes(payments_enabled: true, admin_only: false, merchant_plan_creation_enabled: false)
    assert @setting.save!
    assert @setting.payments_enabled?
    refute @setting.admin_only?
    refute @setting.merchant_plan_creation_enabled?
  end

  def test_plan_changes_do_not_reprice_contract_or_started_charge
    contract = subscription
    charge = Billing::ChargeBuilder.call(contract, now: @now)
    @plan.update!(amount_units: 20_000_000, period_days: 60)
    @chain.update!(treasury_address: "0x#{'77' * 20}")
    assert_equal 10_000_000, contract.reload.amount_units
    assert_equal 30 * 86400, contract.period_seconds
    assert_equal charge.id, Billing::ChargeBuilder.call(contract, now: @now).id
    assert_equal "0x#{'11' * 20}", charge.reload.operator_address
  end

  def test_manual_refund_records_no_chain_verification_and_correct_explorer
    charge = Billing::ChargeBuilder.call(subscription, now: @now)
    charge.update!(status: "settled")
    refund = charge.refund_records.create!(amount_units: 1_000_000, reason: "Manual refund", chain_id: 137, transaction_hash: "0x#{'aa' * 32}")
    assert_equal "https://polygonscan.com/tx/0x#{'aa' * 32}", refund.explorer_url
    assert_equal "settled", charge.reload.status
  end

  def test_execute_batch_abi_and_eip1559_signing
    address = "0x#{'11' * 20}"
    call = Billing::Contracts.encode("transfer", address, 1_000_000)
    data = Billing::Contracts.encode("executeBatch", [[Billing::Chains.fetch(1).usdc, 0, call]])
    assert_equal "0x34fcd5be", data[0, 10]
    signer = Billing::Signer.new(env: { "BILLING_EXECUTION_PRIVATE_KEY" => "01".rjust(64, "0") })
    signed = signer.sign(chain_id: 1, nonce: 3, to: address, data: data, gas_limit: 100_000, max_fee: 2, priority_fee: 1)
    assert Billing::Chains.hash?(signed.fetch(:hash))
    decoded = Eth::Tx.decode(signed.fetch(:raw))
    assert_equal 3, decoded.signer_nonce
    assert_equal signed.fetch(:hash), "0x#{decoded.hash}"
  end

  def test_fee_and_destination_changes_apply_only_to_the_next_invoice
    merchant = Billing::MerchantAccount.create!(creator: @user, public_id: "merchant", display_name: "Merchant")
    payout = merchant.payout_addresses.create!(chain_id: 1, address: "0x#{'66' * 20}")
    plan = merchant.plans.create!(name: "Merchant plan", amount_units: 10_000_001, period_days: 30, chain_ids: [1])
    contract = subscription(plan: plan, amount_units: plan.amount_units)
    first = Billing::ChargeBuilder.call(contract, now: @now)
    @setting.update!(fee_basis_points: 250)
    payout.update!(address: "0x#{'77' * 20}")
    assert_equal 100_000, first.reload.operator_units
    assert_equal 9_900_001, first.merchant_units
    assert_equal "0x#{'66' * 20}", first.merchant_address
    first.update!(status: "settled")
    contract.update!(paid_from: @now, paid_until: @now + 30.days, status: "active")
    second = Billing::ChargeBuilder.call(contract, now: @now + 30.days)
    assert_equal 250_000, second.operator_units
    assert_equal 9_750_001, second.merchant_units
    assert_equal "0x#{'77' * 20}", second.merchant_address
  end

  def test_chain_configuration_does_not_borrow_another_chains_settings
    env = { "BILLING_EXECUTION_PRIVATE_KEY" => "test-key", "BILLING_ETHEREUM_RPC_URL" => "https://rpc.example.test" }
    assert @plan.available_on?(1, env: env)
    refute @plan.available_on?(1, env: {})
    @plan.update!(chain_ids: [1, 8453])
    refute @plan.available_on?(8453, env: env)
    assert_nil Billing::ChainSetting.for_chain(8453).treasury_address
    assert @setting.reload.payments_enabled?
  end

  def test_disabling_new_merchant_plans_preserves_registration_and_existing_plans
    @setting.update!(merchant_plan_creation_enabled: false)
    merchant = Billing::MerchantAccount.create!(creator: @user, public_id: "registered", display_name: "Merchant")
    plan = merchant.plans.build(name: "Plan", amount_units: 1_000_000, period_days: 30, chain_ids: [1])
    refute plan.save
    @setting.update!(merchant_plan_creation_enabled: true)
    plan.save!
    @setting.update!(merchant_plan_creation_enabled: false)
    assert plan.update!(name: "Edited")
    assert merchant.update!(introduction: "Still open")
  end

  def test_rpc_configuration_error_never_retains_a_secret_url_as_its_cause
    error = assert_raises(Billing::ConfigurationError) do
      Billing::Rpc.new(1, env: { "BILLING_ETHEREUM_RPC_URL" => "https://secret-token example.test" })
    end
    assert_nil error.cause
    refute_includes error.full_message, "secret-token"
  end
end
