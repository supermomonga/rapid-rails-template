# frozen_string_literal: true

module Billing
  class ReconcileJob < ::ApplicationJob
    def perform
      Transaction.where(finalized_at: nil).where.not(status: 'review').order(:id).find_each do |transaction|
        process_transaction(transaction)
      end
      Subscription.where(ended_at: nil).find_each { |subscription| process_subscription(subscription) }
      MerchantAccount.where(status: 'closing').find_each { |merchant| MerchantClosure.complete!(merchant) }
      Event.where(push_processed_at: nil).find_each(&:deliver!)
    end

    private

    def process_transaction(transaction)
      rpc = Rpc.new(transaction.chain_setting.chain_id)
      return if ReceiptVerifier.new(transaction, rpc: rpc).call

      Broadcaster.call(transaction, rpc: rpc)
    rescue VerificationError
      transaction.update!(status: 'review', error_code: 'verification')
      Event.admin!("tx:#{transaction.id}:verification", 'verification_failed')
      Event.merchant!(transaction.subscription.plan.merchant_account, "tx:#{transaction.id}:verification", 'verification_failed') if transaction.subscription
    rescue RpcError, ConfigurationError
      Event.admin!("tx:#{transaction.id}:connection", 'connection_failed')
    end

    def process_subscription(subscription)
      now = Time.current
      MerchantAccess.synchronize(subscription.plan.merchant_account) do
        subscription.lock!
        grace = Setting.current.grace_hours.hours
        deadline = subscription.paid_until ? subscription.paid_until + grace : subscription.starts_at + subscription.period_seconds
        if !subscription.cancel_requested_at && now >= deadline
          subscription.update!(cancel_requested_at: now, status: 'cancelling')
          Event.record!("subscription:#{subscription.id}:expired", user: subscription.user, message: 'contract_expired', path: "/account/billing/subscriptions/#{subscription.id}")
        end
        if subscription.cancel_requested_at && subscription.revoked_at && !subscription.unresolved_transactions? &&
           (!subscription.paid_until || now >= subscription.paid_until)
          subscription.update!(status: 'ended', ended_at: now)
          return
        end
      end
      return if subscription.unresolved_transactions?

      chain = ChainSetting.for_chain(subscription.chain_id)
      rpc = Rpc.new(subscription.chain_id)
      permission = Contracts.permission_values(subscription.permission)
      if rpc.contract(Chains::MANAGER, 'isRevoked', permission, block: 'finalized').first
        MerchantAccess.synchronize(subscription.plan.merchant_account) do
          subscription.lock!
          subscription.update!(cancel_requested_at: subscription.cancel_requested_at || now, revoked_at: subscription.revoked_at || now, status: 'cancelling')
        end
        return
      end
      builder = TransactionBuilder.new(chain, rpc: rpc)
      if subscription.cancel_requested_at
        builder.revoke!(subscription)
      else
        charge = ChargeBuilder.call(subscription, now: now)
        builder.charge!(charge, now: now) if charge
      end
    rescue GasLimitExceeded, RpcError, ConfigurationError => e
      if charge
        charge.update!(status: 'held', hold_reason: T.must(e.class.name).demodulize, next_attempt_at: 1.hour.from_now)
        Event.record!("charge:#{charge.id}:held", user: subscription.user, message: 'payment_failed', path: "/account/billing/subscriptions/#{subscription.id}")
      end
      Event.admin!("subscription:#{subscription.id}:#{e.class.name}", 'collection_held')
      incident = charge ? "charge:#{charge.id}" : "subscription:#{subscription.id}:period:#{subscription.period_index(now)}"
      Event.merchant!(subscription.plan.merchant_account, "#{incident}:#{e.class.name}", 'collection_held')
    rescue VerificationError
      Event.admin!("subscription:#{subscription.id}:verification", 'verification_failed')
      Event.merchant!(subscription.plan.merchant_account, "subscription:#{subscription.id}:verification", 'verification_failed')
    end
  end
end
