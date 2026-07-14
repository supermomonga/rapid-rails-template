# frozen_string_literal: true

require "json"
require "yaml"
require "digest"

CONFIG_PATH = ENV.fetch("RAPID_RAILS_TEMPLATE_CONFIG")
PLAN = JSON.parse(File.read(CONFIG_PATH), freeze: true)
VALUES = PLAN.fetch("configuration").fetch("values")
EXPECTED_KEYS = %w[pwa web_push active_job solid_cache account_authentication action_cable mail action_text deployment].freeze
raise "configuration schema mismatch" unless VALUES.keys.sort == EXPECTED_KEYS.sort

RUBOCOP_URL = "https://gist.githubusercontent.com/supermomonga/3ffe073e1c11cd9025d35d507038b9e2/raw/38a485963395626171243dce796e6dc541d61450/.rubocop.yml"
WEB3_URL = "https://cdn.jsdelivr.net/npm/web3@4.16.0/dist/web3.min.js"
WEB3_SHA256 = "f03340295d792adb763c777eaa96039aa831c2402bd7cbc970db44931fa736b8"

gem "pagy"
gem "active_link_to"
gem "action_policy"
gem "sentry-ruby"
gem "sentry-rails"
gem "prism"

gem_group :development do
  gem "ruby-lsp", require: false
  gem "ruby-lsp-rails", require: false
  gem "rubocop-rails", require: false
  gem "rubocop-thread_safety", require: false
  gem "momocop", require: false
end

gem_group :test do
  gem "capybara"
  gem "capybara-playwright-driver"
  gem "factory_bot"
  gem "factory_bot_rails"
end

gem "devise" if VALUES.fetch("account_authentication") == "devise"
gem "siwe-rb", "~> 0.2.0" if VALUES.fetch("account_authentication") == "wallet_siwe"
gem "web-push" if VALUES.fetch("web_push") == "use"
gem "solid_queue" if VALUES.fetch("active_job") == "solid_queue"
gem "solid_cache" if VALUES.fetch("solid_cache") == "use"
gem "solid_cable" if VALUES.fetch("action_cable") == "solid_cable"
gem "foreman", require: false if VALUES.fetch("deployment") == "dokploy"

get RUBOCOP_URL, ".rubocop.yml"

def remove_ruby_call_statement(path, call_name, first_argument)
  require "prism"
  source = File.binread(path)
  result = Prism.parse(source)
  raise "#{path}をRubyとして解析できません: #{result.errors.map(&:message).join(', ')}" unless result.success?

  calls = []
  queue = [result.value]
  until queue.empty?
    node = queue.shift
    if node.is_a?(Prism::CallNode) && node.name == call_name
      argument = node.arguments&.arguments&.first
      value = argument.respond_to?(:unescaped) ? argument.unescaped : argument.respond_to?(:value) ? argument.value.to_s : nil
      calls << node if value == first_argument
    end
    queue.concat(node.compact_child_nodes)
  end
  raise "#{path}の#{call_name}(#{first_argument})が一意ではありません" unless calls.one?

  location = calls.first.location
  line_start = source.rindex("\n", location.start_offset - 1)&.+(1) || 0
  line_end = source.index("\n", location.end_offset) || source.bytesize
  line_end += 1 if line_end < source.bytesize
  File.binwrite(path, source.byteslice(0, line_start) + source.byteslice(line_end..))
end

def run_checked(command)
  raise "コマンドが失敗しました: #{command}" unless run(command)
end

def configure_rubocop
  config = YAML.safe_load_file(".rubocop.yml", aliases: true) || {}
  config["AllCops"] ||= {}
  config["AllCops"]["TargetRubyVersion"] = 4.0
  config["AllCops"]["ParserEngine"] = "parser_prism"
  config["AllCops"]["SuggestExtensions"] = false
  config["Naming/PredicatePrefix"] = config.delete("Naming/PredicateName") if config.key?("Naming/PredicateName")
  config.delete("require")
  config["plugins"] = Array(config["plugins"]) | %w[rubocop-rails rubocop-thread_safety]
  config["require"] = ["momocop"]
  create_file ".rubocop.yml", YAML.dump(config, line_width: -1), force: true
end

