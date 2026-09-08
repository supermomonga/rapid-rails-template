# frozen_string_literal: true

require "test_helper"

class BillingHostContractTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include ActiveJob::TestHelper

  setup do
    @buyer = User.create!
    @seller = User.create!
    @admin = User.create!
    @admin.grant_role!(:admin)
    @merchant = Billing::MerchantProfile.create!(user: @seller, public_id: "billing-test", display_name: "Merchant")
    @plan = @merchant.plans.create!(seller_kind: "merchant", name: "Subscription", amount_units: 10_000_000,
      period_days: 30, chain_ids: [8453])
    @subscription = @plan.subscriptions.create!(user: @buyer, seller_kind: "merchant", buyer_name: "Buyer",
      seller_name: "Merchant", plan_name: "Subscription", chain_id: 8453, payer_address: "0x#{'44' * 20}",
      amount_units: 10_000_000, period_seconds: 30 * 86400, starts_at: Time.current.change(usec: 0),
      permission: {}, permission_hash: "0x#{'55' * 32}")
  end

  test "guest and ordinary user cannot administer billing" do
    get "/account/billing/subscriptions"
    assert_redirected_to new_user_session_path
    patch "/admin/billing/settings", params: { setting: { fee_percent: "2.00", grace_hours: 24 } }
    assert_redirected_to new_user_session_path
    sign_in @buyer
    patch "/admin/billing/settings", params: { setting: { fee_percent: "2.00", grace_hours: 24 } }
    assert_response :forbidden
    assert_equal 100, Billing::Setting.current.fee_basis_points
  end

  test "public buyer seller and admin screens render without crossing ownership boundaries" do
    @merchant.update!(image_upload: AvatarTestImage.upload(width: 96, height: 96))
    ["/billing", "/billing/plans", "/billing/merchants", "/billing/merchants/#{@merchant.public_id}", "/billing/plans/#{@plan.id}"].each do |path|
      get path
      assert_response :success
      assert_select ".translation_missing", count: 0
    end
    get "/billing/merchants/#{@merchant.public_id}"
    assert_select "img[alt='Merchant'][width='80'][height='80']"
    sign_in @buyer
    ["/account/billing/subscriptions", "/account/billing/subscriptions/#{@subscription.id}", "/merchant/billing/profile/new"].each do |path|
      get path
      assert_response :success
      assert_select ".translation_missing", count: 0
    end
    sign_in @seller
    ["/merchant/billing", "/merchant/billing/profile/edit", "/merchant/billing/payout_addresses", "/merchant/billing/plans", "/merchant/billing/plans/new", "/merchant/billing/plans/#{@plan.id}/edit", "/merchant/billing/sales", "/merchant/billing/sales/#{@subscription.id}", "/merchant/billing/payments", "/merchant/billing/refund_records"].each do |path|
      get path
      assert_response :success
      assert_select ".translation_missing", count: 0
    end
    get "/account/billing/subscriptions/#{@subscription.id}"
    assert_response :not_found
    sign_in @admin
    ["/admin/billing", "/admin/billing/chain_settings", "/admin/billing/settings", "/admin/billing/plans", "/admin/billing/plans/new", "/admin/billing/subscriptions", "/admin/billing/subscriptions/#{@subscription.id}"].each do |path|
      get path
      assert_response :success
      assert_select ".translation_missing", count: 0
    end
  end

  test "invalid plan and settings retain submitted values and show validation messages" do
    sign_in @seller
    post "/merchant/billing/plans", params: { plan: { name: "Too short", price_usdc: "10", period_days: 1, chain_ids: ["", "8453"], accepting_subscriptions: "1" } }
    assert_response :unprocessable_content
    assert_select "input[name='plan[name]'][value='Too short']"
    assert_select ".alert-error"
    sign_in @admin
    patch "/admin/billing/settings", params: { setting: { fee_percent: "1.00", grace_hours: 1000 } }
    assert_response :unprocessable_content
    assert_select "input[name='setting[grace_hours]'][value='1000']"
    assert_select ".alert-error"
    patch "/admin/billing/settings", params: { setting: { fee_percent: "invalid", grace_hours: 48, merchant_plan_creation_enabled: "0" } }
    assert_response :unprocessable_content
    assert_select "input[name='setting[fee_percent]'][value='invalid']"
    assert_select "input[name='setting[grace_hours]'][value='48']"
    assert_select "input[type='checkbox'][name='setting[merchant_plan_creation_enabled]']:not([checked])"
    assert Billing::Setting.current.merchant_plan_creation_enabled?
  end

  test "checkout JSON freezes server terms and ignores client pricing and spender" do
    Billing::ChainSetting.for_chain(8453).update!(treasury_address: "0x#{'11' * 20}", collector_address: "0x#{'22' * 20}",
      executor_address: "0x#{'33' * 20}", gas_ceiling_wei: "10000000000000000", verified_at: Time.current)
    @merchant.payout_addresses.create!(chain_id: 8453, address: "0x#{'66' * 20}")
    fake_rpc = Object.new
    fake_rpc.define_singleton_method(:verify_contracts!) { true }
    fake_rpc.define_singleton_method(:contract) { |*_arguments| ["0x#{'77' * 32}"] }
    previous = ENV.to_h.slice("BILLING_EXECUTION_PRIVATE_KEY", "BILLING_BASE_RPC_URL")
    ENV["BILLING_EXECUTION_PRIVATE_KEY"] = "1".rjust(64, "0")
    ENV["BILLING_BASE_RPC_URL"] = "https://rpc.example.test"
    sign_in @admin
    original_new = Billing::Rpc.method(:new)
    Billing::Rpc.define_singleton_method(:new) { |*_arguments| fake_rpc }
    post "/account/billing/subscriptions", params: { subscription: { plan_id: @plan.id, chain_id: 8453,
      payer_address: "0x#{'44' * 20}", allowance: "1", period: "1", spender: "0x#{'88' * 20}" } }, as: :json
    assert_response :created
    body = response.parsed_body
    permission = body.fetch("typed_data").fetch("message")
    assert_equal "10000000", permission.fetch("allowance")
    assert_equal "2592000", permission.fetch("period")
    assert_equal "0x#{'22' * 20}", permission.fetch("spender")
    assert_equal Billing::Chains.fetch(8453).usdc, permission.fetch("token")
    assert_includes body.fetch("review"), "10.000000 USDC"
    @plan.update!(amount_units: 20_000_000)
    contract = Billing::Subscription.find(body.fetch("id"))
    assert_equal 10_000_000, contract.amount_units
    assert_equal permission, Billing::Checkout.typed_data(contract).fetch("message")
  ensure
    Billing::Rpc.define_singleton_method(:new, original_new) if original_new
    %w[BILLING_EXECUTION_PRIVATE_KEY BILLING_BASE_RPC_URL].each { |key| ENV[key] = previous[key] } if previous
  end

  test "only buyer can authorize or cancel a contract" do
    sign_in @seller
    post "/account/billing/subscriptions/#{@subscription.id}/authorize", params: { signature: "0xabcd" }, as: :json
    assert_response :not_found
    sign_in @seller
    post "/account/billing/subscriptions/#{@subscription.id}/cancel"
    assert_response :not_found
    assert_nil @subscription.reload.cancel_requested_at
    sign_in @buyer
    assert_enqueued_with(job: Billing::ReconcileJob) do
      post "/account/billing/subscriptions/#{@subscription.id}/authorize", params: { signature: "0xabcd", amount_units: 1 }, as: :json
    end
    assert_response :accepted
    assert_equal 10_000_000, @subscription.reload.amount_units
    assert_equal "0xabcd", @subscription.signature
    post "/account/billing/subscriptions/#{@subscription.id}/cancel"
    assert_redirected_to "/account/billing/subscriptions/#{@subscription.id}"
    assert @subscription.reload.cancel_requested_at
  end

  test "admin can independently disable operator sales and new merchant plans" do
    sign_in @admin
    patch "/admin/billing/settings", params: { setting: {
      operator_enabled: "0", merchants_enabled: "1", merchant_plan_creation_enabled: "0", fee_percent: "2.25", grace_hours: "24"
    } }
    assert_redirected_to "/admin/billing/settings"
    settings = Billing::Setting.current
    refute settings.operator_enabled?
    assert settings.merchants_enabled?
    refute settings.merchant_plan_creation_enabled?
    assert_equal 225, settings.fee_basis_points
    assert_equal 24, settings.grace_hours
  end

  test "registration belongs to current user when plan creation is disabled" do
    Billing::Setting.current.update!(merchant_plan_creation_enabled: false)
    sign_in @buyer
    post "/merchant/billing/profile", params: { merchant_profile: {
      public_id: "new-merchant", display_name: "New merchant", introduction: "Introduction", user_id: @admin.id
    } }
    assert_redirected_to "/merchant/billing"
    assert_equal @buyer.id, Billing::MerchantProfile.find_by!(public_id: "new-merchant").user_id
  end

  test "only seller can record a manual refund and access is unchanged" do
    @subscription.update!(paid_from: Time.current, paid_until: 30.days.from_now, status: "active")
    charge = @subscription.charges.create!(period_index: 0, period_start: @subscription.starts_at,
      period_end: @subscription.starts_at + 30.days, status: "settled", amount_units: 10_000_000,
      operator_units: 100_000, merchant_units: 9_900_000, fee_basis_points: 100,
      operator_address: "0x#{'11' * 20}", merchant_address: "0x#{'66' * 20}")
    attributes = { refund_record: { amount_usdc: "1.000001", reason: "Manual refund", chain_id: 137, transaction_hash: "0x#{'aa' * 32}" } }
    another_seller = User.create!
    Billing::MerchantProfile.create!(user: another_seller, public_id: "other-seller", display_name: "Other seller")
    sign_in another_seller
    post "/merchant/billing/charges/#{charge.id}/refund_records", params: attributes
    assert_response :not_found
    sign_in @seller
    post "/merchant/billing/charges/#{charge.id}/refund_records", params: attributes
    assert_redirected_to "/merchant/billing/sales/#{@subscription.id}?tab=payments"
    record = charge.refund_records.sole
    assert_equal 1_000_001, record.amount_units
    assert record.explorer_url.start_with?("https://polygonscan.com/tx/")
    assert Billing::Access.active?(user: @buyer, plan: @plan)
  end

  test "account deletion blocks buyer and seller then retains financial history" do
    refute @buyer.destroy
    refute @seller.destroy
    @subscription.update!(status: "ended", ended_at: Time.current, revoked_at: Time.current)
    assert @buyer.reload.destroy
    assert @seller.reload.destroy
    assert_nil @subscription.reload.user_id
    assert_nil @merchant.reload.user_id
    refute @plan.reload.accepting_subscriptions?
    assert_equal "Buyer", @subscription.buyer_name
    assert_equal "Merchant", @subscription.seller_name
  end

  test "billing event creates one host notification and invokes optional push delivery once" do
    delivered = []
    original = Rails.configuration.x.billing.push_delivery
    Rails.configuration.x.billing.push_delivery = ->(**attributes) { delivered << attributes }
    event = Billing::Event.record!("test:billing:settled", user: @buyer, message: "payment_settled", path: "/account/billing/subscriptions/#{@subscription.id}")
    assert_difference("Notification.count", 1) do
      2.times { event.reload.deliver! }
    end
    assert_equal 1, delivered.size
    assert_equal @buyer, delivered.fetch(0).fetch(:user)
    assert_equal 1, NotificationDelivery.where(user_id: @buyer.id).count
    assert event.reload.delivered_at
    assert event.push_processed_at
  ensure
    Rails.configuration.x.billing.push_delivery = original
  end

  test "seller navigation is independent and every menu destination has an icon" do
    get "/merchant/billing"
    assert_redirected_to new_user_session_path
    sign_in @buyer
    get "/merchant/billing"
    assert_redirected_to "/merchant/billing/profile/new"
    get "/account/billing/subscriptions"
    assert_select "[data-with-menu-items] a[href='/merchant/billing']", count: 1
    assert_select "[data-with-menu-items] a[href='/merchant/billing/sales']", count: 0
    assert_select "[role='tabpanel']", count: 1
    sign_in @seller
    get "/merchant/billing/sales"
    assert_select "nav[aria-label='#{I18n.t('billing.ui.merchant_menu')}']"
    assert_select "[data-with-menu-items] a[href='/merchant/billing/sales'][aria-current='page']"
    assert_select "[data-with-menu-items] a[href='/account/billing/subscriptions']", count: 0
    assert_select "[data-with-menu-items] > li > a" do |links|
      links.each { |link| assert link.at_css("svg[aria-hidden='true']"), link.text }
    end
  end

  test "seller summary and histories exclude other sellers and unsettled revenue" do
    charge = settled_charge
    charge.refund_records.create!(amount_units: 1_000_000, reason: "Recorded external refund", chain_id: 8453, transaction_hash: "0x#{'ab' * 32}")
    @subscription.charges.create!(period_index: 1, period_start: 30.days.from_now, period_end: 60.days.from_now,
      status: "held", amount_units: 20_000_000, operator_units: 200_000, merchant_units: 19_800_000,
      fee_basis_points: 100, operator_address: "0x#{'11' * 20}", merchant_address: "0x#{'66' * 20}")
    sign_in @seller
    get "/merchant/billing"
    assert_select ".stat-value", text: /10\s+USDC/
    assert_select ".stat-value", text: /9\.9\s+USDC/
    assert_select ".stat-value", text: /0\.1\s+USDC/
    get "/merchant/billing/payments?chain_id=137"
    assert_select "[data-billing-empty]"
    get "/merchant/billing/refund_records"
    assert_includes response.body, "Recorded external refund"
    other = User.create!
    Billing::MerchantProfile.create!(user: other, public_id: "separate-seller", display_name: "Separate")
    sign_in other
    get "/merchant/billing"
    assert_response :success
    get "/merchant/billing/sales/#{@subscription.id}"
    assert_response :not_found
    get "/merchant/billing/payments"
    refute_includes response.body, "Subscription"
    get "/merchant/billing/charges/#{charge.id}/refund_records/new"
    assert_response :not_found
  end

  test "invalid refund and payout submissions preserve fields in their own seller screen" do
    charge = settled_charge
    sign_in @seller
    post "/merchant/billing/charges/#{charge.id}/refund_records", params: { refund_record: {
      amount_usdc: "1.2345678", reason: "Keep this reason", chain_id: 137, transaction_hash: "incorrect"
    } }
    assert_response :unprocessable_content
    assert_select "input[name='refund_record[amount_usdc]'][value='1.2345678']"
    assert_select "textarea[name='refund_record[reason]']", text: "Keep this reason"
    assert_select "option[value='137'][selected]"
    assert_select ".alert-error"
    assert_equal 0, charge.refund_records.count
    post "/merchant/billing/payout_addresses", params: { payout_address: { chain_id: 8453, address: "bad-address" } }
    assert_response :unprocessable_content
    assert_select "input#payout_8453[value='bad-address']"
    assert_select "[role='tab'][aria-selected='true']", text: /#{Regexp.escape(I18n.t('billing.ui.payouts'))}/
  end

  test "cancellation confirmation is read only and ended subscriptions use a separate tab" do
    sign_in @buyer
    get "/account/billing/subscriptions/#{@subscription.id}/cancellation"
    assert_response :success
    assert_nil @subscription.reload.cancel_requested_at
    assert_select "input.btn-error[type='submit']"
    @subscription.update!(status: "ended", ended_at: Time.current)
    get "/account/billing/subscriptions"
    assert_select "[data-billing-subscription]", count: 0
    get "/account/billing/subscriptions?scope=ended"
    assert_select "[data-billing-subscription]", count: 1
    assert_select "[role='tab'][aria-selected='true']", text: I18n.t("billing.ui.ended_contracts")
  end

  private
    def settled_charge
      @subscription.charges.create!(period_index: 0, period_start: @subscription.starts_at,
        period_end: @subscription.starts_at + 30.days, status: "settled", amount_units: 10_000_000,
        operator_units: 100_000, merchant_units: 9_900_000, fee_basis_points: 100,
        operator_address: "0x#{'11' * 20}", merchant_address: "0x#{'66' * 20}")
    end
end
