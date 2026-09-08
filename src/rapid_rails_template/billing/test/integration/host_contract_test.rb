# frozen_string_literal: true

require 'test_helper'

class BillingHostContractTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include ActiveJob::TestHelper

  setup do
    @buyer = User.create!
    @seller = User.create!
    @admin = User.create!
    @admin.grant_role!(:admin)
    @merchant = Billing::MerchantAccount.create!(creator: @seller, public_id: 'billing-test', display_name: 'Merchant')
    @plan = @merchant.plans.create!(name: 'Subscription', amount_units: 10_000_000, period_days: 30, chain_ids: [8453])
    @subscription = @plan.subscriptions.create!(user: @buyer, buyer_name: 'Buyer', seller_name: 'Merchant', plan_name: 'Subscription', chain_id: 8453, payer_address: "0x#{'44' * 20}", amount_units: 10_000_000, period_seconds: 30 * 86400, starts_at: Time.current.change(usec: 0), permission: {}, permission_hash: "0x#{'55' * 32}")
  end

  test 'guest and ordinary user cannot administer billing' do
    get '/account/billing/subscriptions'
    assert_redirected_to new_user_session_path
    patch '/admin/billing/settings', params: { setting: { fee_percent: '2.00', grace_hours: 24 } }
    assert_redirected_to new_user_session_path
    sign_in @buyer
    patch '/admin/billing/settings', params: { setting: { fee_percent: '2.00', grace_hours: 24 } }
    assert_response :forbidden
    assert_equal 100, Billing::Setting.current.fee_basis_points
  end

  test 'public buyer seller and admin screens render without crossing ownership boundaries' do
    @merchant.update!(image_upload: AvatarTestImage.upload(width: 96, height: 96))
    ['/billing', '/billing/plans', '/billing/merchants', "/billing/merchants/#{@merchant.public_id}", "/billing/plans/#{@plan.id}"].each do |path|
      get path
      assert_response :success
      assert_select '.translation_missing', count: 0
    end
    get "/billing/merchants/#{@merchant.public_id}"
    assert_select "img[alt='Merchant'][width='80'][height='80']"
    sign_in @buyer
    ['/account/billing/subscriptions', "/account/billing/subscriptions/#{@subscription.id}", '/merchant/billing/accounts/new'].each do |path|
      get path
      assert_response :success
      assert_select '.translation_missing', count: 0
    end
    sign_in @seller
    ['/merchant/billing/billing-test', '/merchant/billing/billing-test/profile/edit', '/merchant/billing/billing-test/payout_addresses', '/merchant/billing/billing-test/plans', '/merchant/billing/billing-test/plans/new', "/merchant/billing/billing-test/plans/#{@plan.id}/edit", '/merchant/billing/billing-test/sales', "/merchant/billing/billing-test/sales/#{@subscription.id}", '/merchant/billing/billing-test/payments', '/merchant/billing/billing-test/refund_records', '/merchant/billing/billing-test/memberships', '/merchant/billing/billing-test/audit_entries', '/merchant/billing/billing-test/closure'].each do |path|
      get path
      assert_response :success
      assert_select '.translation_missing', count: 0
    end
    get "/account/billing/subscriptions/#{@subscription.id}"
    assert_response :not_found
    sign_in @admin
    ['/admin/billing', '/admin/billing/chain_settings', '/admin/billing/settings', '/admin/billing/merchants', '/admin/billing/merchants/billing-test', '/admin/billing/subscriptions', "/admin/billing/subscriptions/#{@subscription.id}"].each do |path|
      get path
      assert_response :success
      assert_select '.translation_missing', count: 0
    end
  end

  test 'invalid plan and settings retain submitted values and show validation messages' do
    sign_in @seller
    post '/merchant/billing/billing-test/plans', params: { plan: { name: 'Too short', price_usdc: '10', period_days: 1, chain_ids: ['', '8453'], accepting_subscriptions: '1' } }
    assert_response :unprocessable_content
    assert_select "input[name='plan[name]'][value='Too short']"
    assert_select '.alert-error'
    sign_in @admin
    patch '/admin/billing/settings', params: { setting: { fee_percent: '1.00', grace_hours: 1000 } }
    assert_response :unprocessable_content
    assert_select "input[name='setting[grace_hours]'][value='1000']"
    assert_select '.alert-error'
    patch '/admin/billing/settings', params: { setting: { fee_percent: 'invalid', grace_hours: 48, merchant_plan_creation_enabled: '0' } }
    assert_response :unprocessable_content
    assert_select "input[name='setting[fee_percent]'][value='invalid']"
    assert_select "input[name='setting[grace_hours]'][value='48']"
    assert_select "input[type='checkbox'][name='setting[merchant_plan_creation_enabled]']:not([checked])"
    assert Billing::Setting.current.merchant_plan_creation_enabled?
  end

  test 'checkout JSON freezes server terms and ignores client pricing and spender' do
    Billing::ChainSetting.for_chain(8453).update!(treasury_address: "0x#{'11' * 20}", collector_address: "0x#{'22' * 20}",
                                                  executor_address: "0x#{'33' * 20}", gas_ceiling_wei: '10000000000000000', verified_at: Time.current)
    @merchant.payout_addresses.create!(chain_id: 8453, address: "0x#{'66' * 20}")
    fake_rpc = Object.new
    fake_rpc.define_singleton_method(:verify_contracts!) { true }
    fake_rpc.define_singleton_method(:contract) { |*_arguments| ["0x#{'77' * 32}"] }
    previous = ENV.to_h.slice('BILLING_EXECUTION_PRIVATE_KEY', 'BILLING_BASE_RPC_URL')
    ENV['BILLING_EXECUTION_PRIVATE_KEY'] = '1'.rjust(64, '0')
    ENV['BILLING_BASE_RPC_URL'] = 'https://rpc.example.test'
    sign_in @admin
    original_new = Billing::Rpc.method(:new)
    Billing::Rpc.define_singleton_method(:new) { |*_arguments| fake_rpc }
    post '/account/billing/subscriptions', params: { subscription: { plan_id: @plan.id, chain_id: 8453,
                                                                     payer_address: "0x#{'44' * 20}", allowance: '1', period: '1', spender: "0x#{'88' * 20}", } }, as: :json
    assert_response :created
    body = response.parsed_body
    permission = body.fetch('typed_data').fetch('message')
    assert_equal '10000000', permission.fetch('allowance')
    assert_equal '2592000', permission.fetch('period')
    assert_equal "0x#{'22' * 20}", permission.fetch('spender')
    assert_equal Billing::Chains.fetch(8453).usdc, permission.fetch('token')
    assert_includes body.fetch('review'), '10.000000 USDC'
    @plan.update!(amount_units: 20_000_000)
    contract = Billing::Subscription.find(body.fetch('id'))
    assert_equal 10_000_000, contract.amount_units
    assert_equal permission, Billing::Checkout.typed_data(contract).fetch('message')
  ensure
    Billing::Rpc.define_singleton_method(:new, original_new) if original_new
    %w(BILLING_EXECUTION_PRIVATE_KEY BILLING_BASE_RPC_URL).each { |key| ENV[key] = previous[key] } if previous
  end

  test 'only buyer can authorize or cancel a contract' do
    sign_in @seller
    post "/account/billing/subscriptions/#{@subscription.id}/authorize", params: { signature: '0xabcd' }, as: :json
    assert_response :not_found
    sign_in @seller
    post "/account/billing/subscriptions/#{@subscription.id}/cancel"
    assert_response :not_found
    assert_nil @subscription.reload.cancel_requested_at
    sign_in @buyer
    assert_enqueued_with(job: Billing::ReconcileJob) do
      post "/account/billing/subscriptions/#{@subscription.id}/authorize", params: { signature: '0xabcd', amount_units: 1 }, as: :json
    end
    assert_response :accepted
    assert_equal 10_000_000, @subscription.reload.amount_units
    assert_equal '0xabcd', @subscription.signature
    post "/account/billing/subscriptions/#{@subscription.id}/cancel"
    assert_redirected_to "/account/billing/subscriptions/#{@subscription.id}"
    assert @subscription.reload.cancel_requested_at
  end

  test 'admin can disable new plans while preserving billing and unrestricted membership' do
    sign_in @admin
    patch '/admin/billing/settings', params: { setting: {
      payments_enabled: '1', admin_only: '0', merchant_plan_creation_enabled: '0', fee_percent: '2.25', grace_hours: '24',
    } }
    assert_redirected_to '/admin/billing/settings'
    settings = Billing::Setting.current
    refute settings.admin_only?
    assert settings.payments_enabled?
    refute settings.merchant_plan_creation_enabled?
    assert_equal 225, settings.fee_basis_points
    assert_equal 24, settings.grace_hours
  end

  test 'registration belongs to current user when plan creation is disabled' do
    Billing::Setting.current.update!(merchant_plan_creation_enabled: false)
    sign_in @buyer
    post '/merchant/billing/accounts', params: { merchant_account: {
      public_id: 'new-merchant', display_name: 'New merchant', introduction: 'Introduction', user_id: @admin.id,
    } }
    assert_redirected_to '/merchant/billing/new-merchant'
    assert_equal @buyer.id, Billing::MerchantAccount.find_by!(public_id: 'new-merchant').memberships.sole.user_id
  end

  test 'only seller can record a manual refund and access is unchanged' do
    @subscription.update!(paid_from: Time.current, paid_until: 30.days.from_now, status: 'active')
    charge = @subscription.charges.create!(period_index: 0, period_start: @subscription.starts_at,
                                           period_end: @subscription.starts_at + 30.days, status: 'settled', amount_units: 10_000_000,
                                           operator_units: 100_000, merchant_units: 9_900_000, fee_basis_points: 100,
                                           operator_address: "0x#{'11' * 20}", merchant_address: "0x#{'66' * 20}")
    attributes = { refund_record: { amount_usdc: '1.000001', reason: 'Manual refund', chain_id: 137, transaction_hash: "0x#{'aa' * 32}" } }
    another_seller = User.create!
    Billing::MerchantAccount.create!(creator: another_seller, public_id: 'other-seller', display_name: 'Other seller')
    sign_in another_seller
    post "/merchant/billing/billing-test/charges/#{charge.id}/refund_records", params: attributes
    assert_response :not_found
    sign_in @seller
    post "/merchant/billing/billing-test/charges/#{charge.id}/refund_records", params: attributes
    assert_redirected_to "/merchant/billing/billing-test/sales/#{@subscription.id}?tab=payments"
    record = charge.refund_records.sole
    assert_equal 1_000_001, record.amount_units
    assert record.explorer_url.start_with?('https://polygonscan.com/tx/')
    assert Billing::Access.active?(user: @buyer, plan: @plan)
  end

  test 'account deletion blocks buyer and seller then retains financial history' do
    refute @buyer.destroy
    refute @seller.destroy
    @subscription.update!(status: 'ended', ended_at: Time.current, revoked_at: Time.current)
    assert @buyer.reload.destroy
    Billing::MerchantClosure.start!(merchant: @merchant, actor: @seller)
    Billing::MerchantClosure.complete!(@merchant)
    @merchant.memberships.sole.destroy!
    assert @seller.reload.destroy
    assert_nil @subscription.reload.user_id
    assert_equal 'closed', @merchant.reload.status
    refute @plan.reload.accepting_subscriptions?
    assert_equal 'Buyer', @subscription.buyer_name
    assert_equal 'Merchant', @subscription.seller_name
  end

  test 'billing event creates one host notification and invokes optional push delivery once' do
    delivered = []
    original = Rails.configuration.x.billing.push_delivery
    Rails.configuration.x.billing.push_delivery = ->(**attributes) { delivered << attributes }
    event = Billing::Event.record!('test:billing:settled', user: @buyer, message: 'payment_settled', path: "/account/billing/subscriptions/#{@subscription.id}")
    assert_difference('Notification.count', 1) do
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

  test 'seller navigation is independent and every menu destination has an icon' do
    get '/merchant/billing'
    assert_redirected_to new_user_session_path
    sign_in @buyer
    get '/merchant/billing'
    assert_response :success
    get '/account/billing/subscriptions'
    assert_select "[data-with-menu-items] a[href='/merchant/billing']", count: 1
    assert_select "[data-with-menu-items] a[href='/merchant/billing/sales']", count: 0
    assert_select "[role='tabpanel']", count: 1
    sign_in @seller
    get '/merchant/billing/billing-test/sales'
    assert_select "nav[aria-label='#{I18n.t('billing.ui.merchant_menu')}']"
    assert_select "[data-with-menu-items] a[href='/merchant/billing/billing-test/sales'][aria-current='page']"
    assert_select "[data-with-menu-items] a[href='/account/billing/subscriptions']", count: 0
    assert_select '[data-with-menu-items] > li > a' do |links|
      links.each { |link| assert link.at_css("svg[aria-hidden='true']"), link.text }
    end
  end

  test 'seller summary and histories exclude other sellers and unsettled revenue' do
    charge = settled_charge
    charge.refund_records.create!(amount_units: 1_000_000, reason: 'Recorded external refund', chain_id: 8453, transaction_hash: "0x#{'ab' * 32}")
    @subscription.charges.create!(period_index: 1, period_start: 30.days.from_now, period_end: 60.days.from_now,
                                  status: 'held', amount_units: 20_000_000, operator_units: 200_000, merchant_units: 19_800_000,
                                  fee_basis_points: 100, operator_address: "0x#{'11' * 20}", merchant_address: "0x#{'66' * 20}")
    sign_in @seller
    get '/merchant/billing/billing-test'
    assert_select '.stat-value', text: /10\s+USDC/
    assert_select '.stat-value', text: /9\.9\s+USDC/
    assert_select '.stat-value', text: /0\.1\s+USDC/
    get '/merchant/billing/billing-test/payments?chain_id=137'
    assert_select '[data-billing-empty]'
    get '/merchant/billing/billing-test/refund_records'
    assert_includes response.body, 'Recorded external refund'
    other = User.create!
    Billing::MerchantAccount.create!(creator: other, public_id: 'separate-seller', display_name: 'Separate')
    sign_in other
    get '/merchant/billing/separate-seller'
    assert_response :success
    get "/merchant/billing/billing-test/sales/#{@subscription.id}"
    assert_response :not_found
    get '/merchant/billing/separate-seller/payments'
    refute_includes response.body, 'Subscription'
    get "/merchant/billing/billing-test/charges/#{charge.id}/refund_records/new"
    assert_response :not_found
  end

  test 'invalid refund and payout submissions preserve fields in their own seller screen' do
    charge = settled_charge
    sign_in @seller
    post "/merchant/billing/billing-test/charges/#{charge.id}/refund_records", params: { refund_record: {
      amount_usdc: '1.2345678', reason: 'Keep this reason', chain_id: 137, transaction_hash: 'incorrect',
    } }
    assert_response :unprocessable_content
    assert_select "input[name='refund_record[amount_usdc]'][value='1.2345678']"
    assert_select "textarea[name='refund_record[reason]']", text: 'Keep this reason'
    assert_select "option[value='137'][selected]"
    assert_select '.alert-error'
    assert_equal 0, charge.refund_records.count
    post '/merchant/billing/billing-test/payout_addresses', params: { payout_address: { chain_id: 8453, address: 'bad-address' } }
    assert_response :unprocessable_content
    assert_select "input#payout_8453[value='bad-address']"
    assert_select "[role='tab'][aria-selected='true']", text: /#{Regexp.escape(I18n.t('billing.ui.payouts'))}/
  end

  test 'cancellation confirmation is read only and ended subscriptions use a separate tab' do
    sign_in @buyer
    get "/account/billing/subscriptions/#{@subscription.id}/cancellation"
    assert_response :success
    assert_nil @subscription.reload.cancel_requested_at
    assert_select "input.btn-error[type='submit']"
    @subscription.update!(status: 'ended', ended_at: Time.current)
    get '/account/billing/subscriptions'
    assert_select '[data-billing-subscription]', count: 0
    get '/account/billing/subscriptions?scope=ended'
    assert_select '[data-billing-subscription]', count: 1
    assert_select "[role='tab'][aria-selected='true']", text: I18n.t('billing.ui.ended_contracts')
  end

  test 'app administrator needs membership and viewer cannot write or record refunds' do
    sign_in @admin
    get '/merchant/billing/billing-test/plans'
    assert_response :not_found
    @merchant.memberships.create!(user: @buyer, role: 'viewer')
    sign_in @buyer
    get '/merchant/billing/billing-test/plans'
    assert_response :success
    assert_select "a[href='/merchant/billing/billing-test/plans/#{@plan.id}/edit']", count: 0
    patch "/merchant/billing/billing-test/plans/#{@plan.id}", params: { plan: { name: 'Denied', price_usdc: '12', period_days: 30, chain_ids: ['8453'] } }
    assert_response :forbidden
    post '/merchant/billing/billing-test/payout_addresses', params: { payout_address: { chain_id: 8453, address: "0x#{'66' * 20}" } }
    assert_response :forbidden
    assert_equal 'Subscription', @plan.reload.name
  end

  test 'merchant selection persists but cannot retarget a form in another tab' do
    other = Billing::MerchantAccount.create!(creator: @seller, public_id: 'another-team', display_name: 'Another')
    sign_in @seller
    post '/merchant/billing/selection', params: { selected_merchant_id: other.public_id }
    assert_redirected_to '/merchant/billing/another-team'
    assert_equal other.id, @seller.reload.last_billing_merchant_id
    patch "/merchant/billing/billing-test/plans/#{@plan.id}", params: { plan: { name: 'Original team', price_usdc: '12', period_days: 30, chain_ids: ['8453'] } }
    assert_redirected_to '/merchant/billing/billing-test/plans'
    assert_equal 'Original team', @plan.reload.name
    assert_empty other.plans
    get "/merchant/billing/another-team/plans/#{@plan.id}/edit"
    assert_response :not_found
    get '/merchant/billing'
    assert_redirected_to '/merchant/billing/another-team'
  end

  test 'merchant switcher separates current identity from available destinations' do
    sign_in @seller
    get '/merchant/billing/billing-test'
    assert_select 'aside > section[data-billing-merchant-selector]' do
      assert_select '[data-billing-current-merchant]', text: 'Merchant'
      assert_select '[popovertarget]', count: 0
    end
    assert_select 'nav [data-billing-merchant-selector]', count: 0

    other = Billing::MerchantAccount.create!(creator: @seller, public_id: 'another-team', display_name: 'Another')
    get '/merchant/billing/billing-test'
    assert_select '[data-billing-current-merchant]', text: 'Merchant'
    assert_select '#billing-merchant-choices[popover]' do
      assert_select '[aria-current=true]', text: /Merchant/
      assert_select 'button[value=billing-test]', count: 0
      assert_select 'button[name=selected_merchant_id][value=another-team]', count: 1
      assert_select 'select', count: 0
    end
    assert_nil @seller.reload.last_billing_merchant_id
    post '/merchant/billing/selection', params: { selected_merchant_id: other.public_id }
    follow_redirect!
    assert_select '[data-billing-current-merchant]', text: 'Another'

    history = Billing::MerchantAccount.create!(creator: @buyer, public_id: 'past-team', display_name: 'Past team')
    Billing::MerchantClosure.start!(merchant: history, actor: @buyer)
    Billing::MerchantClosure.complete!(history)
    sign_in @buyer
    get '/merchant/billing'
    assert_select '[data-billing-current-merchant]', count: 0
    assert_select '[popovertarget=billing-merchant-choices]', text: /#{Regexp.escape(I18n.t('billing.ui.open_merchant_history'))}/
    assert_select '#billing-merchant-choices button[value=past-team]', count: 1
    sign_in @admin
    get '/merchant/billing'
    assert_select '[data-billing-merchant-selector]', count: 0
  end

  test 'removed members cannot use already open edit forms' do
    membership = @merchant.memberships.create!(user: @buyer, role: 'editor')
    sign_in @buyer
    get "/merchant/billing/billing-test/plans/#{@plan.id}/edit"
    assert_response :success
    membership.destroy!
    patch "/merchant/billing/billing-test/plans/#{@plan.id}", params: { plan: { name: 'Denied', price_usdc: '12', period_days: 30, chain_ids: ['8453'] } }
    assert_response :not_found
    assert_equal 'Subscription', @plan.reload.name
  end

  test 'app role revocation reports the merchant administrator invariant on the host detail page' do
    @seller.grant_role!(:admin)
    Billing::Setting.current.update!(admin_only: true)
    sign_in @admin
    delete "/admin/users/#{@seller.id}/roles/admin"
    assert_redirected_to admin_user_path(@seller)
    assert @seller.reload.has_role?(:admin)
    assert_includes flash[:alert], I18n.t('errors.messages.billing_last_administrator')
  end

  test 'undelivered merchant alerts are suppressed after membership removal' do
    membership = @merchant.memberships.create!(user: @buyer, role: 'viewer')
    Billing::Event.merchant!(@merchant, 'held:test', 'collection_held')
    event = Billing::Event.find_by!(user: @buyer)
    membership.destroy!
    assert_no_difference('Notification.count') { event.deliver! }
    assert event.reload.push_processed_at
  end

  test 'changing the public id redirects to the updated merchant URL' do
    sign_in @seller
    patch '/merchant/billing/billing-test/profile', params: { merchant_account: { public_id: 'renamed-team' } }
    assert_redirected_to '/merchant/billing/renamed-team/profile/edit'
    follow_redirect!
    assert_response :success
    assert_equal 'renamed-team', @merchant.reload.public_id
  end

  test 'invitation acceptance and stale cancellation preserve the accepted membership' do
    sign_in @seller
    post '/merchant/billing/billing-test/invitations', params: { invitation: { screen_name: @buyer.profile.screen_name, role: 'editor' } }
    assert_redirected_to '/merchant/billing/billing-test/memberships'
    invitation = @merchant.invitations.sole
    sign_in @buyer
    post "/merchant/billing/invitations/#{invitation.id}/accept"
    assert_redirected_to '/merchant/billing/invitations'
    assert_equal 'editor', @merchant.memberships.find_by!(user: @buyer).role
    sign_in @seller
    delete "/merchant/billing/billing-test/invitations/#{invitation.id}"
    assert_redirected_to '/merchant/billing/billing-test/memberships'
    assert_equal I18n.t('billing.errors.invitation'), flash[:alert]
    assert_equal 'accepted', invitation.reload.status
  end

  test 'repeated closure and reopening a plan during closure are rejected' do
    sign_in @seller
    2.times do
      post '/merchant/billing/billing-test/closure', params: { confirmation: @merchant.display_name }
      assert_redirected_to '/merchant/billing/billing-test'
    end
    assert_equal I18n.t('billing.errors.closure'), flash[:alert]
    assert_equal 'closing', @merchant.reload.status
    patch "/merchant/billing/billing-test/plans/#{@plan.id}", params: { plan: { name: @plan.name, price_usdc: '10', period_days: 30, chain_ids: ['8453'], accepting_subscriptions: '1' } }
    assert_response :unprocessable_content
    assert_not @plan.reload.accepting_subscriptions?
  end

  private

  def settled_charge
    @subscription.charges.create!(period_index: 0, period_start: @subscription.starts_at,
                                  period_end: @subscription.starts_at + 30.days, status: 'settled', amount_units: 10_000_000,
                                  operator_units: 100_000, merchant_units: 9_900_000, fee_basis_points: 100,
                                  operator_address: "0x#{'11' * 20}", merchant_address: "0x#{'66' * 20}")
  end
end
