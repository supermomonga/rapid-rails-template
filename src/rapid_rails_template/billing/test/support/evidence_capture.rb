# frozen_string_literal: true

class EvidenceCapture
  private

  def capture_billing_scenarios(viewport)
    merchant = Billing::MerchantAccount.find_or_create_by!(public_id: 'sample-studio') do |record|
      record.creator = @user
      record.display_name = 'サンプルスタジオ'
      record.introduction = '制作ノートと学習コンテンツを定期的にお届けします。'
    end
    merchant.update!(image_upload: T.unsafe(Object.const_get('AvatarTestImage')).upload(width: 96, height: 96)) unless merchant.image.attached?
    plan = merchant.plans.find_or_create_by!(name: '制作ノートプラン') do |record|
      record.description = '制作の過程と実践的な学習ノートを公開しています。30日ごとに10 USDCで継続できます。'
      record.amount_units = 10_000_000
      record.period_days = 30
      record.chain_ids = [42161, 8453, 1, 137]
    end
    routes = Billing::Engine.routes.url_helpers
    Capybara.reset_sessions!
    viewport_size = VIEWPORTS.fetch(viewport)
    page.current_window.resize_to(viewport_size.fetch('width'), viewport_size.fetch('height'))
    capture_page('billing-plans', 'サブスクリプションプラン一覧', routes.plans_path, translate('billing.ui.plans'), viewport)
    capture_page('billing-merchants', '販売者一覧', routes.merchants_path, translate('billing.ui.merchants'), viewport)
    capture_page('billing-merchant', '販売者ページ', routes.merchant_path(merchant.public_id), merchant.display_name, viewport)
    capture_page('billing-plan-unavailable', '受付できないプラン', routes.plan_path(plan), plan.name, viewport)
    authenticate
    capture_page('billing-merchant-overview-empty', '販売者画面・初回の販売準備', routes.merchant_dashboard_path(merchant_id: merchant.public_id), translate('billing.ui.merchant_area'), viewport)
    capture_page('billing-merchant-edit', '販売者プロフィール', routes.edit_merchant_profile_path(merchant_id: merchant.public_id), translate('billing.ui.merchant_settings'), viewport)
    capture_page('billing-payouts', 'チェーン別の販売者送金先', routes.merchant_payout_addresses_path(merchant_id: merchant.public_id), translate('billing.ui.merchant_settings'), viewport)
    capture_page('billing-seller-plans', '販売プラン一覧', routes.merchant_plans_path(merchant_id: merchant.public_id), translate('billing.ui.seller_plans'), viewport)
    capture_page('billing-plan-new', '販売プラン作成', routes.new_merchant_plan_path(merchant_id: merchant.public_id), translate('billing.ui.new_plan'), viewport)
    capture_page('billing-plan-edit', '販売プラン編集', routes.edit_merchant_plan_path(plan, merchant_id: merchant.public_id), translate('billing.ui.edit_plan'), viewport)
    capture_page('billing-settings', '決済設定（独立した3設定）', routes.admin_settings_path, translate('billing.ui.settings'), viewport)
    capture_page('billing-setup', '決済運用（設定不足・チェーン設定）', routes.admin_root_path, translate('billing.ui.overview'), viewport)
    capture_page('billing-chain-settings', 'チェーン別の運営設定', routes.admin_chain_settings_path, translate('billing.ui.chain_settings'), viewport)
    capture_page('billing-admin-merchants', '販売者の横断閲覧', routes.admin_merchants_path, translate('billing.ui.merchants'), viewport)
    capture_page('billing-admin-merchant-fee', '販売者別の運営手数料', routes.admin_merchant_path(merchant), merchant.display_name, viewport)
    contract = billing_evidence_contract(plan, viewport)
    capture_page('billing-pending', '契約（初回支払・署名待ち）', routes.account_subscription_path(contract), translate('billing.ui.contract', id: contract.id), viewport)
    assert_selector '[data-billing-checkout-target="review"]', visible: true
    assert_selector '[data-billing-checkout-target="terms"]', text: '10.000000 USDC'
    page.execute_script(<<~JAVASCRIPT)
      window.createBaseAccountSDK = () => ({ getProvider: () => ({ request: async () => ["0x9999999999999999999999999999999999999999"] }) })
    JAVASCRIPT
    click_button translate('billing.ui.authorize_payment')
    assert_selector '[data-billing-checkout-target="message"]', text: translate('billing.checkout.wrongWallet')
    assert_nil contract.reload.signature
    capture_current_page('billing-wallet-mismatch', '契約時と異なるウォレットの拒否', viewport)
    contract.update!(signature: '0xabcd', status: 'active', paid_from: contract.starts_at, paid_until: contract.starts_at + 30.days)
    charge = contract.charges.create!(period_index: 0, period_start: contract.starts_at, period_end: contract.starts_at + 30.days,
                                      status: 'settled', amount_units: 10_000_000, operator_units: 100_000, merchant_units: 9_900_000,
                                      fee_basis_points: 100, operator_address: "0x#{'11' * 20}", merchant_address: "0x#{'22' * 20}", settled_at: Time.current)
    charge.refund_records.create!(amount_units: 1_000_000, reason: '重複購入分を外部ウォレットから手動で返金しました。', chain_id: 8453, transaction_hash: "0x#{'aa' * 32}")
    capture_page('billing-active-refund', '購入者の決済履歴・手動返金の記録', routes.account_subscription_path(contract, tab: 'payments'), translate('billing.ui.contract', id: contract.id), viewport)
    capture_page('billing-merchant-overview', '販売者画面・売上概要', routes.merchant_dashboard_path(merchant_id: merchant.public_id), translate('billing.ui.merchant_area'), viewport)
    capture_page('billing-subscriptions', '購入者の契約一覧', routes.account_subscriptions_path, translate('billing.ui.subscriptions'), viewport)
    capture_page('billing-sales', '販売契約一覧', routes.merchant_sales_path(merchant_id: merchant.public_id), translate('billing.ui.sales'), viewport)
    capture_page('billing-payments', '販売者の決済履歴', routes.merchant_payments_path(merchant_id: merchant.public_id), translate('billing.ui.sales'), viewport)
    capture_page('billing-refunds', '販売者の手動返金履歴', routes.merchant_refund_records_path(merchant_id: merchant.public_id), translate('billing.ui.sales'), viewport)
    capture_page('billing-sale', '販売契約詳細', routes.merchant_sale_path(contract, merchant_id: merchant.public_id), translate('billing.ui.contract', id: contract.id), viewport)
    capture_page('billing-refund-new', '手動返金の記録フォーム', routes.new_merchant_charge_refund_record_path(charge, merchant_id: merchant.public_id), translate('billing.ui.manual_refund'), viewport)
    fill_in translate('billing.ui.refund_amount'), with: '1'
    fill_in translate('billing.ui.reason'), with: '送金済みの返金を記録します。'
    fill_in translate('billing.ui.transaction_hash'), with: 'invalid'
    click_button translate('billing.ui.record_refund')
    assert_selector '.alert-error'
    assert_field translate('billing.ui.transaction_hash'), with: 'invalid'
    capture_current_page('billing-refund-invalid', '手動返金の入力エラーと値の保持', viewport)
    capture_merchant_membership_scenarios(merchant, routes, viewport)
    verify_billing_navigation(routes, viewport, merchant)
    capture_page('billing-admin-subscriptions', '管理者の契約一覧', routes.admin_subscriptions_path, translate('billing.ui.subscriptions'), viewport)
    capture_page('billing-admin-subscription', '管理者の契約・決済詳細', routes.admin_subscription_path(contract), translate('billing.ui.contract', id: contract.id), viewport)
    travel_to contract.paid_until + 1.hour do
      renewal = contract.charges.create!(period_index: 1, period_start: contract.paid_until, period_end: contract.paid_until + 30.days,
                                         status: 'held', hold_reason: 'receipt_verification', amount_units: 10_000_000, operator_units: 100_000,
                                         merchant_units: 9_900_000, fee_basis_points: 100, operator_address: "0x#{'11' * 20}", merchant_address: "0x#{'22' * 20}")
      transaction = renewal.transactions.create!(subscription: contract, chain_setting: Billing::ChainSetting.for_chain(8453),
                                                 kind: 'charge', status: 'review', signer_address: "0x#{'33' * 20}", nonce: viewport == 'desktop' ? 0 : 1,
                                                 transaction_hash: "0x#{viewport == 'desktop' ? 'bb' * 32 : 'cc' * 32}", raw_transaction: '0x00', to_address: "0x#{'22' * 20}",
                                                 call_data: '0x', estimated_fee_wei: 1, error_code: 'receipt_verification')
      capture_page('billing-grace', '契約（更新猶予中）', routes.account_subscription_path(contract), translate('billing.ui.contract', id: contract.id), viewport)
      capture_page('billing-review-held', '決済運用（未確定・要確認・送信保留）', routes.admin_root_path, translate('billing.ui.overview'), viewport)
      transaction.update!(status: 'reverted', finalized_at: Time.current)
    end
    capture_page('billing-cancellation', '契約の解約確認', routes.cancellation_account_subscription_path(contract), translate('billing.ui.cancel_subscription'), viewport)
    contract.update!(cancel_requested_at: Time.current, status: 'cancelling')
    capture_page('billing-cancelled-access', '解約後の支払済み利用期間', routes.account_subscription_path(contract), translate('billing.ui.contract', id: contract.id), viewport)
    travel_to contract.paid_until + 1.hour do
      contract.update!(ended_at: Time.current, revoked_at: Time.current, status: 'ended')
      capture_page('billing-ended', '契約終了・許可取消済み', routes.account_subscription_path(contract), translate('billing.ui.contract', id: contract.id), viewport)
    end
    Capybara.reset_sessions!
    page.current_window.resize_to(viewport_size.fetch('width'), viewport_size.fetch('height'))
    login_as(@regular_user, scope: :user)
    capture_page('billing-merchant-new', '販売者登録', routes.new_merchant_account_path, translate('billing.ui.merchant_registration'), viewport)
    Capybara.reset_sessions!
    page.current_window.resize_to(viewport_size.fetch('width'), viewport_size.fetch('height'))
    authenticate
    if viewport == 'mobile'
      visit routes.account_subscriptions_path
      assert_selector '[data-with-menu-items] a.menu-active', text: translate('billing.ui.subscriptions')
      find('header details.dropdown > summary', visible: :visible).click
      capture_current_page('billing-navigation-open', '決済画面のモバイルメニュー', viewport)
    end
  end

  def capture_merchant_membership_scenarios(merchant, routes, viewport)
    viewport_size = VIEWPORTS.fetch(viewport)
    editor = User.create!
    T.must(editor.profile).update!(display_name: "制作担当 #{viewport}")
    merchant.memberships.create!(user: editor, role: 'editor')
    merchant.memberships.find_or_create_by!(user: @regular_user) { |member| member.role = 'viewer' }
    guest = User.create!
    T.must(guest.profile).update!(display_name: "参加予定メンバー #{viewport}")
    Billing::Invitations.create!(merchant: merchant, actor: @user, screen_name: T.must(guest.profile).screen_name, role: 'editor')
    second = Billing::MerchantAccount.create!(creator: @user, public_id: "shared-#{viewport}", display_name: "共同運営チーム #{viewport}")
    closed = Billing::MerchantAccount.create!(creator: @user, public_id: "closed-#{viewport}", display_name: "活動を終えた販売者 #{viewport}")
    Billing::MerchantClosure.start!(merchant: closed, actor: @user)
    Billing::MerchantClosure.complete!(closed)
    capture_page('billing-members', '販売者メンバー・役割・招待管理', routes.merchant_memberships_path(merchant_id: merchant.public_id), translate('billing.ui.members'), viewport)
    capture_page('billing-audit', '通知と独立した販売者操作履歴', routes.merchant_audit_entries_path(merchant_id: merchant.public_id), translate('billing.ui.audit_entries'), viewport)
    capture_page('billing-closure', '販売者の閉鎖確認', routes.merchant_closure_path(merchant_id: merchant.public_id), translate('billing.ui.close_merchant'), viewport)
    capture_page('billing-closed-merchant', '閉鎖済み販売者の履歴と切り替え', routes.merchant_dashboard_path(merchant_id: closed.public_id), translate('billing.ui.merchant_area'), viewport)
    assert_no_link translate('billing.ui.complete_payouts')
    Billing::MerchantClosure.start!(merchant: second, actor: @user)
    capture_page('billing-closing-merchant', '閉鎖処理中の販売者', routes.merchant_dashboard_path(merchant_id: second.public_id), translate('billing.ui.merchant_area'), viewport)
    Capybara.reset_sessions!
    login_as(@regular_user, scope: :user)
    page.current_window.resize_to(viewport_size.fetch('width'), viewport_size.fetch('height'))
    capture_page('billing-viewer-members', '閲覧者によるメンバー確認', routes.merchant_memberships_path(merchant_id: merchant.public_id), translate('billing.ui.members'), viewport)
    assert_no_button translate('billing.ui.change_role')
    Capybara.reset_sessions!
    login_as(guest, scope: :user)
    page.current_window.resize_to(viewport_size.fetch('width'), viewport_size.fetch('height'))
    capture_page('billing-invitations', '本人による招待の承諾・拒否', routes.merchant_invitations_path, translate('billing.ui.invitations'), viewport)
    history = Billing::MerchantAccount.create!(creator: guest, public_id: "history-#{viewport}", display_name: '以前の販売活動')
    Billing::MerchantClosure.start!(merchant: history, actor: guest)
    Billing::MerchantClosure.complete!(history)
    capture_page('billing-merchant-entry', '販売者の作成・招待・閉鎖済み履歴への入口', routes.merchant_root_path, translate('billing.ui.merchant_area'), viewport)
    Billing::Setting.current.update!(admin_only: true)
    capture_page('billing-merchant-restricted', 'アプリ管理者限定による販売者機能の利用制限', routes.merchant_root_path, translate('billing.ui.merchant_area'), viewport)
    assert_no_link translate('billing.ui.merchant_registration')
    Billing::Setting.current.update!(admin_only: false)
    Capybara.reset_sessions!
    authenticate
    page.current_window.resize_to(viewport_size.fetch('width'), viewport_size.fetch('height'))
  end

  def assert_billing_geometry(viewport)
    geometry = page.evaluate_script(<<~JAVASCRIPT)
      (() => {
        const textBox = element => { const range = document.createRange(); range.selectNodeContents(element); return range.getBoundingClientRect(); };
        return {
          width: document.documentElement.scrollWidth, viewport: innerWidth,
          amountsFit: [...document.querySelectorAll('[data-billing-amount]')].every(element => {
            const text = textBox(element), box = element.getBoundingClientRect();
            return text.left >= box.left && text.right <= box.right && text.height <= parseFloat(getComputedStyle(element).lineHeight) + 1;
          }),
          statesFit: [...document.querySelectorAll('[data-billing-state]')].every(element => {
            const text = textBox(element), box = element.getBoundingClientRect();
            return text.top >= box.top && text.bottom <= box.bottom;
          }),
          menuIcons: [...document.querySelectorAll('[data-with-menu-items] > li > a')].every(link => !!link.querySelector('svg[aria-hidden="true"]')),
          linksUnderlined: [...document.querySelectorAll('.link [data-billing-label-text]')].every(label => getComputedStyle(label).textDecorationLine.includes('underline')),
          tabs: [...document.querySelectorAll('[role="tablist"]')].map(list => {
            const tabs = [...list.querySelectorAll(':scope > [role="tab"]')].map(tab => tab.getBoundingClientRect());
            const active = list.querySelector(':scope > [aria-selected="true"]');
            const box = active.getBoundingClientRect(), panel = active.nextElementSibling.getBoundingClientRect();
            return { rowDelta: Math.max(...tabs.map(tab => tab.top)) - Math.min(...tabs.map(tab => tab.top)), connection: Math.abs(box.bottom - panel.top), activeZ: Number(getComputedStyle(active).zIndex) || 0, panelZ: Number(getComputedStyle(active.nextElementSibling).zIndex) || 0, visible: box.left >= 0 && box.right <= innerWidth };
          })
        };
      })()
    JAVASCRIPT
    assert_equal VIEWPORTS.fetch(viewport).fetch('width'), geometry.fetch('viewport')
    assert_operator geometry.fetch('width'), :<=, geometry.fetch('viewport')
    assert geometry.fetch('amountsFit'), 'billing amounts must be readable without horizontal scrolling'
    assert geometry.fetch('statesFit'), 'billing state text must fit inside badges'
    assert geometry.fetch('menuIcons'), 'every application menu destination needs an icon'
    assert geometry.fetch('linksUnderlined'), 'icon labels in text links must remain underlined without hover'
    geometry.fetch('tabs').each do |tab|
      assert_operator tab.fetch('rowDelta'), :<=, 1
      assert_operator tab.fetch('connection'), :<=, 2
      assert_operator tab.fetch('activeZ'), :>, tab.fetch('panelZ')
      assert tab.fetch('visible'), 'active billing tab must remain visible'
    end
    unless page.has_css?('header details[open]', wait: 0)
      covers_edges = page.evaluate_script(<<~JAVASCRIPT)
        (() => {
          const position = { left: scrollX, top: scrollY };
          const covered = [...document.querySelectorAll('[role="tablist"] > [aria-selected="true"]')].every(active => {
            active.scrollIntoView({ block: 'center', inline: 'nearest', behavior: 'instant' });
            const box = active.getBoundingClientRect(), panel = active.nextElementSibling.getBoundingClientRect();
            const topmost = document.elementFromPoint((box.left + box.right) / 2, panel.top + 0.5);
            return active.contains(topmost);
          });
          window.scrollTo({ ...position, behavior: 'instant' });
          return covered;
        })()
      JAVASCRIPT
      assert covers_edges, 'active tab must cover the shared panel border'
    else
      menu_on_top = page.evaluate_script(<<~JAVASCRIPT)
        [...document.querySelectorAll('header details[open] .dropdown-content a')].every(link => {
          const box = link.getBoundingClientRect();
          return [0.1, 0.5, 0.9].every(x => [0.2, 0.5, 0.8].every(y =>
            link.contains(document.elementFromPoint(box.left + box.width * x, box.top + box.height * y))));
        })
      JAVASCRIPT
      assert menu_on_top, 'open header menu links must stay above page tabs'
    end
  end

  def verify_billing_navigation(routes, viewport, merchant)
    visit routes.merchant_sales_path(merchant_id: merchant.public_id)
    assert_selector '[data-with-menu-items] a[aria-current="page"]', text: translate('billing.ui.sales')
    if viewport == 'desktop'
      [320, 390, 640, 960, 961].each do |width|
        page.current_window.resize_to(width, 900)
        geometry = page.evaluate_script(<<~JAVASCRIPT)
          (() => {
            const shell = document.querySelector('[data-layout="with-menu"]');
            const aside = shell.querySelector('aside').getBoundingClientRect();
            const content = shell.lastElementChild.getBoundingClientRect();
            return { width: document.documentElement.scrollWidth, viewport: innerWidth, sideBySide: aside.right <= content.left };
          })()
        JAVASCRIPT
        assert_operator geometry.fetch('width'), :<=, width
        assert_equal width >= 961, geometry.fetch('sideBySide')
      end
      page.current_window.resize_to(VIEWPORTS.fetch(viewport).fetch('width'), VIEWPORTS.fetch(viewport).fetch('height'))
    else
      find('header details.dropdown > summary', visible: :visible).click
      assert_selector 'header a', text: translate('billing.ui.back_account')
      capture_current_page('billing-merchant-navigation-open', '販売者画面のモバイルメニュー', viewport)
    end
  end

  def billing_evidence_contract(plan, viewport)
    now = (30.days.ago + 1.hour).change(usec: 0)
    permission = { 'account' => "0x#{'44' * 20}", 'spender' => "0x#{'33' * 20}", 'token' => Billing::Chains.fetch(8453).usdc,
                   'allowance' => '10000000', 'period' => '2592000', 'start' => now.to_i.to_s, 'end' => ((2**48) - 1).to_s,
                   'salt' => (viewport == 'desktop' ? '1' : '2'), 'extraData' => '0x', }
    plan.subscriptions.create!(user: @user, buyer_name: 'Evidence User', seller_name: plan.seller_name, plan_name: plan.name, chain_id: 8453, payer_address: permission.fetch('account'), amount_units: 10_000_000, period_seconds: 30 * 86400, starts_at: now, permission: permission, permission_hash: "0x#{viewport == 'desktop' ? 'dd' * 32 : 'ee' * 32}")
  end
end
