# frozen_string_literal: true

module Billing
  module Merchant
    class AuditEntriesController < BaseController
      def index
        @pagy, @entries = pagy(:offset, merchant_account.audit_entries.order(id: :desc))
      end
    end
  end
end
