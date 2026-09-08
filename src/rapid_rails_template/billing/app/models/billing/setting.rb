# frozen_string_literal: true

module Billing
  class Setting < ApplicationRecord
    validates :fee_basis_points, numericality: { only_integer: true, in: 0..10_000 }
    validates :grace_hours, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validate :grace_is_shorter_than_periods
    validate :cannot_disable_existing_contracts
    around_save :save_settings

    def self.current
      find_by(id: 1) || create_or_find_by!(id: 1)
    end

    private

    def save_settings
      if new_record?
        yield
      else
        self.class.find(id).with_lock do
          cannot_disable_existing_contracts
          grace_is_shorter_than_periods
          MerchantAccess.validate_administrators!(self, setting: self)
          raise ActiveRecord::RecordInvalid, self if errors.any?

          yield
        end
      end
    end

    def grace_is_shorter_than_periods
      return unless grace_hours.is_a?(Integer) && grace_hours >= 0

      seconds = grace_hours * 3600
      if Plan.where(accepting_subscriptions: true).exists?(['period_days * 86400 <= ?', seconds]) ||
         Subscription.where(ended_at: nil).exists?(['period_seconds <= ?', seconds])
        errors.add(:grace_hours, :billing_period)
      end
    end

    def cannot_disable_existing_contracts
      if will_save_change_to_payments_enabled? && !payments_enabled? &&
         (Subscription.exists?(ended_at: nil) || Subscription.exists?(['paid_until > ?', Time.current]) || Transaction.exists?(finalized_at: nil))
        errors.add(:payments_enabled, :billing_contracts)
      end
    end
  end
end
