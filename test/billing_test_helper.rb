# frozen_string_literal: true

require_relative "test_helper"
require "eth"
require "tmpdir"
require "fileutils"
require "rails/all"
Rails.env = "test"

BILLING_SOURCE = File.expand_path("../src/rapid_rails_template/billing", __dir__)
$LOAD_PATH.unshift File.join(BILLING_SOURCE, "lib")
require "billing"

class BillingTestApplication < Rails::Application
  config.root = Dir.mktmpdir("billing-test-host-")
  config.eager_load = false
  config.secret_key_base = "billing-test-host-secret-key-base" * 4
  config.hosts.clear
  config.logger = Logger.new(File::NULL)
  config.active_storage.service = :test
  config.active_storage.service_configurations = { "test" => { "service" => "Disk", "root" => File.join(config.root, "storage") } }
  config.x.billing.web_push_enabled = false
  config.active_job.queue_adapter = :test
  FileUtils.mkdir_p(File.join(config.root, "config"))
  File.write(File.join(config.root, "config/database.yml"), "#{Rails.env}:\n  adapter: sqlite3\n  database: #{File.join(config.root, 'billing-test.sqlite3')}\n  timeout: 5000\n  pool: 5\n")
end

BillingTestApplication.initialize!
Minitest.after_run { FileUtils.rm_rf(BillingTestApplication.root) }

class ApplicationJob < ActiveJob::Base; end

class User < ActiveRecord::Base
  def profile
    Struct.new(:display_name).new("Test buyer")
  end
end

class UserRole < ActiveRecord::Base
  scope :admin, -> { where(role: "admin") }
end

ActiveRecord::Migration.verbose = false
ActiveRecord::Schema.define do
  create_table(:users) { |t| t.string :name }
  create_table(:user_roles) { |t| t.integer :user_id; t.string :role }
end
require File.join(BILLING_SOURCE, "db/migration_templates/create_billing")
CreateBilling.new.migrate(:up)

class BillingTest < Minitest::Test
  def setup
    ActiveRecord::Base.connection.begin_transaction(joinable: false)
    @user = User.create!(name: "Buyer")
    @setting = Billing::Setting.current
    @chain = Billing::ChainSetting.for_chain(1)
    @chain.update!(treasury_address: "0x#{'11' * 20}", collector_address: "0x#{'22' * 20}",
      executor_address: "0x#{'33' * 20}", gas_ceiling_wei: "100000000000000000", verified_at: Time.current)
    @plan = Billing::Plan.create!(seller_kind: "operator", name: "30 days", amount_units: 10_000_000, period_days: 30, chain_ids: [1])
    @now = Time.utc(2026, 9, 8, 0, 0, 0)
  end

  def teardown
    ActiveRecord::Base.connection.rollback_transaction
  end

  def subscription(**attributes)
    defaults = {
      user: @user, plan: @plan, seller_kind: "operator", buyer_name: "Buyer", seller_name: "Operator", plan_name: @plan.name,
      chain_id: 1, payer_address: "0x#{'44' * 20}", amount_units: @plan.amount_units,
      period_seconds: 30 * 86400, starts_at: @now,
      permission: {
        "account" => "0x#{'44' * 20}", "spender" => @chain.collector_address, "token" => Billing::Chains.fetch(1).usdc,
        "allowance" => @plan.amount_units.to_s, "period" => (30 * 86400).to_s, "start" => @now.to_i.to_s,
        "end" => (2**48 - 1).to_s, "salt" => "1", "extraData" => "0x"
      },
      permission_hash: "0x#{'55' * 32}", signature: "0xabcd"
    }
    Billing::Subscription.create!(**defaults.merge(attributes))
  end
end
