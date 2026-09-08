# frozen_string_literal: true

module Billing
  class ReceiptVerifier
    def initialize(transaction, rpc: Rpc.new(transaction.chain_setting.chain_id))
      @transaction, @rpc = transaction, rpc
    end

    def call
      return if @transaction.finalized_at || @transaction.status == "review"

      @rpc.verify_chain!
      receipt = @rpc.call("eth_getTransactionReceipt", @transaction.transaction_hash)
      return unless receipt

      number = receipt.fetch("blockNumber")
      finalized = @rpc.call("eth_getBlockByNumber", "finalized", false)
      raise VerificationError, "finalized block unavailable" unless finalized
      return if Integer(finalized.fetch("number"), 16) < Integer(number, 16)

      block = @rpc.call("eth_getBlockByNumber", number, false)
      return unless block && block.fetch("hash") == receipt.fetch("blockHash")
      unless receipt.fetch("transactionHash") == @transaction.transaction_hash &&
          receipt.fetch("from").casecmp?(@transaction.signer_address) && receipt.fetch("to").casecmp?(@transaction.to_address)
        raise VerificationError, "receipt identity mismatch"
      end

      success = Integer(receipt.fetch("status"), 16) == 1
      period = verify_effects!(receipt) if success
      @transaction.with_lock do
        return if @transaction.finalized_at

        @transaction.update!(status: success ? "finalized" : "reverted", receipt: receipt, finalized_at: Time.current)
        apply_result!(success, period)
      end
      true
    end

    private
      def verify_effects!(receipt)
        case @transaction.kind
        when "charge" then verify_charge!(receipt)
        when "revoke"
          permission = Contracts.permission_values(@transaction.subscription.permission)
          raise VerificationError, "permission was not revoked" unless @rpc.contract(Chains::MANAGER, "isRevoked", permission, block: receipt.fetch("blockNumber")).first
          nil
        when "deploy"
          settings = @transaction.chain_setting
          unless @rpc.contract(settings.collector_address, "isOwnerAddress", @transaction.signer_address, block: receipt.fetch("blockNumber")).first
            raise VerificationError, "collector owner mismatch"
          end
          nil
        when "void" then nil
        else raise VerificationError, "unknown transaction kind"
        end
      end

      def verify_charge!(receipt)
        subscription = @transaction.subscription
        charge = @transaction.charge
        logs = receipt.fetch("logs")
        topics = [Contracts.topic("SpendPermissionUsed(bytes32,address,address,address,(uint48,uint48,uint160))"),
          subscription.permission_hash, Contracts.address_topic(subscription.payer_address),
          Contracts.address_topic(subscription.permission.fetch("spender"))]
        spends = logs.select { |log| log.fetch("address").casecmp?(Chains::MANAGER) && log.fetch("topics").map(&:downcase) == topics.map(&:downcase) }
        raise VerificationError, "expected exactly one permission spend" unless spends.one?

        token, start, finish, amount = Eth::Abi.decode(%w[address uint48 uint48 uint160], spends.first.fetch("data"))
        chain = Chains.fetch(subscription.chain_id)
        unless token.casecmp?(chain.usdc) && amount == charge.amount_units &&
            start >= subscription.starts_at.to_i && (start - subscription.starts_at.to_i) % subscription.period_seconds == 0 &&
            finish == start + subscription.period_seconds
          raise VerificationError, "permission spend does not match contract"
        end
        expected = Hash.new(0)
        collector = subscription.permission.fetch("spender")
        expected[[subscription.payer_address.downcase, collector.downcase]] += charge.amount_units
        [[charge.operator_address, charge.operator_units], [charge.merchant_address, charge.merchant_units]].each do |address, units|
          expected[[collector.downcase, address.downcase]] += units if units.positive?
        end
        expected.each do |(from, to), units|
          transfer_topics = [Contracts.topic("Transfer(address,address,uint256)"), Contracts.address_topic(from), Contracts.address_topic(to)]
          transferred = logs.select { |log| log.fetch("address").casecmp?(chain.usdc) && log.fetch("topics").map(&:downcase) == transfer_topics }
            .sum { |log| Integer(log.fetch("data"), 16) }
          raise VerificationError, "USDC transfer does not match distribution" unless transferred == units
        end
        [Time.at(start).utc, Time.at(finish).utc]
      end

      def apply_result!(success, period)
        case @transaction.kind
        when "charge"
          charge = @transaction.charge
          subscription = @transaction.subscription
          subscription.lock!
          if success
            charge.update!(status: "settled", settled_at: @transaction.finalized_at,
              settled_period_start: period.first, settled_period_end: period.last, hold_reason: nil)
            subscription.update!(paid_from: period.first, paid_until: period.last,
              status: subscription.cancel_requested_at ? "cancelling" : "active")
            Event.record!("charge:#{charge.id}:settled", user: subscription.user, message: "payment_settled", path: "/account/billing/subscriptions/#{subscription.id}")
            Event.admin!("charge:#{charge.id}:late", "late_period") if period.first != charge.period_start
          else
            charge.update!(status: subscription.cancel_requested_at ? "cancelled" : "held", hold_reason: "reverted", next_attempt_at: 1.hour.from_now)
            Event.record!("charge:#{charge.id}:failed", user: subscription.user, message: "payment_failed", path: "/account/billing/subscriptions/#{subscription.id}")
          end
        when "revoke"
          @transaction.subscription.update!(revoked_at: @transaction.finalized_at) if success
        when "deploy"
          @transaction.chain_setting.update!(verified_at: @transaction.finalized_at) if success
        end
      end
  end
end
