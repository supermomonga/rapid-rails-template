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
    post "/account/billing/merchant", params: { merchant_profile: {
      public_id: "new-merchant", display_name: "New merchant", introduction: "Introduction", user_id: @admin.id
    } }
    assert_redirected_to "/account/billing/merchant/edit"
    assert_equal @buyer.id, Billing::MerchantProfile.find_by!(public_id: "new-merchant").user_id
  end

  test "only seller can record a manual refund and access is unchanged" do
    @subscription.update!(paid_from: Time.current, paid_until: 30.days.from_now, status: "active")
    charge = @subscription.charges.create!(period_index: 0, period_start: @subscription.starts_at,
      period_end: @subscription.starts_at + 30.days, status: "settled", amount_units: 10_000_000,
      operator_units: 100_000, merchant_units: 9_900_000, fee_basis_points: 100,
      operator_address: "0x#{'11' * 20}", merchant_address: "0x#{'66' * 20}")
    attributes = { refund_record: { amount_usdc: "1.000001", reason: "Manual refund", chain_id: 137, transaction_hash: "0x#{'aa' * 32}" } }
    sign_in @buyer
    post "/account/billing/charges/#{charge.id}/refund_records", params: attributes
    assert_response :not_found
    sign_in @seller
    post "/account/billing/charges/#{charge.id}/refund_records", params: attributes
    assert_redirected_to "/account/billing/sales/#{@subscription.id}"
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
end