def install_devise
  generate "devise:install"
  generate "devise", "User"
end

def install_wallet_siwe
  generate "authentication", "--api"
  remove_ruby_call_statement("Gemfile", :gem, "bcrypt")
  remove_ruby_call_statement("config/routes.rb", :resources, "passwords")
  remove_file "app/controllers/passwords_controller.rb"
  remove_file "app/mailers/passwords_mailer.rb" if File.exist?("app/mailers/passwords_mailer.rb")
  remove_dir "app/views/passwords_mailer" if Dir.exist?("app/views/passwords_mailer")

  user_migration = Dir.glob("db/migrate/*_create_users.rb")
  raise "CreateUsers migrationが一意ではありません" unless user_migration.one?

  create_file user_migration.first, <<~RUBY, force: true
    class CreateUsers < ActiveRecord::Migration[8.1]
      def change
        create_table :users do |t|
          t.string :wallet_address, null: false
          t.timestamps
        end
        add_index :users, :wallet_address, unique: true
      end
    end
  RUBY

  create_file "app/models/user.rb", <<~RUBY, force: true
    class User < ApplicationRecord
      has_many :sessions, dependent: :destroy

      normalizes :wallet_address, with: ->(address) { address.to_s.downcase }
      validates :wallet_address, presence: true,
        format: { with: /\\A0x[0-9a-f]{40}\\z/ },
        uniqueness: { case_sensitive: false }
    end
  RUBY

  create_file "app/controllers/concerns/authentication.rb", <<~RUBY, force: true
    module Authentication
      extend ActiveSupport::Concern

      included do
        before_action :require_authentication
        helper_method :authenticated?
      end

      class_methods do
        def allow_unauthenticated_access(**options)
          skip_before_action :require_authentication, **options
        end
      end

      private
        def authenticated?
          resume_session
        end

        def require_authentication
          resume_session || request_authentication
        end

        def resume_session
          Current.session ||= find_session_by_cookie
        end

        def find_session_by_cookie
          Session.find_by(id: cookies.signed[:session_id]) if cookies.signed[:session_id]
        end

        def request_authentication
          session[:return_to_after_authenticating] = request.url
          redirect_to new_session_path
        end

        def after_authentication_url
          session.delete(:return_to_after_authenticating) || root_url
        end

        def start_new_session_for(user)
          user.sessions.create!(user_agent: request.user_agent, ip_address: request.remote_ip).tap do |record|
            Current.session = record
            cookies.signed.permanent[:session_id] = { value: record.id, httponly: true, same_site: :lax }
          end
        end

        def terminate_session
          Current.session&.destroy!
          cookies.delete(:session_id)
        end
    end
  RUBY

  create_file "app/controllers/sessions_controller.rb", <<~RUBY, force: true
    class SessionsController < ApplicationController
      allow_unauthenticated_access only: %i[new nonce create]
      rate_limit to: 10, within: 3.minutes, only: %i[nonce create], with: -> { head :too_many_requests }

      def new; end

      def nonce
        value = Siwe.generate_nonce
        session[:siwe_nonce] = value
        session[:siwe_nonce_issued_at] = Time.current.to_i
        render json: { nonce: value }
      end

      def create
        nonce = session.delete(:siwe_nonce)
        issued_at = session.delete(:siwe_nonce_issued_at)
        return head :unauthorized if nonce.blank? || issued_at.blank?
        return head :unauthorized if Time.current.to_i - issued_at.to_i > 5.minutes.to_i

        message = Siwe::Message.parse(params.require(:message))
        message.verify!(signature: params.require(:signature), domain: request.host_with_port, nonce: nonce)
        return head :unauthorized unless message.uri == request.base_url && message.chain_id.to_i.positive?
        user = User.find_or_create_by!(wallet_address: message.address.downcase)
        start_new_session_for(user)
        render json: { redirect_url: after_authentication_url }
      rescue Siwe::Error, ActionController::ParameterMissing, ActiveRecord::RecordInvalid
        head :unauthorized
      end

      def destroy
        terminate_session
        redirect_to new_session_path
      end
    end
  RUBY

  create_file "app/views/sessions/new.html.erb", <<~ERB, force: true
    <h1>Sign in with Ethereum</h1>
    <button type="button" data-siwe-sign-in>ウォレットでサインイン</button>
    <p data-siwe-error role="alert"></p>
  ERB
  create_file "config/initializers/siwe.rb", "require \"siwe\"\n"

  create_file "app/javascript/siwe_sign_in.js", <<~JAVASCRIPT
    const button = document.querySelector("[data-siwe-sign-in]")
    const error = document.querySelector("[data-siwe-error]")

    button?.addEventListener("click", async () => {
      try {
        if (!window.ethereum) throw new Error("EVM互換ウォレットが見つかりません")
        const web3 = new window.Web3(window.ethereum)
        await window.ethereum.request({ method: "eth_requestAccounts" })
        const [address] = await web3.eth.getAccounts()
        const chainId = Number(await web3.eth.getChainId())
        const nonceResponse = await fetch("/session/nonce", { headers: { Accept: "application/json" } })
        if (!nonceResponse.ok) throw new Error("nonceを取得できません")
        const { nonce } = await nonceResponse.json()
        const domain = window.location.host
        const uri = window.location.origin
        const issuedAt = new Date().toISOString()
        const message = `${domain} wants you to sign in with your Ethereum account:\n${address}\n\nSign in to ${domain}\n\nURI: ${uri}\nVersion: 1\nChain ID: ${chainId}\nNonce: ${nonce}\nIssued At: ${issuedAt}`
        const signature = await web3.eth.personal.sign(message, address, "")
        const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content
        const response = await fetch("/session", {
          method: "POST",
          headers: { "Content-Type": "application/json", "X-CSRF-Token": csrfToken, Accept: "application/json" },
          body: JSON.stringify({ message, signature })
        })
        if (!response.ok) throw new Error("署名を検証できません")
        window.location.assign((await response.json()).redirect_url)
      } catch (exception) {
        error.textContent = exception.message
      }
    })
  JAVASCRIPT
  append_to_file "app/javascript/application.js", "\nimport \"siwe_sign_in\"\n"
  route "get 'session/nonce', to: 'sessions#nonce'"
  get WEB3_URL, "public/vendor/web3-4.16.0.min.js"
  actual_web3_sha256 = Digest::SHA256.file("public/vendor/web3-4.16.0.min.js").hexdigest
  raise "Web3.jsのSHA-256が一致しません" unless actual_web3_sha256 == WEB3_SHA256
  inject_into_file "app/views/layouts/application.html.erb",
    "  <script src=\"/vendor/web3-4.16.0.min.js\" defer></script>\n",
    before: "<%= javascript_importmap_tags %>"

  remove_file "test/controllers/passwords_controller_test.rb" if File.exist?("test/controllers/passwords_controller_test.rb")
  create_file "test/models/user_test.rb", <<~RUBY, force: true
    require 'test_helper'

    class UserTest < ActiveSupport::TestCase
      test 'normalizes wallet addresses across chains' do
        user = User.new(wallet_address: '0xABCDEF0123456789ABCDEF0123456789ABCDEF01')

        assert user.valid?
        assert_equal '0xabcdef0123456789abcdef0123456789abcdef01', user.wallet_address
      end
    end
  RUBY
  create_file "test/fixtures/users.yml", <<~YAML, force: true
    one:
      wallet_address: 0x1111111111111111111111111111111111111111
  YAML
  create_file "test/controllers/sessions_controller_test.rb", <<~RUBY, force: true
    require 'test_helper'
    require 'eth'

    class SessionsControllerTest < ActionDispatch::IntegrationTest
      test 'creates one user per wallet address after a valid SIWE signature' do
        get session_nonce_url
        nonce = response.parsed_body.fetch('nonce')
        key = Eth::Key.new
        message = Siwe::Message.new(
          domain: 'www.example.com',
          address: key.address.to_s,
          uri: 'http://www.example.com',
          chain_id: 1,
          nonce: nonce,
          issued_at: Time.current.iso8601,
          statement: 'Sign in to www.example.com'
        ).prepare_message

        assert_difference('User.count', 1) do
          post session_url, params: { message: message, signature: key.personal_sign(message) }, as: :json
        end
        assert_response :success
      end
    end
  RUBY
