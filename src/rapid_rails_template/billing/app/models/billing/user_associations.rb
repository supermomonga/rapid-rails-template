# frozen_string_literal: true

module Billing
  module UserAssociations
    extend ActiveSupport::Concern

    included do
      T.bind(self, T.class_of(::User))
      has_many :merchant_memberships, class_name: 'Billing::MerchantMembership', dependent: :restrict_with_error
      has_many :merchant_accounts, through: :merchant_memberships, class_name: 'Billing::MerchantAccount'
      belongs_to :last_billing_merchant, class_name: 'Billing::MerchantAccount', optional: true
      has_many :billing_subscriptions, class_name: 'Billing::Subscription', dependent: :nullify
      has_many :billing_events, class_name: 'Billing::Event', dependent: :destroy
      has_many :billing_received_invitations, class_name: 'Billing::MerchantInvitation', foreign_key: :recipient_id, dependent: :nullify
      has_many :billing_sent_invitations, class_name: 'Billing::MerchantInvitation', foreign_key: :inviter_id, dependent: :nullify
      has_many :billing_audit_entries, class_name: 'Billing::AuditEntry', foreign_key: :actor_id, dependent: :nullify
      before_destroy :ensure_billing_contracts_ended, prepend: true
      around_destroy :serialize_billing_deletion, prepend: true
    end

    private

    def ensure_billing_contracts_ended
      T.bind(self, ::User)
      if AccountDeletion.blocked?(self)
        errors.add(:base, I18n.t('billing.errors.active_contracts'))
        throw :abort
      end
    end

    def serialize_billing_deletion
      MerchantAccess.synchronize { yield }
    end
  end
end
