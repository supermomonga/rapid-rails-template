# frozen_string_literal: true

module Billing
  module MerchantRecord
    extend ActiveSupport::Concern

    included do
      T.bind(self, T.class_of(ActiveRecord::Base))
      class_attribute :audit_fields, default: []
      around_save :save_merchant_record
    end

    private

    def save_merchant_record
      T.bind(self, T.any(Plan, PayoutAddress, RefundRecord))
      merchant = billing_merchant
      MerchantAccess.synchronize(merchant) do
        MerchantAccess.authorize!(Current.actor, merchant, billing_permission) if Current.actor
        if is_a?(Plan)
          valid_terms
          creation_enabled if new_record?
          raise ActiveRecord::RecordInvalid, self if errors.any?
        end
        yield
        changes = saved_changes.slice(*audit_fields).except('updated_at', 'created_at')
        unless changes.empty?
          AuditEntry.record!(merchant: merchant, target: self, action: "#{self.class.model_name.element}.changed",
                             before_values: changes.transform_values(&:first), after_values: changes.transform_values(&:last))
        end
      end
    end

    def billing_merchant
      T.bind(self, T.any(Plan, PayoutAddress))
      T.must(merchant_account)
    end

    def billing_permission
      :edit
    end
  end
end