end

def configure_web_push
  require "web-push"
  key = WebPush.generate_key
  create_file "mise.local.toml", <<~TOML, force: true
    [env]
    VAPID_PUBLIC_KEY = #{key.public_key.inspect}
    VAPID_PRIVATE_KEY = #{key.private_key.inspect}
  TOML
  append_to_file ".gitignore", "\n/mise.local.toml\n" unless File.read(".gitignore").lines.map(&:strip).include?("/mise.local.toml")
end

def install_solid_components
  if VALUES.fetch("active_job") == "solid_queue"
    generate "solid_queue:install"
    environment "config.active_job.queue_adapter = :solid_queue"
    append_to_file "config/puma.rb", "\nplugin :solid_queue if ENV.fetch(\"RAILS_ENV\", \"development\") == \"development\"\n"
  end
  generate "solid_cache:install" if VALUES.fetch("solid_cache") == "use"
  generate "solid_cable:install" if VALUES.fetch("action_cable") == "solid_cable"
end

def configure_common_files
  create_file "config/initializers/pagy.rb", "Pagy::DEFAULT.freeze\n"
  create_file "config/initializers/sentry.rb", <<~RUBY
    Sentry.init do |config|
      config.dsn = ENV["SENTRY_DSN"]
      config.enabled_environments = %w[production]
    end
  RUBY
  create_file "app/controllers/home_controller.rb", "class HomeController < ApplicationController\n  def index; end\nend\n"
  create_file "app/views/home/index.html.erb", "<h1>Rapid Rails</h1>\n"
  route 'root "home#index"'
  create_file "test/application_system_test_case.rb", <<~RUBY
    require "test_helper"

    class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
      driven_by :playwright, using: :chromium, screen_size: [1400, 1400]
    end
  RUBY
  create_file "test/support/factory_bot.rb", "ActiveSupport.on_load(:active_support_test_case) { include FactoryBot::Syntax::Methods }\n"
  append_to_file "test/test_helper.rb", "\nrequire_relative \"support/factory_bot\"\n"
