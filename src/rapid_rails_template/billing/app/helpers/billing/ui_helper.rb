# frozen_string_literal: true

module Billing
  module UiHelper
    ICONS = %w(building-storefront home squares-2x2 credit-card banknotes arrow-uturn-left cog-6-tooth wallet user-circle arrow-top-right-on-square receipt-percent exclamation-triangle check-circle clock document-text).freeze

    def billing_icon(name)
      Kernel.raise ArgumentError, 'unknown billing icon' unless ICONS.include?(name)

      render "billing/icons/#{name}"
    end

    def billing_label(key, icon)
      tag.span(safe_join([billing_icon(icon), tag.span(t("billing.ui.#{key}"), class: 'in-[.link]:underline', data: { billing_label_text: true })]), class: 'inline-flex items-center gap-2')
    end

    def billing_menu_item(key, path, icon, active:)
      tag.li(link_to(billing_label(key, icon), path, class: ('menu-active' if active), aria: { current: ('page' if active) }))
    end

    def billing_amount(units)
      number_with_delimiter(Billing::Amount.format(units).sub(/\.?0+\z/, ''))
    end

    def billing_tabs(section)
      routes = Billing::Engine.routes.url_helpers
      entries = case section
                when :admin
                  [['operations', routes.admin_root_path, 'banknotes', controller_path == 'billing/admin/overview' && action_name == 'show'],
                   ['chain_settings', routes.admin_chain_settings_path, 'wallet', controller_path == 'billing/admin/chains' || action_name == 'chains'],
                   ['merchants', routes.admin_merchants_path, 'building-storefront', controller_path == 'billing/admin/merchants'],
                   ['subscriptions', routes.admin_subscriptions_path, 'credit-card', controller_path.in?(%w(billing/admin/subscriptions billing/admin/refund_records))],
                   ['settings', routes.admin_settings_path, 'cog-6-tooth', controller_path == 'billing/admin/settings']]
                when :merchant_settings
                  [['profile', routes.edit_merchant_profile_path(merchant_id: params[:merchant_id]), 'user-circle', controller_path == 'billing/merchant/merchant_accounts'],
                   ['payouts', routes.merchant_payout_addresses_path(merchant_id: params[:merchant_id]), 'wallet', controller_path == 'billing/merchant/payout_addresses']]
                when :merchant_sales
                  [['subscriptions', routes.merchant_sales_path(merchant_id: params[:merchant_id]), 'credit-card', controller_path == 'billing/merchant/sales'],
                   ['payments', routes.merchant_payments_path(merchant_id: params[:merchant_id]), 'banknotes', controller_path == 'billing/merchant/payments'],
                   ['manual_refunds', routes.merchant_refund_records_path(merchant_id: params[:merchant_id]), 'arrow-uturn-left', controller_path == 'billing/merchant/refund_records']]
                when :public
                  [['plans', routes.plans_path, 'squares-2x2', controller_path == 'billing/plans'],
                   ['merchants', routes.merchants_path, 'building-storefront', controller_path == 'billing/merchants']]
                else
                  Kernel.raise ArgumentError, 'unknown billing tab group'
                end
      entries.map do |key, path, icon, active|
        ::ApplicationHelper::Tab.new(name: billing_label(key, icon), path: path, is_active: -> { active })
      end
    end

    def billing_audit_value(field, value)
      return '—' if value.nil?

      case field
      when 'role' then t("billing.ui.member_roles.#{value}")
      when 'status'
        group = %w(active closing closed).include?(value) ? 'business_states' : 'invitation_states'
        t("billing.ui.#{group}.#{value}")
      when 'amount_units' then "#{billing_amount(value)} USDC"
      when 'fee_basis_points' then "#{Billing::Amount.format(value, decimals: 2)}%"
      when 'chain_id' then Billing::Chains.fetch(value).name
      when 'chain_ids' then value.map { |id| Billing::Chains.fetch(id).name }.join(' / ')
      when 'accepting_subscriptions' then t(value ? 'billing.ui.accepting' : 'billing.ui.closed')
      else value.to_s
      end
    end

    def billing_subscription_state(subscription)
      return 'ended' if subscription.ended_at
      return 'cancelling' if subscription.cancel_requested_at
      return 'grace' if subscription.paid_until && Time.current >= subscription.paid_until && subscription.usable?

      subscription.status
    end
  end
end
