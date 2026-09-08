# frozen_string_literal: true

module Billing
  class Event < ApplicationRecord
    belongs_to :user, class_name: '::User', optional: true
    belongs_to :merchant_account, optional: true

    def self.record!(key, user:, message:, path:, merchant: nil)
      return unless user

      create_or_find_by!(event_key: key) do |event|
        event.user = user
        event.message_key = message
        event.path = path
        event.merchant_account = merchant
      end
    end

    def self.admin!(key, message)
      ::User.where(id: ::UserRole.admin.select(:user_id)).find_each do |user|
        record!("#{key}:#{user.id}", user: user, message: message, path: '/admin/billing')
      end
    end

    def self.merchant!(merchant, key, message)
      users = merchant.users
      users = users.where(id: ::UserRole.admin.select(:user_id)) if Setting.current.admin_only?
      users.find_each do |user|
        record!("merchant:#{merchant.id}:#{key}:#{user.id}", user: user, message: message, merchant: merchant,
                                                             path: "/merchant/billing/#{merchant.public_id}/payments")
      end
    end

    def deliver!
      with_lock do
        return unless user
        if merchant_account && !MerchantAccess.allowed?(user, merchant_account)
          update!(delivered_at: Time.current, push_processed_at: Time.current)
          return
        end

        unless delivered_at
          notification = ::Notification.new(audience: 'selected_users', draft: false, published_at: Time.current)
          notification.message = "#{I18n.t("billing.notifications.#{message_key}")} #{path}"
          notification.save_with_delivery_synchronization!(recipient_ids: [T.must(user_id)])
          update!(delivered_at: Time.current)
        end
      end
      with_lock do
        return if push_processed_at || !user
        if merchant_account && !MerchantAccess.allowed?(user, merchant_account)
          update!(push_processed_at: Time.current)
          return
        end

        delivery = Rails.configuration.x.billing.push_delivery
        if delivery
          delivery.call(user: user, title: I18n.t('billing.title'),
                        body: I18n.t("billing.notifications.#{message_key}"), path: path, tag: "billing-#{id}")
        end
        update!(push_processed_at: Time.current)
      end
    end
  end
end