end

def configure_database
  databases = {
    "primary" => { "database" => "<%= ENV.fetch(\"DATABASE_PATH\", \"/data/production.sqlite3\") %>" }
  }
  if VALUES.fetch("active_job") == "solid_queue"
    databases["queue"] = { "database" => "<%= ENV.fetch(\"QUEUE_DATABASE_PATH\", \"/data/production_queue.sqlite3\") %>", "migrations_paths" => "db/queue_migrate" }
  end
  if VALUES.fetch("solid_cache") == "use"
    databases["cache"] = { "database" => "<%= ENV.fetch(\"CACHE_DATABASE_PATH\", \"/data/production_cache.sqlite3\") %>", "migrations_paths" => "db/cache_migrate" }
  end
  if VALUES.fetch("action_cable") == "solid_cable"
    databases["cable"] = { "database" => "<%= ENV.fetch(\"CABLE_DATABASE_PATH\", \"/data/production_cable.sqlite3\") %>", "migrations_paths" => "db/cable_migrate" }
  end
  production = databases.transform_values do |database|
    { "adapter" => "sqlite3", "pool" => "<%= ENV.fetch(\"DATABASE_POOL_SIZE\", ENV.fetch(\"RAILS_MAX_THREADS\", 5)) %>", "timeout" => 20_000, "transaction_mode" => "immediate" }.merge(database)
  end
  config = {
    "default" => { "adapter" => "sqlite3", "pool" => "<%= ENV.fetch(\"RAILS_MAX_THREADS\", 5) %>", "timeout" => 5000 },
    "development" => { "database" => "storage/development.sqlite3" },
    "test" => { "database" => "storage/test.sqlite3" },
    "production" => production
  }
  database_yaml = YAML.dump(config, line_width: -1)
    .sub("default:\n", "default: &default\n")
    .gsub(/^development:\n/, "development:\n  <<: *default\n")
    .gsub(/^test:\n/, "test:\n  <<: *default\n")
  create_file "config/database.yml", database_yaml, force: true
end

