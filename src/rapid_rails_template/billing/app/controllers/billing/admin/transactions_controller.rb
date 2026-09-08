# frozen_string_literal: true

module Billing
  module Admin
    class TransactionsController < BaseController
      def recheck
        transaction = Transaction.find(params.expect(:id))
        transaction.with_lock do
          transaction.update!(status: "submitted", error_code: nil) if transaction.status == "review" && !transaction.finalized_at
        end
        ReconcileJob.perform_later
        redirect_to admin_root_path, notice: I18n.t("billing.recheck_requested")
      end
    end
  end
end
