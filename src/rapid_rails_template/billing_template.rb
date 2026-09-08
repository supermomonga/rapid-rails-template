# frozen_string_literal: true

def prepare_billing_engine
  BILLING_FILES.each do |path, encoded|
    create_file File.join("engines/billing", path), Base64.strict_decode64(encoded)
  end
  gem "billing", path: "engines/billing"
end

def configure_billing
  # Use Rails' migration numbering after the host authentication tables exist.
  # The generated migration stays in the engine, whose path Rails loads directly.
  generate "migration", "CreateBilling"
  migrations = Dir.glob("db/migrate/*_create_billing.rb")
  raise "CreateBilling migrationが一意ではありません" unless migrations.one?

  engine_migration = "engines/billing/db/migration_templates/create_billing.rb"
  create_file File.join("engines/billing/db/migrate", File.basename(migrations.first)), File.binread(engine_migration)
  remove_file engine_migration
  remove_file migrations.first
  route 'mount Billing::Engine => "/", as: :billing'
  environment "config.x.billing.web_push_enabled = #{VALUES.fetch('web_push') == 'use'}"
  if VALUES.fetch("web_push") == "use"
    environment "config.x.billing.push_delivery = ->(**attributes) { ::PushNotifier.deliver_later(**attributes) if attributes.fetch(:user).push_subscriptions.exists? }"
  end
  append_to_file "config/initializers/filter_parameter_logging.rb", <<~RUBY

    Rails.application.config.filter_parameters += [:signature, :raw_transaction, :superseded_payload, :billing_execution_private_key]
  RUBY
  inject_into_class "app/models/user.rb", "User", <<~RUBY
    has_one :merchant_profile, class_name: "Billing::MerchantProfile", dependent: :nullify
    has_many :billing_subscriptions, class_name: "Billing::Subscription", dependent: :nullify
    has_many :billing_events, class_name: "Billing::Event", dependent: :destroy
    before_destroy :ensure_billing_contracts_ended, prepend: true

    private
      T::Sig::WithoutRuntime.sig { void }
      def ensure_billing_contracts_ended
        if Billing::AccountDeletion.blocked?(self)
          errors.add(:base, I18n.t("billing.errors.active_contracts"))
          throw :abort
        end
        merchant_profile&.plans&.find_each { |plan| plan.update!(accepting_subscriptions: false) }
      end
    public
  RUBY
  recurring = YAML.safe_load_file("config/recurring.yml", aliases: true)
  %w[development production].each do |environment_name|
    recurring[environment_name] ||= {}
    recurring.fetch(environment_name)["billing_reconcile"] = {
      "class" => "Billing::ReconcileJob", "schedule" => "every minute"
    }
  end
  create_file "config/recurring.yml", YAML.dump(recurring), force: true
  create_file "test/billing_engine_test.rb", <<~RUBY
    require_relative "../engines/billing/test/integration/host_contract_test"
  RUBY
  create_file "sorbet/tapioca/compilers/billing_routes.rb", <<~RUBY
    require_relative "../../../engines/billing/lib/tapioca/dsl/compilers/billing_routes"
  RUBY
end