def configure_dokploy
  configure_database
  processes = ["web: bundle exec puma -p 3000 -C ./config/puma.rb"]
  processes << "worker: bin/jobs --mode async" if VALUES.fetch("active_job") == "solid_queue"
  create_file "Procfile.prod", processes.join("\n") + "\n"

  replicas = ["  - path: ${DATABASE_PATH}\n    replicas:\n      - url: ${LITESTREAM_REPLICA_URL}"]
  replicas << "  - path: ${QUEUE_DATABASE_PATH}\n    replicas:\n      - url: ${LITESTREAM_QUEUE_REPLICA_URL}" if VALUES.fetch("active_job") == "solid_queue"
  replicas << "  - path: ${CABLE_DATABASE_PATH}\n    replicas:\n      - url: ${LITESTREAM_CABLE_REPLICA_URL}" if VALUES.fetch("action_cable") == "solid_cable"
  create_file "litestream.yml", "dbs:\n#{replicas.join("\n")}\n"
  create_file ".dockerignore", ".git\nlog/*\ntmp/*\nstorage/*\nconfig/master.key\nmise.local.toml\n"
  create_file "bin/docker-entrypoint", <<~SH
    #!/bin/sh
    set -eu
    mkdir -p /data
    bundle exec rails db:prepare
    exec "$@"
  SH
  chmod "bin/docker-entrypoint", 0o755
  create_file "Dockerfile.prod", <<~DOCKERFILE
    # syntax=docker/dockerfile:1
    ARG RUBY_VERSION=4.0.0
    FROM ruby:${RUBY_VERSION}-slim AS base
    WORKDIR /rails
    ENV RAILS_ENV=production BUNDLE_DEPLOYMENT=1 BUNDLE_PATH=/usr/local/bundle BUNDLE_WITHOUT=development:test RUBY_YJIT_ENABLE=1

    FROM base AS build
    RUN apt-get update -qq && apt-get install --no-install-recommends -y build-essential git pkg-config autoconf automake libtool libssl-dev libsqlite3-dev libyaml-dev && rm -rf /var/lib/apt/lists/*
    COPY Gemfile Gemfile.lock ./
    RUN bundle install
    COPY . .
    RUN SECRET_KEY_BASE_DUMMY=1 bundle exec rails assets:precompile

    FROM base AS final
    ARG TARGETARCH
    ARG LITESTREAM_VERSION=0.5.14
    RUN case "${TARGETARCH}" in amd64) LITESTREAM_ARCH=x86_64 ;; arm64) LITESTREAM_ARCH=arm64 ;; *) echo "unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; esac && \
        LITESTREAM_ASSET="litestream-${LITESTREAM_VERSION}-linux-${LITESTREAM_ARCH}.tar.gz" && \
        apt-get update -qq && apt-get install --no-install-recommends -y ca-certificates curl libjemalloc2 libsqlite3-0 libvips && \
        curl -fsSLO "https://github.com/benbjohnson/litestream/releases/download/v${LITESTREAM_VERSION}/${LITESTREAM_ASSET}" && \
        curl -fsSLO https://github.com/benbjohnson/litestream/releases/download/v${LITESTREAM_VERSION}/checksums.txt && \
        grep " ${LITESTREAM_ASSET}$" checksums.txt | sha256sum -c - && \
        tar -xzf "${LITESTREAM_ASSET}" -C /usr/local/bin && \
        rm -f checksums.txt litestream-*.tar.gz && rm -rf /var/lib/apt/lists/*
    ENV LD_PRELOAD=libjemalloc.so.2
    COPY --from=build /usr/local/bundle /usr/local/bundle
    COPY --from=build /rails /rails
    VOLUME ["/data"]
    EXPOSE 3000
    ENTRYPOINT ["/rails/bin/docker-entrypoint"]
    CMD ["litestream", "replicate", "-config", "/rails/litestream.yml", "-exec", "bundle exec foreman start --procfile=Procfile.prod"]
  DOCKERFILE
end

after_bundle do
  configure_rubocop
  configure_common_files
  VALUES.fetch("account_authentication") == "devise" ? install_devise : install_wallet_siwe
  configure_web_push if VALUES.fetch("web_push") == "use"
  install_solid_components
  configure_dokploy if VALUES.fetch("deployment") == "dokploy"
  run_checked "bundle binstubs rubocop"
  run_checked "bin/rubocop -a"
end
