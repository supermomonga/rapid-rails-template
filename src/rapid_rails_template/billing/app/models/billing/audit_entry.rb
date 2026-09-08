# frozen_string_literal: true

module Billing
  class AuditEntry < ApplicationRecord
    belongs_to :merchant_account
    belongs_to :actor, class_name: '::User', optional: true

    def self.record!(merchant:, target:, action:, before_values: {}, after_values: {})
      actor = Current.actor
      create!(merchant_account: merchant, actor: actor,
              actor_name: actor ? actor.profile.display_name : I18n.t('billing.ui.system_actor'),
              action: action, target_type: target.class.name, target_id: target.id,
              before_values: before_values, after_values: after_values)
    end

    def readonly?
      persisted?
    end
  end
end
