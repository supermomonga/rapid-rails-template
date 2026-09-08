# frozen_string_literal: true

class CreateBilling < ActiveRecord::Migration[8.1]
  def change
    create_table :billing_settings do |t|
      t.boolean :payments_enabled, null: false, default: true
      t.boolean :admin_only, null: false, default: false
      t.boolean :merchant_plan_creation_enabled, null: false, default: true
      t.integer :fee_basis_points, null: false, default: 100
      t.integer :grace_hours, null: false, default: 72
      t.timestamps
    end
    add_check_constraint :billing_settings, 'id = 1', name: 'billing_single_settings'
    add_check_constraint :billing_settings, 'fee_basis_points BETWEEN 0 AND 10000 AND grace_hours >= 0', name: 'billing_settings_ranges'

    create_table :billing_chain_settings do |t|
      t.integer :chain_id, null: false
      t.string :treasury_address
      t.string :collector_address
      t.string :executor_address
      t.string :gas_ceiling_wei
      t.integer :next_nonce
      t.datetime :verified_at
      t.timestamps
    end
    add_index :billing_chain_settings, :chain_id, unique: true
    add_check_constraint :billing_chain_settings, 'chain_id IN (1, 137, 8453, 42161)', name: 'billing_supported_chain'

    create_table :billing_merchant_accounts do |t|
      t.string :public_id, null: false
      t.string :display_name, null: false
      t.text :introduction, null: false, default: ''
      t.string :status, null: false, default: 'active'
      t.integer :fee_basis_points
      t.datetime :closed_at
      t.timestamps
    end
    add_index :billing_merchant_accounts, :public_id, unique: true
    add_check_constraint :billing_merchant_accounts, "status IN ('active', 'closing', 'closed')", name: 'billing_merchant_status'
    add_check_constraint :billing_merchant_accounts, 'fee_basis_points IS NULL OR fee_basis_points BETWEEN 0 AND 10000', name: 'billing_merchant_fee'
    add_reference :users, :last_billing_merchant, foreign_key: { to_table: :billing_merchant_accounts }

    create_table :billing_merchant_memberships do |t|
      t.references :merchant_account, null: false, foreign_key: { to_table: :billing_merchant_accounts }
      t.references :user, null: false, foreign_key: true
      t.string :role, null: false
      t.timestamps
    end
    add_index :billing_merchant_memberships, [:merchant_account_id, :user_id], unique: true, name: 'billing_unique_membership'
    add_check_constraint :billing_merchant_memberships, "role IN ('admin', 'editor', 'viewer')", name: 'billing_member_role'

    create_table :billing_merchant_invitations do |t|
      t.references :merchant_account, null: false, foreign_key: { to_table: :billing_merchant_accounts }
      t.references :recipient, foreign_key: { to_table: :users }
      t.references :inviter, foreign_key: { to_table: :users }
      t.string :role, null: false
      t.string :status, null: false, default: 'pending'
      t.datetime :expires_at, null: false
      t.datetime :resolved_at
      t.timestamps
    end
    add_index :billing_merchant_invitations, [:merchant_account_id, :recipient_id], unique: true, where: "status = 'pending'", name: 'billing_unique_pending_invitation'
    add_check_constraint :billing_merchant_invitations, "role IN ('admin', 'editor', 'viewer')", name: 'billing_invitation_role'
    add_check_constraint :billing_merchant_invitations, "status IN ('pending', 'accepted', 'rejected', 'revoked', 'expired')", name: 'billing_invitation_status'

    create_table :billing_audit_entries do |t|
      t.references :merchant_account, null: false, foreign_key: { to_table: :billing_merchant_accounts }
      t.references :actor, foreign_key: { to_table: :users }
      t.string :actor_name, null: false
      t.string :action, null: false
      t.string :target_type, null: false
      t.bigint :target_id, null: false
      t.json :before_values, null: false, default: {}
      t.json :after_values, null: false, default: {}
      t.timestamps
    end

    create_table :billing_payout_addresses do |t|
      t.references :merchant_account, null: false, foreign_key: { to_table: :billing_merchant_accounts }
      t.integer :chain_id, null: false
      t.string :address, null: false
      t.timestamps
    end
    add_index :billing_payout_addresses, [:merchant_account_id, :chain_id], unique: true

    create_table :billing_plans do |t|
      t.references :merchant_account, null: false, foreign_key: { to_table: :billing_merchant_accounts }
      t.string :name, null: false
      t.text :description, null: false, default: ''
      t.bigint :amount_units, null: false
      t.integer :period_days, null: false
      t.json :chain_ids, null: false, default: []
      t.boolean :accepting_subscriptions, null: false, default: true
      t.timestamps
    end
    add_check_constraint :billing_plans, 'amount_units > 0 AND period_days > 0', name: 'billing_plan_positive'

    create_table :billing_subscriptions do |t|
      t.references :user, foreign_key: true
      t.references :plan, null: false, foreign_key: { to_table: :billing_plans }
      t.string :buyer_name, null: false
      t.string :seller_name, null: false
      t.string :plan_name, null: false
      t.string :status, null: false, default: 'pending'
      t.integer :chain_id, null: false
      t.string :payer_address, null: false
      t.bigint :amount_units, null: false
      t.integer :period_seconds, null: false
      t.datetime :starts_at, null: false
      t.datetime :paid_from
      t.datetime :paid_until
      t.datetime :cancel_requested_at
      t.datetime :ended_at
      t.datetime :revoked_at
      t.json :permission, null: false
      t.string :permission_hash, null: false
      t.text :signature
      t.timestamps
    end
    add_index :billing_subscriptions, [:user_id, :plan_id], unique: true, where: 'ended_at IS NULL', name: 'billing_one_open_contract'
    add_index :billing_subscriptions, :permission_hash, unique: true
    add_check_constraint :billing_subscriptions, 'amount_units > 0 AND period_seconds > 0', name: 'billing_contract_positive'

    create_table :billing_charges do |t|
      t.references :subscription, null: false, foreign_key: { to_table: :billing_subscriptions }
      t.integer :period_index, null: false
      t.datetime :period_start, null: false
      t.datetime :period_end, null: false
      t.string :status, null: false, default: 'pending'
      t.bigint :amount_units, null: false
      t.bigint :operator_units, null: false
      t.bigint :merchant_units, null: false
      t.integer :fee_basis_points, null: false
      t.string :operator_address, null: false
      t.string :merchant_address, null: false
      t.datetime :settled_period_start
      t.datetime :settled_period_end
      t.datetime :settled_at
      t.datetime :next_attempt_at
      t.string :hold_reason
      t.timestamps
    end
    add_index :billing_charges, [:subscription_id, :period_index], unique: true
    add_check_constraint :billing_charges, 'amount_units = operator_units + merchant_units AND operator_units >= 0 AND merchant_units >= 0', name: 'billing_charge_split'

    create_table :billing_transactions do |t|
      t.references :chain_setting, null: false, foreign_key: { to_table: :billing_chain_settings }
      t.references :subscription, foreign_key: { to_table: :billing_subscriptions }
      t.references :charge, foreign_key: { to_table: :billing_charges }
      t.string :kind, null: false
      t.string :status, null: false, default: 'prepared'
      t.string :signer_address, null: false
      t.integer :nonce, null: false
      t.string :transaction_hash, null: false
      t.text :raw_transaction, null: false
      t.string :to_address, null: false
      t.text :call_data, null: false
      t.bigint :estimated_fee_wei, null: false
      t.datetime :broadcast_started_at
      t.datetime :finalized_at
      t.json :receipt
      t.json :superseded_payload
      t.string :error_code
      t.timestamps
    end
    add_index :billing_transactions, :transaction_hash, unique: true
    add_index :billing_transactions, [:chain_setting_id, :signer_address, :nonce], unique: true, name: 'billing_unique_nonce'

    create_table :billing_refund_records do |t|
      t.references :charge, null: false, foreign_key: { to_table: :billing_charges }
      t.bigint :amount_units, null: false
      t.text :reason, null: false
      t.integer :chain_id, null: false
      t.string :transaction_hash, null: false
      t.timestamps
    end

    create_table :billing_events do |t|
      t.string :event_key, null: false
      t.references :user, foreign_key: true
      t.references :merchant_account, foreign_key: { to_table: :billing_merchant_accounts }
      t.string :message_key, null: false
      t.string :path, null: false
      t.datetime :delivered_at
      t.datetime :push_processed_at
      t.timestamps
    end
    add_index :billing_events, :event_key, unique: true
  end
end
