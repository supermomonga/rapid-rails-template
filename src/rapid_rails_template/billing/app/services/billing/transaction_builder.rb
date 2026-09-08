# frozen_string_literal: true

module Billing
  class TransactionBuilder
    def initialize(chain_setting, rpc: Rpc.new(chain_setting.chain_id), signer: Signer.new)
      @settings, @rpc, @signer = chain_setting, rpc, signer
    end

    def charge!(charge, now: Time.current)
      @settings.with_lock do
        subscription = charge.subscription
        subscription.lock!
        charge.reload
        return unless %w[pending held].include?(charge.status)
        return if subscription.cancel_requested_at || subscription.ended_at || subscription.unresolved_transactions?
        return if charge.next_attempt_at && now < charge.next_attempt_at

        deadline = subscription.paid_until ? charge.period_start + Setting.current.grace_hours.hours : charge.period_end
        return if now >= deadline || now >= charge.period_end

        verify_collector!(subscription.permission.fetch("spender"))
        permission = Contracts.permission_values(subscription.permission)
        raise VerificationError, "permission revoked" if @rpc.contract(Chains::MANAGER, "isRevoked", permission).first

        calls = []
        unless @rpc.contract(Chains::MANAGER, "isApproved", permission).first
          calls << [Chains::MANAGER, 0, Contracts.encode("approveWithSignature", permission, subscription.signature)]
        end
        calls << [Chains::MANAGER, 0, Contracts.encode("spend", permission, charge.amount_units)]
        [[charge.operator_address, charge.operator_units], [charge.merchant_address, charge.merchant_units]].each do |address, amount|
          calls << [Chains.fetch(subscription.chain_id).usdc, 0, Contracts.encode("transfer", address, amount)] if amount.positive?
        end
        tx = persist!(kind: "charge", subscription: subscription, charge: charge,
          to: subscription.permission.fetch("spender"), data: Contracts.encode("executeBatch", calls))
        charge.update!(status: "submitted", hold_reason: nil)
        tx
      end
    end

    def revoke!(subscription)
      @settings.with_lock do
        subscription.lock!
        return if subscription.revoked_at || subscription.unresolved_transactions?
        raise Error, "contract is not cancelling" unless subscription.cancel_requested_at

        verify_collector!(subscription.permission.fetch("spender"))
        permission = Contracts.permission_values(subscription.permission)
        if @rpc.contract(Chains::MANAGER, "isRevoked", permission, block: "finalized").first
          subscription.update!(revoked_at: Time.current)
          return
        end
        persist!(kind: "revoke", subscription: subscription, to: subscription.permission.fetch("spender"),
          data: Contracts.encode("executeBatch", [[Chains::MANAGER, 0, Contracts.encode("revokeAsSpender", permission)]]))
      end
    end

    def deploy!
      @settings.with_lock do
        @rpc.verify_contracts!
        if @settings.executor_address.present? && @settings.executor_address != @signer.address
          raise ConfigurationError, "execution key differs from configured owner"
        end
        raise Error, "setup transaction pending" if @settings.transactions.exists?(kind: "deploy", finalized_at: nil)

        owners = ["0x#{@signer.address.delete_prefix('0x').rjust(64, '0')}"]
        predicted = @rpc.contract(Chains::FACTORY, "getAddress", owners, 0).first.downcase
        predicted = "0x#{predicted}" unless predicted.start_with?("0x")
        if @settings.collector_address.present? && @settings.collector_address != predicted
          raise ConfigurationError, "collector differs from factory address"
        end
        @settings.update!(collector_address: predicted, executor_address: @signer.address)
        persist!(kind: "deploy", to: Chains::FACTORY, data: Contracts.encode("createAccount", owners, 0))
      end
    end

    private
      def verify_collector!(collector)
        @rpc.verify_chain!
        unless @settings.executor_address == @signer.address && @settings.collector_address&.casecmp?(collector)
          raise ConfigurationError, "execution key or collector mismatch"
        end
        unless @rpc.contract(collector, "isOwnerAddress", @signer.address).first
          raise VerificationError, "execution key does not own collector"
        end
      end

      def persist!(kind:, to:, data:, subscription: nil, charge: nil)
        ceiling = @settings.gas_ceiling_wei
        raise ConfigurationError, "gas ceiling is required" unless ceiling.present? && ceiling.to_i.positive?

        pending = @rpc.call("eth_getBlockByNumber", "pending", false)
        priority = Integer(@rpc.call("eth_maxPriorityFeePerGas"), 16)
        max_fee = Integer(pending.fetch("baseFeePerGas"), 16) * 2 + priority
        estimate = Integer(@rpc.call("eth_estimateGas", { "from" => @signer.address, "to" => to, "data" => data }), 16)
        gas = (estimate * 120 + 99) / 100
        estimated_fee = gas * max_fee
        raise GasLimitExceeded, "gas estimate exceeds configured ceiling" if estimated_fee > ceiling.to_i

        network_nonce = Integer(@rpc.call("eth_getTransactionCount", @signer.address, "pending"), 16)
        nonce = [network_nonce, @settings.next_nonce || network_nonce].max
        signed = @signer.sign(chain_id: @settings.chain_id, nonce: nonce, to: to, data: data,
          gas_limit: gas, max_fee: max_fee, priority_fee: priority)
        if @settings.chain_id == 8453
          estimated_fee += @rpc.contract("0x420000000000000000000000000000000000000f", "getL1Fee", signed.fetch(:raw)).first
          raise GasLimitExceeded, "gas estimate exceeds configured ceiling" if estimated_fee > ceiling.to_i
        end
        tx = @settings.transactions.create!(kind: kind, subscription: subscription, charge: charge,
          signer_address: @signer.address, nonce: nonce, transaction_hash: signed.fetch(:hash),
          raw_transaction: signed.fetch(:raw), to_address: to, call_data: data, estimated_fee_wei: estimated_fee)
        @settings.update!(next_nonce: nonce + 1)
        tx
      end
  end
end
