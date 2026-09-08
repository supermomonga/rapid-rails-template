# frozen_string_literal: true

module Billing
  class Broadcaster
    def self.call(transaction, rpc: Rpc.new(transaction.chain_setting.chain_id), now: Time.current)
      transaction.chain_setting.with_lock do
        transaction.lock!
        return if transaction.finalized_at || transaction.status == "review"

        if transaction.kind == "charge" && !transaction.broadcast_started_at
          subscription = transaction.subscription
          subscription.lock!
          deadline = subscription.paid_until ? transaction.charge.period_start + Setting.current.grace_hours.hours : transaction.charge.period_end
          if subscription.cancel_requested_at || subscription.ended_at || now >= deadline
            void_before_broadcast!(transaction)
          end
        end
        transaction.update!(broadcast_started_at: transaction.broadcast_started_at || now, status: "submitted")
      end
      # The durable marker precedes this call: a crash or timeout is ambiguous, never a failed payment.
      hash = rpc.call("eth_sendRawTransaction", transaction.raw_transaction)
      raise VerificationError, "broadcast hash mismatch" unless hash == transaction.transaction_hash

      transaction
    end

    def self.void_before_broadcast!(transaction)
      signer = Signer.new
      raise ConfigurationError, "execution key mismatch" unless signer.address == transaction.signer_address

      original = Eth::Tx.decode(transaction.raw_transaction)
      signed = signer.sign(chain_id: transaction.chain_setting.chain_id, nonce: transaction.nonce,
        to: signer.address, data: "0x", gas_limit: 21_000, max_fee: original.max_fee_per_gas, priority_fee: original.max_priority_fee_per_gas)
      transaction.update!(kind: "void", to_address: signer.address, call_data: "0x",
        superseded_payload: { "hash" => transaction.transaction_hash, "raw" => transaction.raw_transaction,
          "to" => transaction.to_address, "data" => transaction.call_data },
        transaction_hash: signed.fetch(:hash), raw_transaction: signed.fetch(:raw))
      transaction.charge.update!(status: "cancelled")
    end
    private_class_method :void_before_broadcast!
  end
end
