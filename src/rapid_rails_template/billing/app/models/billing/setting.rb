# frozen_string_literal: true

module Billing
  class Setting < ApplicationRecord
    validates :fee_basis_points, numericality: { only_integer: true, in: 0..10_000 }
    validates :grace_hours, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validate :grace_is_shorter_than_periods
    validate :cannot_disable_existing_contracts

    def self.current
      find_by(id: 1) || create_or_find_by!(id: 1)
    end

    def enabled_for?(seller_kind)
      case seller_kind
      when "operator" then operator_enabled?
      when "merchant" then merchants_enabled?
      else raise ArgumentError, "unknown seller kind"
      end
    end

    private
      def grace_is_shorter_than_periods
        return unless grace_hours.is_a?(Integer) && grace_hours >= 0

        seconds = grace_hours * 3600
        if Plan.where(accepting_subscriptions: true).exists?(["period_days * 86400 <= ?", seconds]) ||
            Subscription.where(ended_at: nil).exists?(["period_seconds <= ?", seconds])
          errors.add(:grace_hours, :billing_period)
        end
      end

      def cannot_disable_existing_contracts
        { "operator" => :operator_enabled, "merchant" => :merchants_enabled }.each do |kind, attribute|
          if will_save_change_to_attribute?(attribute) && !public_send(attribute) && Subscription.exists?(seller_kind: kind, ended_at: nil)
            errors.add(attribute, :billing_contracts)
          end
        end
      end
  end
end
