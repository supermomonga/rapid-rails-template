# frozen_string_literal: true

require "json"
require "yaml"
require "digest"

CONFIG_PATH = ENV.fetch("RAPID_RAILS_TEMPLATE_CONFIG")
PLAN = JSON.parse(File.read(CONFIG_PATH), freeze: true)
VALUES = PLAN.fetch("configuration").fetch("values")
EXPECTED_KEYS = %w[pwa web_push active_job job_operations maintenance_tasks solid_cache account_authentication profile_features image_delivery api action_cable mail deployment default_locale].freeze
raise "configuration schema mismatch" unless VALUES.keys.sort == EXPECTED_KEYS.sort

RUBOCOP_URL = "https://gist.githubusercontent.com/supermomonga/3ffe073e1c11cd9025d35d507038b9e2/raw/38a485963395626171243dce796e6dc541d61450/.rubocop.yml"
WEB3_URL = "https://cdn.jsdelivr.net/npm/web3@4.16.0/dist/web3.min.js"
WEB3_SHA256 = "f03340295d792adb763c777eaa96039aa831c2402bd7cbc970db44931fa736b8"

gem "pagy"
gem "active_link_to"
gem "action_policy"
gem "sentry-ruby"
gem "sentry-rails"
gem "lexxy", "~> 0.9.21"
gem "active_storage_db"
gem "prism"
gem "rails-i18n"

gem_group :development do
  gem "annotaterb"
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
gem "devise-i18n" if VALUES.fetch("account_authentication") == "devise"
gem "siwe-rb", "~> 0.2.0" if VALUES.fetch("account_authentication") == "wallet_siwe"
gem "haikunator" if (VALUES.fetch("profile_features") & %w[screen_name display_name]).any?
gem "boring_avatars", "~> 0.1.0", require: "boring_avatars/bindings/rails" if VALUES.fetch("profile_features").include?("avatar")
gem "imgproxy-rails", "~> 0.3.0" if VALUES.fetch("image_delivery") == "imgproxy"
gem "web-push", "~> 3.1" if VALUES.fetch("web_push") == "use"
gem "solid_queue", "1.6.0" if VALUES.fetch("active_job") == "solid_queue"
gem "mission_control-jobs", "1.1.0" if VALUES.fetch("job_operations") == "enable"
gem "maintenance_tasks", "2.17.0" if VALUES.fetch("maintenance_tasks") == "enable"
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

def configure_devise_registration_route
  require "prism"
  path = "config/routes.rb"
  source = File.binread(path)
  result = Prism.parse(source)
  raise "#{path}をRubyとして解析できません: #{result.errors.map(&:message).join(', ')}" unless result.success?

  calls = []
  queue = [result.value]
  until queue.empty?
    node = queue.shift
    if node.is_a?(Prism::CallNode) && node.name == :devise_for
      argument = node.arguments&.arguments&.first
      calls << node if argument.is_a?(Prism::SymbolNode) && argument.unescaped == "users"
    end
    queue.concat(node.compact_child_nodes)
  end
  raise "#{path}のdevise_for(:users)が一意ではありません" unless calls.one?

  call = calls.first
  actual = source.byteslice(call.location.start_offset, call.location.length)
  raise "#{path}のdevise_for(:users)が想定外の構造です: #{actual}" unless actual == "devise_for :users"

  replacement = 'devise_for :users, controllers: { registrations: "users/registrations" }'
  File.binwrite(
    path,
    source.byteslice(0, call.location.start_offset) + replacement + source.byteslice(call.location.end_offset..)
  )
end

def configure_maintenance_tasks_route
  require "prism"
  path = "config/routes.rb"
  source = File.binread(path)
  result = Prism.parse(source)
  raise "#{path}をRubyとして解析できません: #{result.errors.map(&:message).join(', ')}" unless result.success?

  calls = []
  queue = [result.value]
  until queue.empty?
    node = queue.shift
    if node.is_a?(Prism::CallNode) && node.name == :mount
      actual = source.byteslice(node.location.start_offset, node.location.length)
      calls << node if actual == 'mount MaintenanceTasks::Engine, at: "/maintenance_tasks"'
    end
    queue.concat(node.compact_child_nodes)
  end
  raise "#{path}のMaintenance Tasks mountが一意ではありません" unless calls.one?

  call = calls.first
  replacement = 'mount MaintenanceTasks::Engine, at: "/admin/maintenance_tasks", as: :admin_maintenance_tasks'
  File.binwrite(
    path,
    source.byteslice(0, call.location.start_offset) + replacement + source.byteslice(call.location.end_offset..)
  )
end

def run_checked(command)
  raise "コマンドが失敗しました: #{command}" unless run(command)
end

def create_locale_pair(name, ja:, en:)
  create_file "config/locales/#{name}.ja.yml", YAML.dump({ "ja" => ja }, line_width: -1), force: true
  create_file "config/locales/#{name}.en.yml", YAML.dump({ "en" => en }, line_width: -1), force: true
end

def configure_application_identity
  app_name = PLAN.fetch("app_name")
  default_locale = VALUES.fetch("default_locale")

  create_file "lib/application_identity.rb", <<~RUBY, force: true
    require "uri"

    class ApplicationIdentity
      Error = Class.new(StandardError)
      AVAILABLE_LOCALES = %i[ja en].freeze

      attr_reader :app_name, :canonical_origin, :default_locale

      def self.build(configuration, environment: ENV)
        canonical_origin = configuration.canonical_origin
        if configuration.canonical_origin_env.present?
          canonical_origin = environment.fetch(configuration.canonical_origin_env) do
            raise Error, "\#{configuration.canonical_origin_env} is required"
          end
        end
        new(
          app_name: configuration.app_name,
          canonical_origin:,
          default_locale: configuration.default_locale
        )
      end

      def initialize(app_name:, canonical_origin:, default_locale:)
        @app_name = app_name.to_s.strip
        raise Error, "app_name is required" if @app_name.empty?

        @default_locale = default_locale.to_s.to_sym
        raise Error, "default_locale must be ja or en" unless AVAILABLE_LOCALES.include?(@default_locale)

        @canonical_origin = validate_origin(canonical_origin)
        freeze
      end

      def default_url_options
        uri = URI.parse(canonical_origin)
        options = { protocol: uri.scheme, host: uri.host }
        options[:port] = uri.port unless uri.port == URI::HTTP.default_port || uri.port == URI::HTTPS.default_port
        options
      end

      def canonical_url(path)
        path = path.to_s
        raise ArgumentError, "path must be a same-origin absolute path" unless path.start_with?("/") && !path.start_with?("//")

        canonical_origin + path
      end

      def siwe_statement(locale: default_locale)
        locale = locale.to_s.to_sym
        raise ArgumentError, "locale must be ja or en" unless AVAILABLE_LOCALES.include?(locale)

        encoded_app_name = URI.encode_uri_component(app_name).gsub("%20", " ")
        I18n.t("wallet_siwe.statement", locale:, app_name: encoded_app_name)
      end

      private
        def validate_origin(value)
          raise Error, "canonical_origin is required" if value.blank?

          uri = URI.parse(value.to_s)
          valid = uri.is_a?(URI::HTTP) && uri.host.present? && uri.userinfo.nil? &&
            uri.path.empty? && uri.query.nil? && uri.fragment.nil?
          raise Error, "canonical_origin must be an HTTP(S) origin without path, query, fragment, or userinfo" unless valid

          uri.to_s
        rescue URI::InvalidURIError => error
          raise Error, "canonical_origin is invalid: \#{error.message}"
        end
    end
  RUBY

  identity = {
    "shared" => {
      "app_name" => app_name,
      "default_locale" => default_locale
    },
    "development" => { "canonical_origin" => "http://localhost:3000" },
    "test" => { "canonical_origin" => "http://www.example.com" },
    "production" => { "canonical_origin_env" => "APPLICATION_ORIGIN" }
  }
  create_file "config/application_identity.yml", YAML.dump(identity, line_width: -1), force: true

  environment <<~RUBY
    require_relative "../lib/application_identity"
    config.x.application_identity = ApplicationIdentity.build(config_for(:application_identity))
    config.i18n.available_locales = ApplicationIdentity::AVAILABLE_LOCALES
    config.i18n.default_locale = config.x.application_identity.default_locale
    config.i18n.fallbacks = false
  RUBY
  environment "config.i18n.raise_on_missing_translations = true", env: "test"

  create_file "config/initializers/application_identity.rb", <<~RUBY, force: true
    identity = Rails.configuration.x.application_identity
    Rails.application.routes.default_url_options = identity.default_url_options
    if Rails.application.config.respond_to?(:action_mailer)
      Rails.application.config.action_mailer.default_url_options = identity.default_url_options
    end
  RUBY

  create_file "app/controllers/concerns/localized_request.rb", <<~RUBY, force: true
    module LocalizedRequest
      extend ActiveSupport::Concern

      included do
        around_action :use_default_locale
      end

      private
        def use_default_locale(&action)
          I18n.with_locale(I18n.default_locale, &action)
        end
    end
  RUBY
  inject_into_class "app/controllers/application_controller.rb", "ApplicationController", "  include LocalizedRequest\n\n"

  create_locale_pair(
    "application",
    ja: {
      "meta" => { "description" => "%{app_name}のWebアプリケーションです。" },
      "navigation" => {
        "main" => "メインナビゲーション", "account_menu" => "アカウントメニュー", "admin_menu" => "管理メニュー", "open_account_menu" => "アカウントメニューを開く",
        "dashboard" => "マイページ", "profile" => "プロフィール", "account_settings" => "アカウント設定", "notifications" => "通知",
        "api_credentials" => "APIキーの管理", "users" => "ユーザー管理", "pages" => "固定ページ管理", "faqs" => "FAQ管理",
        "admin" => "管理画面", "sign_in" => "ログイン", "sign_up" => "アカウント作成", "sign_out" => "ログアウト"
      },
      "footer" => { "about_section" => "アプリについて", "guides_section" => "ガイド", "links_section" => "リンク", "about" => "%{app_name}について", "company" => "運営会社", "manual" => "使い方", "faq" => "よくある質問", "terms" => "利用規約", "privacy" => "プライバシーポリシー", "transaction_law" => "特商法表記" },
      "home" => {
        "title" => "ホーム", "badge" => "Railsアプリケーションテンプレート", "heading" => "迷わず始められる、モダンなRails開発環境。",
        "description" => "Rails 8.1の標準を活かしながら、認証、UI、テスト、デプロイまでを再現可能な構成で整えます。",
        "start_devise" => "無料で始める", "start_wallet" => "ウォレットで始める", "features_link" => "構成を見る", "starter" => "スターターキット", "features_title" => "最初から揃う開発基盤",
        "features" => { "rails" => { "title" => "Railsネイティブ", "description" => "Generator APIを中心に、安全な初期構成を生成します。" }, "ui" => { "title" => "読みやすいUI", "description" => "daisyUIとsemantic colorで、読みやすい画面を用意します。" }, "production" => { "title" => "本番運用対応", "description" => "SQLiteとLitestreamを前提に、運用経路まで設計します。" } }
      },
      "accounts" => {
        "show" => { "title" => "マイページ", "description" => "アプリケーションの状態を確認できます。", "description_with_profile" => "プロフィールとアプリケーションの状態を確認できます。", "next_step" => "次のステップ", "action" => "サイドメニューから利用設定を管理できます。", "action_with_profile" => "サイドメニューからプロフィールや利用設定を管理できます。", "back_home" => "ホームへ戻る" },
        "edit" => { "title" => "アカウント設定", "information" => "アカウント情報", "wallet_address" => "ウォレットアドレス", "danger_title" => "アカウントの削除", "danger_description" => "この操作は取り消せません。このアカウントのすべてのセッションも削除されます。", "delete" => "アカウントを削除", "confirm" => "本当に削除しますか？" },
        "destroy" => { "notice" => "アカウントを削除しました", "last_admin" => "最後の管理者はアカウントを削除できません" }
      },
      "wallet_siwe" => { "title" => "ウォレットでログイン", "eyebrow" => "Ethereumでログイン", "description" => "EVM互換ウォレットで署名し、アカウントを安全に確認します。", "connect" => "ウォレットを接続", "note" => "署名要求に秘密鍵や送金は必要ありません。", "statement" => "Login to %{app_name}", "errors" => { "wallet_missing" => "EVM互換ウォレットが見つかりません", "nonce" => "nonceを取得できません", "verification" => "署名を検証できません" } },
      "common" => { "edit" => "編集", "delete" => "削除", "back" => "戻る", "update" => "更新", "create" => "作成", "cancel" => "キャンセル", "copy" => "コピー", "copied" => "コピーしました", "menu" => "メニュー", "actions" => "操作", "none" => "なし", "previous" => "前へ", "next" => "次へ", "unused" => "未使用", "not_set" => "未設定", "save" => "保存" }
    },
    en: {
      "meta" => { "description" => "The web application for %{app_name}." },
      "navigation" => {
        "main" => "Main navigation", "account_menu" => "Account menu", "admin_menu" => "Administration menu", "open_account_menu" => "Open account menu",
        "dashboard" => "Dashboard", "profile" => "Profile", "account_settings" => "Account settings", "notifications" => "Notifications",
        "api_credentials" => "API credentials", "users" => "Users", "pages" => "Pages", "faqs" => "FAQs",
        "admin" => "Administration", "sign_in" => "Sign in", "sign_up" => "Create account", "sign_out" => "Sign out"
      },
      "footer" => { "about_section" => "About", "guides_section" => "Guides", "links_section" => "Links", "about" => "About %{app_name}", "company" => "Company", "manual" => "Guides", "faq" => "Frequently asked questions", "terms" => "Terms", "privacy" => "Privacy policy", "transaction_law" => "Commercial transactions disclosure" },
      "home" => {
        "title" => "Home", "badge" => "Rails application template", "heading" => "A modern Rails environment without the guesswork.",
        "description" => "Build on Rails 8.1 defaults with reproducible authentication, UI, testing, and deployment foundations.",
        "start_devise" => "Get started", "start_wallet" => "Start with a wallet", "features_link" => "View features", "starter" => "Starter kit", "features_title" => "A complete development foundation",
        "features" => { "rails" => { "title" => "Rails native", "description" => "Generate a safe baseline centered on the Generator API." }, "ui" => { "title" => "Readable UI", "description" => "Start with readable screens built with daisyUI and semantic colors." }, "production" => { "title" => "Production ready", "description" => "Include an operational path designed for SQLite and Litestream." } }
      },
      "accounts" => {
        "show" => { "title" => "Dashboard", "description" => "Review the state of your application.", "description_with_profile" => "Review your profile and application state.", "next_step" => "Next step", "action" => "Manage your preferences from the side menu.", "action_with_profile" => "Manage your profile and preferences from the side menu.", "back_home" => "Back to home" },
        "edit" => { "title" => "Account settings", "information" => "Account information", "wallet_address" => "Wallet address", "danger_title" => "Delete account", "danger_description" => "This action cannot be undone. All sessions for this account will also be deleted.", "delete" => "Delete account", "confirm" => "Are you sure you want to delete your account?" },
        "destroy" => { "notice" => "Your account was deleted.", "last_admin" => "The last administrator cannot delete their account." }
      },
      "wallet_siwe" => { "title" => "Sign in with your wallet", "eyebrow" => "Sign in with Ethereum", "description" => "Sign with an EVM-compatible wallet to verify your account securely.", "connect" => "Connect wallet", "note" => "The signature request does not require your private key or a transfer.", "statement" => "Sign in to %{app_name}", "errors" => { "wallet_missing" => "No EVM-compatible wallet was found", "nonce" => "Could not obtain a nonce", "verification" => "Could not verify the signature" } },
      "common" => { "edit" => "Edit", "delete" => "Delete", "back" => "Back", "update" => "Update", "create" => "Create", "cancel" => "Cancel", "copy" => "Copy", "copied" => "Copied", "menu" => "Menu", "actions" => "Actions", "none" => "None", "previous" => "Previous", "next" => "Next", "unused" => "Never used", "not_set" => "Not set", "save" => "Save" }
    }
  )

  create_file "test/lib/application_identity_test.rb", <<~RUBY, force: true
    require "test_helper"

    class ApplicationIdentityTest < ActiveSupport::TestCase
      test "builds URL options and canonical URLs from an explicit origin" do
        identity = ApplicationIdentity.new(app_name: "Sample App", canonical_origin: "https://example.com:8443", default_locale: :en)

        assert_equal "Sample App", identity.app_name
        assert_equal :en, identity.default_locale
        assert_equal({ protocol: "https", host: "example.com", port: 8443 }, identity.default_url_options)
        assert_equal "https://example.com:8443/account", identity.canonical_url("/account")
        assert_equal "Sign in to Sample App", identity.siwe_statement

        unicode_identity = ApplicationIdentity.new(app_name: "サンプル & App", canonical_origin: "https://example.com", default_locale: :ja)
        assert_equal "Login to %E3%82%B5%E3%83%B3%E3%83%97%E3%83%AB %26 App", unicode_identity.siwe_statement
      end

      test "requires the configured production environment variable" do
        configuration = ActiveSupport::OrderedOptions.new
        configuration.app_name = "Sample App"
        configuration.default_locale = "ja"
        configuration.canonical_origin_env = "APPLICATION_ORIGIN"

        error = assert_raises(ApplicationIdentity::Error) { ApplicationIdentity.build(configuration, environment: {}) }
        assert_equal "APPLICATION_ORIGIN is required", error.message

        identity = ApplicationIdentity.build(configuration, environment: { "APPLICATION_ORIGIN" => "https://example.com" })
        assert_equal "https://example.com", identity.canonical_origin
      end

      test "rejects origins with credentials or URL components" do
        %w[ftp://example.com https://user@example.com https://example.com/path https://example.com?query=1 https://example.com#fragment].each do |origin|
          assert_raises(ApplicationIdentity::Error) do
            ApplicationIdentity.new(app_name: "Sample App", canonical_origin: origin, default_locale: :ja)
          end
        end
      end
    end

    class ApplicationIdentityRequestTest < ActionDispatch::IntegrationTest
      test "renders identity metadata and restores the caller locale after a request" do
        previous_locale = I18n.default_locale == :ja ? :en : :ja
        I18n.with_locale(previous_locale) do
          get root_url

          identity = Rails.configuration.x.application_identity
          assert_response :success
          assert_select "html[lang=?]", identity.default_locale.to_s, count: 1
          assert_select "title", text: /\#{Regexp.escape(identity.app_name)}/, count: 1
          assert_select 'meta[property="og:site_name"][content=?]', identity.app_name, count: 1
          assert_select 'link[rel="canonical"][href=?]', identity.canonical_url("/"), count: 1
          assert_equal previous_locale, I18n.locale
        end
      end
    end
  RUBY

  create_file "test/i18n_locale_test.rb", <<~RUBY, force: true
    require "test_helper"

    class I18nLocaleTest < ActiveSupport::TestCase
      test "every application locale file has a matching ja and en key set" do
        Rails.root.glob("config/locales/*.ja.yml").each do |ja_path|
          en_path = Pathname(ja_path.to_s.sub(/\\.ja\\.yml\\z/, ".en.yml"))
          assert_predicate en_path, :file?, "missing English pair for \#{ja_path.basename}"

          ja_keys = flatten_keys(YAML.safe_load_file(ja_path).fetch("ja"))
          en_keys = flatten_keys(YAML.safe_load_file(en_path).fetch("en"))
          assert_equal ja_keys, en_keys, "locale key mismatch for \#{ja_path.basename}"
        end
      end

      test "the configured locales load without missing application translations" do
        assert_equal %i[en ja], I18n.available_locales.sort
        assert_equal Rails.configuration.x.application_identity.default_locale, I18n.default_locale
      end

      private
        def flatten_keys(value, prefix = nil)
          return [prefix] unless value.is_a?(Hash)

          value.flat_map { |key, child| flatten_keys(child, [prefix, key].compact.join(".")) }.sort
        end
    end
  RUBY
end

def configure_image_delivery
  delivery = VALUES.fetch("image_delivery")
  environment <<~RUBY
    config.active_storage.variant_processor = :vips
    config.active_storage.track_variants = true
    config.active_storage.resolve_model_to_route = :#{delivery == "imgproxy" ? "imgproxy_active_storage" : "rails_storage_redirect"}
  RUBY

  if delivery == "imgproxy"
    create_file "lib/image_delivery_configuration.rb", <<~'RUBY', force: true
      require "ipaddr"
      require "resolv"
      require "uri"

      class ImageDeliveryConfiguration
        Error = Class.new(StandardError)
        HEX_PATTERN = /\A(?:[0-9a-fA-F]{2})+\z/
        NON_PUBLIC_IPV4_NETWORKS = %w[
          0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16
          172.16.0.0/12 192.0.0.0/24 192.0.2.0/24 192.88.99.0/24
          192.168.0.0/16 198.18.0.0/15 198.51.100.0/24 203.0.113.0/24
          224.0.0.0/4 240.0.0.0/4
        ].map { |network| IPAddr.new(network) }.freeze
        GLOBAL_IPV6_NETWORK = IPAddr.new("2000::/3")
        NON_PUBLIC_IPV6_NETWORKS = %w[2001:2::/48 2001:db8::/32].map { |network| IPAddr.new(network) }.freeze

        attr_reader :endpoint, :key, :salt, :source_origin

        def self.fetch!(environment: ENV, rails_environment: Rails.env,
          application_identity: Rails.configuration.x.application_identity,
          resolver: Resolv.method(:getaddresses))
          new(environment:, rails_environment:, application_identity:, resolver:)
        end

        def initialize(environment:, rails_environment:, application_identity:, resolver:)
          production = rails_environment.to_s == "production"
          @endpoint = validate_url(environment.fetch("IMGPROXY_ENDPOINT") { raise Error, "IMGPROXY_ENDPOINT is required" }, "IMGPROXY_ENDPOINT", origin: false, https: production)
          @key = validate_hex(environment.fetch("IMGPROXY_KEY") { raise Error, "IMGPROXY_KEY is required" }, "IMGPROXY_KEY")
          @salt = validate_hex(environment.fetch("IMGPROXY_SALT") { raise Error, "IMGPROXY_SALT is required" }, "IMGPROXY_SALT")
          source = if production
                     application_identity.canonical_origin
                   else
                     environment.fetch("IMGPROXY_SOURCE_ORIGIN") { raise Error, "IMGPROXY_SOURCE_ORIGIN is required outside production" }
                   end
          @source_origin = validate_url(source, "imgproxy source origin", origin: true, https: production)
          if production
            validate_public_host!(@endpoint, "IMGPROXY_ENDPOINT", resolver)
            validate_public_host!(@source_origin, "imgproxy source origin", resolver)
          end
          freeze
        rescue URI::InvalidURIError => error
          raise Error, "image delivery URL is invalid: #{error.message}"
        end

        private
          def validate_hex(value, name)
            value = value.to_s
            raise Error, "#{name} must be non-empty even-length hexadecimal" unless value.match?(HEX_PATTERN)

            value.freeze
          end

          def validate_url(value, name, origin:, https:)
            raise Error, "#{name} is required" if value.to_s.strip.empty?

            uri = URI.parse(value.to_s)
            valid = uri.is_a?(URI::HTTP) && uri.host && uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil?
            valid &&= ["", "/"].include?(uri.path) if origin
            raise Error, "#{name} must be an HTTP(S) URL without userinfo, query, or fragment" unless valid
            raise Error, "#{name} must use HTTPS in production" if https && uri.scheme != "https"

            uri.path = "" if origin
            uri.to_s.delete_suffix("/").freeze
          end

          def validate_public_host!(url, name, resolver)
            host = URI.parse(url).host
            raise Error, "#{name} must not use localhost in production" if host.casecmp?("localhost")

            addresses = begin
              [IPAddr.new(host)]
            rescue IPAddr::InvalidAddressError
              Array(resolver.call(host)).map { |address| IPAddr.new(address) }
            end
            raise Error, "#{name} host could not be resolved" if addresses.empty?
            return if addresses.all? { |address| public_address?(address) }

            raise Error, "#{name} must resolve only to public addresses in production"
          rescue Resolv::ResolvError, SocketError, IPAddr::InvalidAddressError => error
            raise Error, "#{name} host could not be resolved: #{error.message}"
          end

          def public_address?(address)
            return NON_PUBLIC_IPV4_NETWORKS.none? { |network| network.include?(address) } if address.ipv4?

            GLOBAL_IPV6_NETWORK.include?(address) && NON_PUBLIC_IPV6_NETWORKS.none? { |network| network.include?(address) }
          end
      end
    RUBY

    create_file "lib/imgproxy/active_storage_url_adapter.rb", <<~'RUBY', force: true
      module Imgproxy
        class ActiveStorageUrlAdapter < UrlAdapters::ActiveStorage
          def initialize(source_origin:)
            super()
            @source_origin = source_origin.delete_suffix("/")
          end

          def url(image)
            path = Rails.application.routes.url_helpers.rails_storage_proxy_path(image)
            "#{@source_origin}#{path}"
          end
        end
      end
    RUBY

    create_file "config/initializers/imgproxy.rb", <<~'RUBY', force: true
      require Rails.root.join("lib/image_delivery_configuration")
      require Rails.root.join("lib/imgproxy/active_storage_url_adapter")

      assets_precompile = ENV["SECRET_KEY_BASE_DUMMY"] == "1" &&
        defined?(Rake) && Rake.application.top_level_tasks.include?("assets:precompile")
      unless assets_precompile
        image_delivery = ImageDeliveryConfiguration.fetch!
        Rails.configuration.x.image_delivery = image_delivery

        Imgproxy.configure do |config|
          config.endpoint = image_delivery.endpoint
          config.key = image_delivery.key
          config.salt = image_delivery.salt
          config.use_short_options = true
          config.base64_encode_urls = true
          config.url_adapters.clear!
          config.url_adapters.add(Imgproxy::ActiveStorageUrlAdapter.new(source_origin: image_delivery.source_origin))
        end
      end
    RUBY

    create_file "bin/imgproxy-dev", <<~'SH', force: true
      #!/bin/sh
      set -eu
      : "${IMGPROXY_KEY:?IMGPROXY_KEY is required}"
      : "${IMGPROXY_SALT:?IMGPROXY_SALT is required}"
      : "${IMGPROXY_SOURCE_ORIGIN:?IMGPROXY_SOURCE_ORIGIN is required}"
      IMGPROXY_PORT="${IMGPROXY_PORT:-8080}"
      ALLOWED_SOURCE="${IMGPROXY_SOURCE_ORIGIN%/}/"
      exec docker run --rm -p "${IMGPROXY_PORT}:8080" \
        -e IMGPROXY_KEY \
        -e IMGPROXY_SALT \
        -e IMGPROXY_ALLOWED_SOURCES="${ALLOWED_SOURCE}" \
        -e IMGPROXY_MAX_SRC_FILE_SIZE=5242880 \
        -e IMGPROXY_MAX_SRC_RESOLUTION=16.8 \
        -e IMGPROXY_MAX_ANIMATION_FRAMES=1 \
        darthsim/imgproxy:v4.0.12
    SH
    chmod "bin/imgproxy-dev", 0o755

    create_file "test/lib/image_delivery_configuration_test.rb", <<~'RUBY', force: true
      require "test_helper"

      class ImageDeliveryConfigurationTest < ActiveSupport::TestCase
        test "accepts signed explicit development settings" do
          configuration = build_configuration

          assert_equal "http://localhost:8080", configuration.endpoint
          assert_equal "http://host.docker.internal:3000", configuration.source_origin
        end

        test "requires endpoint key salt and source origin" do
          %w[IMGPROXY_ENDPOINT IMGPROXY_KEY IMGPROXY_SALT IMGPROXY_SOURCE_ORIGIN].each do |name|
            environment = valid_environment.except(name)
            assert_raises(ImageDeliveryConfiguration::Error) { build_configuration(environment:) }
          end
        end

        test "rejects malformed signing values" do
          ["", "0", "xyz", "00-11"].each do |value|
            error = assert_raises(ImageDeliveryConfiguration::Error) do
              build_configuration(environment: valid_environment.merge("IMGPROXY_KEY" => value))
            end
            assert_match(/IMGPROXY_KEY/, error.message)
          end
        end

        test "production requires HTTPS public endpoint and canonical source origin" do
          identity = ApplicationIdentity.new(app_name: "Sample", canonical_origin: "https://app.example.com", default_locale: :en)
          resolver = ->(_host) { ["93.184.216.34"] }
          configuration = build_configuration(
            environment: valid_environment.except("IMGPROXY_SOURCE_ORIGIN").merge("IMGPROXY_ENDPOINT" => "https://images.example.com"),
            rails_environment: "production",
            application_identity: identity,
            resolver:
          )

          assert_equal "https://app.example.com", configuration.source_origin
          assert_raises(ImageDeliveryConfiguration::Error) do
            build_configuration(rails_environment: "production", application_identity: identity, resolver:)
          end
          assert_raises(ImageDeliveryConfiguration::Error) do
            build_configuration(
              environment: valid_environment.except("IMGPROXY_SOURCE_ORIGIN").merge("IMGPROXY_ENDPOINT" => "https://images.example.com"),
              rails_environment: "production",
              application_identity: identity,
              resolver: ->(_host) { ["127.0.0.1"] }
            )
          end
          assert_raises(ImageDeliveryConfiguration::Error) do
            build_configuration(
              environment: valid_environment.except("IMGPROXY_SOURCE_ORIGIN").merge("IMGPROXY_ENDPOINT" => "https://images.example.com"),
              rails_environment: "production",
              application_identity: identity,
              resolver: ->(_host) { ["203.0.113.10"] }
            )
          end
        end

        private
          def build_configuration(environment: valid_environment, rails_environment: "test",
            application_identity: Rails.configuration.x.application_identity,
            resolver: ->(_host) { ["93.184.216.34"] })
            ImageDeliveryConfiguration.new(environment:, rails_environment:, application_identity:, resolver:)
          end

          def valid_environment
            {
              "IMGPROXY_ENDPOINT" => "http://localhost:8080",
              "IMGPROXY_KEY" => "00112233",
              "IMGPROXY_SALT" => "aabbccdd",
              "IMGPROXY_SOURCE_ORIGIN" => "http://host.docker.internal:3000"
            }
          end
      end
    RUBY

    create_file "test/lib/imgproxy/active_storage_url_adapter_test.rb", <<~'RUBY', force: true
      require "test_helper"
      require "base64"
      require "openssl"
      require "uri"

      class ImgproxyActiveStorageUrlAdapterTest < ActiveSupport::TestCase
        test "builds a source URL only from an Active Storage blob proxy path" do
          blob = ActiveStorage::Blob.create_and_upload!(
            io: StringIO.new("stored image"), filename: "avatar.png", content_type: "image/png"
          )
          adapter = Imgproxy::ActiveStorageUrlAdapter.new(source_origin: "https://app.example.com")

          url = adapter.url(blob)

          assert url.start_with?("https://app.example.com/rails/active_storage/blobs/proxy/")
          assert_includes url, blob.signed_id
        ensure
          blob&.purge
        end

        test "signs an imgproxy URL whose encoded source is the blob proxy path" do
          blob = ActiveStorage::Blob.create_and_upload!(
            io: StringIO.new("stored image"), filename: "avatar.png", content_type: "image/png"
          )

          url = Imgproxy.url_for(blob, resizing_type: "fill", width: 40, height: 40, enlarge: 1)
          path = URI(url).path
          signature, processing, *encoded_source = path.delete_prefix("/").split("/")
          unsigned_path = "/#{([processing] + encoded_source).join("/")}"
          expected_signature = Base64.urlsafe_encode64(
            OpenSSL::HMAC.digest(
              "sha256",
              [Rails.configuration.x.image_delivery.key].pack("H*"),
              [Rails.configuration.x.image_delivery.salt].pack("H*") + unsigned_path
            ),
            padding: false
          )

          assert_equal expected_signature, signature
          assert_equal "rs:fill:40:40:1", processing
          source = Base64.urlsafe_decode64(encoded_source.join)
          assert source.start_with?("http://host.docker.internal:45678/rails/active_storage/blobs/proxy/")
          assert_includes source, blob.signed_id
          assert_not_includes url, "/unsafe/"
        ensure
          blob&.purge
        end
      end
    RUBY
  end

  delivery_description = if delivery == "imgproxy"
    <<~MARKDOWN
      `imgproxy`配信では`imgproxy-rails`がActive Storage named variantを署名済みimgproxy URLへ解決します。元画像sourceは`rails_storage_proxy`の署名済みpathだけで、Active Storage DBが元画像のsource of truthです。任意の外部URLは受け付けません。

      必須環境変数は`IMGPROXY_ENDPOINT`、`IMGPROXY_KEY`、`IMGPROXY_SALT`です。keyとsaltは偶数長hexで指定します。productionのsource originは`APPLICATION_ORIGIN`から取得し、HTTPSかつpublic addressだけを許可します。development/testでは`IMGPROXY_SOURCE_ORIGIN`も明示してください。

      imgproxyはRailsとは別の必須serviceです。`bin/imgproxy-dev`は`darthsim/imgproxy:v4.0.12`を直接起動します。Rails用Dokploy imageや`Procfile.prod`にはimgproxyを追加しません。

      ```console
      export IMGPROXY_ENDPOINT=http://localhost:8080
      export IMGPROXY_KEY="$(openssl rand -hex 32)"
      export IMGPROXY_SALT="$(openssl rand -hex 32)"
      export IMGPROXY_SOURCE_ORIGIN=http://host.docker.internal:3000
      bin/imgproxy-dev
      ```
    MARKDOWN
  else
    "`rails`配信ではActive Storage公式のrepresentation routeを使用します。imgproxy Gem、設定、外部serviceは不要です。\n"
  end
  create_file "docs/image_delivery.md", <<~MARKDOWN, force: true
    # Image delivery

    Active Storageのattachment、blob metadata、元画像は、配信方式にかかわらずActive Storage／Active Storage DBをsource of truthとします。Rails配信の処理済みvariantはActive Storage DBへ保存します。imgproxyの派生画像は外部serviceが生成・cacheしますが、永続的なsourceにはしません。variant processorはlibvipsです。
    Docker外で開発・testするhostにもlibvips runtimeが必要です（macOSでは例: `brew install vips`）。

    #{delivery_description}
    ## Avatar policy

    Profile avatarは`header_avatar`（40×40）と`profile_avatar`（64×64）のnamed variantだけを使用し、中央基準で正方形にcropします。uploadは静止画JPEG、PNG、WebP、5 MiB以下、幅・高さ4096px以下に限定します。GIF、APNG、animated WebP、空・破損・偽装画像は拒否します。

    Action Text添付はavatar policyの対象外です。表示、download、削除はAction TextとActive Storageの標準契約を維持します。
  MARKDOWN
  append_to_file "README.md", "\n## Image delivery\n\nSee [docs/image_delivery.md](docs/image_delivery.md) for variant, upload, and deployment requirements.\n"

  create_file "test/support/image_test_fixture.rb", <<~'RUBY', force: true
    require "base64"
    require "stringio"

    module ImageTestFixture
      PNG = Base64.decode64("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")

      module_function

      def png_blob(filename: "attachment.png")
        ActiveStorage::Blob.create_and_upload!(
          io: StringIO.new(PNG), filename:, content_type: "image/png"
        )
      end
    end
  RUBY
  append_to_file "test/test_helper.rb", "\nrequire_relative \"support/image_test_fixture\"\n"
end

def install_action_text
  generate "action_text:install"
end

def install_active_storage_db
  require "fileutils"

  migration_pattern = "db/migrate/*_create_active_storage_db_files.active_storage_db.rb"
  existing_migrations = Dir.glob(migration_pattern)
  raise "Active Storage DBのmigrationが既に存在します: #{existing_migrations.join(', ')}" unless existing_migrations.empty?

  run_checked "bin/rails active_storage_db:install:migrations"
  installed_migrations = Dir.glob(migration_pattern)
  raise "Active Storage DBのmigrationを一意に特定できません: #{installed_migrations.join(', ')}" unless installed_migrations.one?

  FileUtils.mkdir_p("db/storage_migrate")
  FileUtils.mv(installed_migrations.first, File.join("db/storage_migrate", File.basename(installed_migrations.first)))
end

def replace_active_storage_service(environment)
  require "prism"

  path = "config/environments/#{environment}.rb"
  source = File.binread(path)
  result = Prism.parse(source)
  raise "#{path}をRubyとして解析できません: #{result.errors.map(&:message).join(', ')}" unless result.success?

  assignments = []
  queue = [result.value]
  until queue.empty?
    node = queue.shift
    if node.is_a?(Prism::CallNode) && node.name == :service=
      active_storage = node.receiver
      config = active_storage&.receiver
      assignments << node if active_storage&.name == :active_storage && config&.name == :config && config.receiver.nil?
    end
    queue.concat(node.compact_child_nodes)
  end
  raise "#{path}のActive Storage service設定が一意ではありません" unless assignments.one?

  assignment = assignments.first
  File.binwrite(
    path,
    source.byteslice(0, assignment.location.start_offset) +
      "config.active_storage.service = :db" +
      source.byteslice(assignment.location.end_offset..)
  )
end

def configure_active_storage_db
  create_file "config/storage.yml", <<~YAML, force: true
    db:
      service: DB
  YAML
  %w[development test production].each { |environment| replace_active_storage_service(environment) }
  create_file "config/initializers/active_storage_db.rb", <<~RUBY, force: true
    # frozen_string_literal: true

    Rails.application.config.after_initialize do
      ActiveStorageDB::ApplicationRecord.connects_to database: { writing: :storage, reading: :storage }
    end
  RUBY
  route 'mount ActiveStorageDB::Engine => "/active_storage_db"'
  create_file "test/models/active_storage_db_test.rb", <<~RUBY, force: true
    # frozen_string_literal: true

    require "test_helper"
    require "stringio"

    class ActiveStorageDBTest < ActiveSupport::TestCase
      test "stores, downloads, and deletes attachment data in the storage database" do
        contents = "sqlite attachment data"
        blob = ActiveStorage::Blob.create_and_upload!(
          io: StringIO.new(contents),
          filename: "attachment.txt",
          content_type: "text/plain"
        )

        stored_file = ActiveStorageDB::File.find_by!(ref: blob.key)
        assert_equal "storage", ActiveStorageDB::ApplicationRecord.connection_db_config.name
        assert_equal contents, stored_file.data
        assert_equal contents, blob.download

        key = blob.key
        blob.purge
        refute ActiveStorageDB::File.exists?(ref: key)
      end
    end
  RUBY
end

def configure_lexxy
  importmap_path = "config/importmap.rb"
  importmap = File.binread(importmap_path)
  raise "#{importmap_path}には既にLexxyが登録されています" if importmap.include?('pin "lexxy"')
  raise "#{importmap_path}には既にActive Storageが登録されています" if importmap.include?('pin "@rails/activestorage"')

  append_to_file importmap_path, <<~RUBY
    pin "lexxy", to: "lexxy.js"
    pin "@rails/activestorage", to: "activestorage.esm.js"
  RUBY

  application_javascript_path = "app/javascript/application.js"
  application_javascript = File.binread(application_javascript_path)
  raise "#{application_javascript_path}には既にLexxy importがあります" if application_javascript.lines.any? { |line| line.strip == 'import "lexxy"' }

  append_to_file application_javascript_path, "\nimport \"lexxy\"\n"
  create_file "app/views/layouts/action_text/contents/_content.html.erb", <<~ERB, force: true
    <div class="lexxy-content">
      <%= yield -%>
    </div>
  ERB
end

def install_daisyui
  stylesheet_path = "app/assets/tailwind/application.css"
  stylesheet = File.binread(stylesheet_path)
  import_statement = '@import "tailwindcss";'
  raise "#{stylesheet_path}のTailwind CSS importが一意ではありません" unless stylesheet.lines.count { |line| line.strip == import_statement } == 1
  raise "#{stylesheet_path}には既にdaisyUI pluginが登録されています" if stylesheet.include?('@plugin "daisyui"')

  create_file "package.json", JSON.pretty_generate("private" => true) + "\n"
  run_checked "npm install --save-dev daisyui@latest"
  package = JSON.parse(File.read("package.json"))
  raise "package.jsonにdaisyUIが登録されていません" unless package.dig("devDependencies", "daisyui")
  raise "package-lock.jsonが生成されませんでした" unless File.file?("package-lock.json")

  append_to_file stylesheet_path, <<~CSS
    @plugin "daisyui" {
      themes: false;
      logs: false;
    }

    @plugin "daisyui/theme" {
      name: "rapid-rails";
      default: true;
      prefersdark: false;
      color-scheme: light;

      --color-base-100: #ffffff;
      --color-base-200: #f1f5f9;
      --color-base-300: #d6e3ed;
      --color-base-content: rgba(0, 0, 0, 0.82);
      --color-primary: #3ea8ff;
      --color-primary-content: #ffffff;
      --color-secondary: #0f83fd;
      --color-secondary-content: #ffffff;
      --color-accent: #3ea8ff;
      --color-accent-content: #ffffff;
      --color-neutral: rgba(0, 0, 0, 0.55);
      --color-neutral-content: #ffffff;
      --color-info: #3ea8ff;
      --color-info-content: #ffffff;
      --color-success: #10b981;
      --color-success-content: rgba(0, 0, 0, 0.82);
      --color-warning: #f59e0b;
      --color-warning-content: rgba(0, 0, 0, 0.82);
      --color-error: #f43f5e;
      --color-error-content: #ffffff;

      --radius-selector: 0.5rem;
      --radius-field: 0.5rem;
      --radius-box: 0.75rem;
      --size-selector: 0.25rem;
      --size-field: 0.25rem;
      --border: 1px;
      --depth: 0;
      --noise: 0;
    }

    @layer base {
      html {
        font-size: 16px;
      }

      body {
        font-family: -apple-system, system-ui, "Hiragino Kaku Gothic ProN", "Hiragino Sans", Meiryo, sans-serif;
        font-size: 1rem;
        line-height: 1.8;
        letter-spacing: normal;
        font-feature-settings: normal;
        word-break: break-all;
        overflow-wrap: break-word;
      }

      h1, h2, h3, h4, h5, h6 {
        line-height: 1.5;
      }

      code, pre, kbd, samp {
        font-family: SFMono-Regular, Consolas, Menlo, monospace;
        font-size: 0.875rem;
        line-height: 1.5;
      }
    }

    @utility shadow-elevation-1 {
      box-shadow: 0 2px 4px rgba(0, 0, 0, 0.08);
    }

    @utility shadow-elevation-2 {
      box-shadow: 0 4px 12px rgba(0, 0, 0, 0.1);
    }

    @utility shadow-elevation-3 {
      box-shadow: 0 8px 24px rgba(0, 0, 0, 0.12);
    }

    @utility input-rapid {
      --input-color: var(--color-base-300);
      font-size: 1rem;

      &:focus,
      &:focus-within {
        --input-color: var(--color-primary);
      }
    }

    @utility btn-rapid {
      font-size: 1rem;
      font-weight: 700;
    }
  CSS
  append_to_file ".gitignore", "\n/node_modules\n" unless File.read(".gitignore").lines.map(&:strip).include?("/node_modules")
end

def configure_generator_view_templates
  create_file "lib/templates/erb/scaffold/_form.html.erb.tt", <<~ERB, force: true
    <%%= form_with(model: <%= model_resource_name %>, class: "space-y-5") do |form| %>
      <%% if <%= singular_table_name %>.errors.any? %>
        <div class="alert alert-error" role="alert">
          <div>
            <h2 class="font-semibold leading-[1.5]"><%%= pluralize(<%= singular_table_name %>.errors.count, "error") %> prohibited this <%= singular_table_name %> from being saved:</h2>
            <ul class="mt-2 list-disc pl-5">
              <%% <%= singular_table_name %>.errors.each do |error| %>
                <li><%%= error.full_message %></li>
              <%% end %>
            </ul>
          </div>
        </div>
      <%% end %>

    <% attributes.each do |attribute| -%>
    <% if attribute.password_digest? -%>
      <fieldset class="fieldset">
        <legend class="fieldset-legend"><%%= form.label :password %></legend>
        <%%= form.password_field :password, class: "input input-rapid w-full" %>
      </fieldset>

      <fieldset class="fieldset">
        <legend class="fieldset-legend"><%%= form.label :password_confirmation %></legend>
        <%%= form.password_field :password_confirmation, class: "input input-rapid w-full" %>
      </fieldset>
    <% elsif attribute.field_type == :checkbox -%>
      <fieldset class="fieldset">
        <legend class="fieldset-legend"><%= attribute.human_name %></legend>
        <label class="label cursor-pointer justify-start gap-3">
          <%%= form.checkbox :<%= attribute.column_name %>, class: "checkbox" %>
          <span><%= attribute.human_name %></span>
        </label>
      </fieldset>
    <% else -%>
    <% field_class = case attribute.field_type
       when :textarea, :rich_textarea then "textarea w-full"
       when :file_field then "file-input w-full"
       else "input input-rapid w-full"
       end -%>
      <fieldset class="fieldset">
        <legend class="fieldset-legend"><%%= form.label :<%= attribute.column_name %> %></legend>
    <% if attribute.attachments? -%>
        <%%= form.<%= attribute.field_type %> :<%= attribute.column_name %>, multiple: true, class: "<%= field_class %>" %>
    <% else -%>
        <%%= form.<%= attribute.field_type %> :<%= attribute.column_name %>, class: "<%= field_class %>" %>
    <% end -%>
      </fieldset>

    <% end -%>
    <% end -%>
      <div class="flex justify-end">
        <%%= form.submit class: "btn btn-primary btn-rapid" %>
      </div>
    <%% end %>
  ERB

  create_file "lib/templates/erb/scaffold/index.html.erb.tt", <<~ERB, force: true
    <%% content_for :title, "<%= human_name.pluralize %>" %>

    <div class="mx-auto w-full max-w-6xl space-y-6 px-5 py-10 md:py-14">
      <header class="flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
        <h1 class="text-2xl font-bold leading-[1.5]"><%= human_name.pluralize %></h1>
        <%%= link_to "New <%= human_name.downcase %>", <%= new_helper(type: :path) %>, class: "btn btn-primary btn-rapid" %>
      </header>

      <section class="card card-border border-base-300 bg-base-100 shadow-none">
        <div class="card-body">
          <div class="overflow-x-auto">
            <table class="table table-sm table-pin-rows">
              <thead>
                <tr>
    <% attributes.reject(&:password_digest?).each do |attribute| -%>
                  <th scope="col"><%= attribute.human_name %></th>
    <% end -%>
                  <th scope="col"><span class="sr-only">Actions</span></th>
                </tr>
              </thead>
              <tbody id="<%= plural_table_name %>">
                <%% @<%= plural_table_name %>.each do |<%= singular_table_name %>| %>
                  <tr id="<%%= dom_id <%= singular_table_name %> %>">
    <% attributes.reject(&:password_digest?).each do |attribute| -%>
                    <td>
    <% if attribute.attachment? -%>
                      <%%= link_to <%= singular_table_name %>.<%= attribute.column_name %>.filename, <%= singular_table_name %>.<%= attribute.column_name %> if <%= singular_table_name %>.<%= attribute.column_name %>.attached? %>
    <% elsif attribute.attachments? -%>
                      <%% <%= singular_table_name %>.<%= attribute.column_name %>.each do |<%= attribute.singular_name %>| %>
                        <div><%%= link_to <%= attribute.singular_name %>.filename, <%= attribute.singular_name %> %></div>
                      <%% end %>
    <% else -%>
                      <%%= <%= singular_table_name %>.<%= attribute.column_name %> %>
    <% end -%>
                    </td>
    <% end -%>
                    <td class="text-right">
                      <%%= link_to "Show this <%= human_name.downcase %>", <%= model_resource_name(singular_table_name) %>, class: "btn btn-rapid" %>
                    </td>
                  </tr>
                <%% end %>
              </tbody>
            </table>
          </div>
        </div>
      </section>
    </div>
  ERB

  create_file "lib/templates/erb/scaffold/partial.html.erb.tt", <<~ERB, force: true
    <div id="<%%= dom_id <%= singular_name %> %>">
      <ul class="list">
    <% attributes.reject(&:password_digest?).each do |attribute| -%>
        <li class="list-row">
          <span class="text-sm text-neutral"><%= attribute.human_name %></span>
          <div class="list-col-grow min-w-0">
    <% if attribute.attachment? -%>
            <%%= link_to <%= singular_name %>.<%= attribute.column_name %>.filename, <%= singular_name %>.<%= attribute.column_name %> if <%= singular_name %>.<%= attribute.column_name %>.attached? %>
    <% elsif attribute.attachments? -%>
            <%% <%= singular_name %>.<%= attribute.column_name %>.each do |<%= attribute.singular_name %>| %>
              <div><%%= link_to <%= attribute.singular_name %>.filename, <%= attribute.singular_name %> %></div>
            <%% end %>
    <% else -%>
            <%%= <%= singular_name %>.<%= attribute.column_name %> %>
    <% end -%>
          </div>
        </li>
    <% end -%>
      </ul>
    </div>
  ERB

  create_file "lib/templates/erb/scaffold/show.html.erb.tt", <<~ERB, force: true
    <%% content_for :title, "<%= human_name %>" %>

    <div class="mx-auto w-full max-w-[820px] space-y-6 px-5 py-10 md:py-14">
      <h1 class="text-2xl font-bold leading-[1.5]"><%= human_name %></h1>

      <section class="card card-border border-base-300 bg-base-100 shadow-none">
        <div class="card-body">
          <%%= render @<%= singular_table_name %> %>
          <div class="card-actions justify-end">
            <%%= link_to "Edit this <%= human_name.downcase %>", <%= edit_helper(type: :path) %>, class: "btn btn-rapid" %>
            <%%= link_to "Back to <%= human_name.pluralize.downcase %>", <%= index_helper(type: :path) %>, class: "btn btn-rapid" %>
            <%%= button_to "Destroy this <%= human_name.downcase %>", <%= model_resource_name(prefix: "@") %>, method: :delete, class: "btn btn-outline btn-error btn-rapid" %>
          </div>
        </div>
      </section>
    </div>
  ERB

  create_file "lib/templates/erb/scaffold/new.html.erb.tt", <<~ERB, force: true
    <%% content_for :title, "New <%= human_name.downcase %>" %>

    <div class="mx-auto w-full max-w-[820px] space-y-6 px-5 py-10 md:py-14">
      <header class="flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
        <h1 class="text-2xl font-bold leading-[1.5]">New <%= human_name.downcase %></h1>
        <%%= link_to "Back to <%= human_name.pluralize.downcase %>", <%= index_helper(type: :path) %>, class: "btn btn-rapid" %>
      </header>

      <section class="card card-border border-base-300 bg-base-100 shadow-none">
        <div class="card-body">
          <%%= render "form", <%= singular_table_name %>: @<%= singular_table_name %> %>
        </div>
      </section>
    </div>
  ERB

  create_file "lib/templates/erb/scaffold/edit.html.erb.tt", <<~ERB, force: true
    <%% content_for :title, "Editing <%= human_name.downcase %>" %>

    <div class="mx-auto w-full max-w-[820px] space-y-6 px-5 py-10 md:py-14">
      <header class="flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
        <h1 class="text-2xl font-bold leading-[1.5]">Editing <%= human_name.downcase %></h1>
        <div class="flex flex-col gap-3 sm:flex-row">
          <%%= link_to "Show this <%= human_name.downcase %>", <%= model_resource_name(prefix: "@") %>, class: "btn btn-rapid" %>
          <%%= link_to "Back to <%= human_name.pluralize.downcase %>", <%= index_helper(type: :path) %>, class: "btn btn-rapid" %>
        </div>
      </header>

      <section class="card card-border border-base-300 bg-base-100 shadow-none">
        <div class="card-body">
          <%%= render "form", <%= singular_table_name %>: @<%= singular_table_name %> %>
        </div>
      </section>
    </div>
  ERB

  create_file "lib/templates/erb/controller/view.html.erb.tt", <<~ERB, force: true
    <%% content_for :title, "<%= class_name %>#<%= @action %>" %>

    <div class="mx-auto w-full max-w-[820px] px-5 py-10 md:py-14">
      <section class="card card-border border-base-300 bg-base-100 shadow-none">
        <div class="card-body">
          <h1 class="card-title text-2xl leading-[1.5]"><%= class_name %>#<%= @action %></h1>
          <p class="text-neutral">Find me in <%= @path %></p>
        </div>
      </section>
    </div>
  ERB
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
  generate "devise:views", "-v", "sessions", "registrations", "passwords", "mailer"
  create_file "test/fixtures/users.yml", <<~YAML, force: true
    one:
      email: one@example.com
      encrypted_password: <%= Devise::Encryptor.digest(User, "password123") %>

    two:
      email: two@example.com
      encrypted_password: <%= Devise::Encryptor.digest(User, "password123") %>
  YAML
end

def install_wallet_siwe
  generate "authentication", "--api"
  remove_ruby_call_statement("Gemfile", :gem, "bcrypt")
  remove_ruby_call_statement("config/routes.rb", :resources, "passwords")
  remove_ruby_call_statement("config/routes.rb", :resource, "session")
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
        expected_statement = Rails.configuration.x.application_identity.siwe_statement
        valid_message = message.uri == request.base_url && message.chain_id.to_i.positive? &&
          message.statement == expected_statement
        return head :unauthorized unless valid_message
        user = User.find_or_create_by!(wallet_address: message.address.downcase)
        start_new_session_for(user)
        render json: { redirect_url: after_authentication_url }
      rescue Siwe::Error, ActionController::ParameterMissing, ActiveRecord::RecordInvalid
        head :unauthorized
      end

      def destroy
        terminate_session
        redirect_to new_session_path, status: :see_other
      end
    end
  RUBY
  create_file "config/initializers/siwe.rb", "require \"siwe\"\n"

  create_file "test/support/siwe_test_request.rb", <<~RUBY, force: true
    module SiweTestRequest
      private
        def siwe_test_headers(key)
          address_groups = key.address.to_s.delete_prefix("0x").scan(/.{4}/).first(4)
          { "REMOTE_ADDR" => "2001:db8::\#{address_groups.join(":")}" }
        end
    end

    class ActiveSupport::TestCase
      include SiweTestRequest
    end
  RUBY
  append_to_file "test/test_helper.rb", <<~RUBY

    require_relative "support/siwe_test_request"
  RUBY

  create_file "app/javascript/controllers/siwe_sign_in_controller.js", <<~JAVASCRIPT
    import { Controller } from "@hotwired/stimulus"

    export default class extends Controller {
      static targets = ["error"]
      static values = {
        statement: String,
        walletMissing: String,
        nonceError: String,
        verificationError: String
      }

      async signIn() {
        this.errorTarget.classList.add("hidden")
        this.errorTarget.textContent = ""

        try {
          if (!window.ethereum) throw new Error(this.walletMissingValue)
          const web3 = new window.Web3(window.ethereum)
          await window.ethereum.request({ method: "eth_requestAccounts" })
          const [address] = await web3.eth.getAccounts()
          const chainId = Number(await web3.eth.getChainId())
          const nonceResponse = await fetch("/session/nonce", { headers: { Accept: "application/json" } })
          if (!nonceResponse.ok) throw new Error(this.nonceErrorValue)
          const { nonce } = await nonceResponse.json()
          const domain = window.location.host
          const uri = window.location.origin
          const issuedAt = new Date().toISOString()
          const message = `${domain} wants you to sign in with your Ethereum account:\n${address}\n\n${this.statementValue}\n\nURI: ${uri}\nVersion: 1\nChain ID: ${chainId}\nNonce: ${nonce}\nIssued At: ${issuedAt}`
          const signature = await web3.eth.personal.sign(message, address, "")
          const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content
          const response = await fetch("/session", {
            method: "POST",
            headers: { "Content-Type": "application/json", "X-CSRF-Token": csrfToken, Accept: "application/json" },
            body: JSON.stringify({ message, signature })
          })
          if (!response.ok) throw new Error(this.verificationErrorValue)
          window.location.assign((await response.json()).redirect_url)
        } catch (exception) {
          this.errorTarget.textContent = exception.message
          this.errorTarget.classList.remove("hidden")
        }
      }
    }
  JAVASCRIPT
  route "resource :session, only: %i[new create destroy]"
  route "get 'session/nonce', to: 'sessions#nonce'"
  get WEB3_URL, "public/vendor/web3-4.16.0.min.js"
  actual_web3_sha256 = Digest::SHA256.file("public/vendor/web3-4.16.0.min.js").hexdigest
  raise "Web3.jsのSHA-256が一致しません" unless actual_web3_sha256 == WEB3_SHA256
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
  account_navigation_count = 2 + (VALUES.fetch("profile_features").any? ? 1 : 0) +
    (VALUES.fetch("api") == "enable" ? 1 : 0) + (VALUES.fetch("web_push") == "use" ? 1 : 0)
  create_file "test/fixtures/users.yml", <<~YAML, force: true
    one:
      wallet_address: 0x1111111111111111111111111111111111111111

    two:
      wallet_address: 0x2222222222222222222222222222222222222222
  YAML
  create_file "test/controllers/sessions_controller_test.rb", <<~RUBY, force: true
    require 'test_helper'
    require 'eth'

    class SessionsControllerTest < ActionDispatch::IntegrationTest
      test 'creates one user per wallet address after a valid SIWE signature' do
        key = Eth::Key.new
        get session_nonce_url, headers: siwe_test_headers(key)
        nonce = response.parsed_body.fetch('nonce')
        message = Siwe::Message.new(
          domain: 'www.example.com',
          address: key.address.to_s,
          uri: 'http://www.example.com',
          chain_id: 1,
          nonce: nonce,
          issued_at: Time.current.iso8601,
          statement: Rails.configuration.x.application_identity.siwe_statement
        ).prepare_message

        assert_difference('User.count', 1) do
          post session_url, params: { message: message, signature: key.personal_sign(message) },
            headers: siwe_test_headers(key), as: :json
        end
        assert_response :success

        get account_url
        assert_response :success
        assert_select '[data-layout="account"].mx-auto.w-full.max-w-6xl.px-5', count: 1
        account_menu = I18n.t("navigation.account_menu")
        assert_select 'nav[aria-label=?] > .menu > li > a', account_menu, count: #{account_navigation_count}
        assert_select 'nav[aria-label=?] > .menu > li > a > svg.size-5[aria-hidden="true"][data-slot="icon"]', account_menu, count: #{account_navigation_count}
        assert_select 'nav[aria-label=?] a[href=?]', account_menu, root_path, count: 0
        assert_select '.badge', text: 'ID', count: 0

        get edit_account_url
        assert_response :success
        assert_select 'nav[aria-label=?] a.menu-active[aria-current="page"][href=?]', account_menu, edit_account_path, count: 1
        assert_select '.list .badge', text: 'ID', count: 1
        assert_select '.list p.font-semibold', text: key.address.to_s.downcase, count: 1
        assert_select '.card-actions form[action=?][method="post"]', account_path, count: 1 do
          assert_select 'input[name="_method"][value="delete"]', count: 1
          assert_select 'button.btn.btn-error[data-turbo-confirm]', text: I18n.t("accounts.edit.delete"), count: 1
        end

        assert_difference(['User.count', 'Session.count'], -1) do
          delete account_url
        end
        assert_redirected_to root_url
        follow_redirect!
        assert_select '.alert.alert-success', text: I18n.t("accounts.destroy.notice"), count: 1
      end
    end
  RUBY
end

def configure_roles
  devise = VALUES.fetch("account_authentication") == "devise"
  identifier_attribute = devise ? "email" : "wallet_address"
  identifier_key = devise ? "email" : "wallet_address"
  identifier_environment = devise ? "ADMIN_EMAIL" : "ADMIN_WALLET_ADDRESS"
  authentication_callback = devise ? "    before_action :authenticate_user!\n" : ""
  authorization_user = devise ? "current_user" : "Current.user"

  generate "action_policy:install"
  inject_into_class "app/policies/application_policy.rb", "ApplicationPolicy", <<~RUBY
      private
        def admin?
          user&.has_role?(:admin) || false
        end

  RUBY
  generate "model", "UserRole", "user:references", "role:string"
  migration = Dir.glob("db/migrate/*_create_user_roles.rb")
  raise "CreateUserRoles migrationが一意ではありません" unless migration.one?

  create_file migration.first, <<~RUBY, force: true
    class CreateUserRoles < ActiveRecord::Migration[8.1]
      def change
        create_table :user_roles do |t|
          t.references :user, null: false, foreign_key: { on_delete: :cascade }
          t.string :role, null: false
          t.timestamps
        end

        add_index :user_roles, [:user_id, :role], unique: true
        add_index :user_roles, :role
        add_check_constraint :user_roles, "role IN ('admin')", name: "user_roles_role_check"
      end
    end
  RUBY

  create_file "app/models/user_role.rb", <<~RUBY, force: true
    class UserRole < ApplicationRecord
      ROLES = { admin: "admin" }.freeze

      belongs_to :user

      enum :role, ROLES, validate: true
      validates :role, uniqueness: { scope: :user_id }

      before_destroy :ensure_admin_remains, if: :admin?

      private
        def ensure_admin_remains
          return if self.class.admin.where.not(id: id).exists?

          errors.add(:base, I18n.t("roles.errors.last_admin"))
          throw :abort
        end
    end
  RUBY

  inject_into_class "app/models/user.rb", "User", <<~RUBY
      has_many :user_roles, dependent: :destroy

      def has_role?(role)
        normalized_role = UserRole.roles[role.to_s]
        return false if normalized_role.nil?

        if user_roles.loaded?
          user_roles.any? { |assignment| assignment.role == normalized_role }
        else
          user_roles.exists?(role: normalized_role)
        end
      end

      def grant_role!(role)
        normalized_role = UserRole.roles.fetch(role.to_s)
        user_roles.find_or_create_by!(role: normalized_role)
      end

      def revoke_role!(role)
        normalized_role = UserRole.roles.fetch(role.to_s)
        assignment = user_roles.find_by(role: normalized_role)
        return if assignment.nil?

        assignment.destroy!
      end

      def last_admin?
        has_role?(:admin) && UserRole.admin.where.not(user_id: id).none?
      end

  RUBY

  inject_into_class "app/controllers/application_controller.rb", "ApplicationController", <<~RUBY
      include Pagy::Method

      authorize :user, through: :authorization_user
      helper_method :authorization_user

      rescue_from ActionPolicy::Unauthorized, with: :render_forbidden

      private
        def authorization_user
          #{authorization_user}
        end

        def render_forbidden
          head :forbidden
        end

  RUBY

  append_to_file "test/test_helper.rb", <<~RUBY

    require "action_policy/test_helper"

    class ActionDispatch::IntegrationTest
      include ActionPolicy::TestHelper
    end
  RUBY

  create_file "app/policies/user_policy.rb", <<~RUBY, force: true
    class UserPolicy < ApplicationPolicy
      def index?
        admin?
      end

      def manage_roles?
        admin?
      end

      relation_scope do |relation|
        admin? ? relation : relation.none
      end
    end
  RUBY

  create_file "app/controllers/admin/base_controller.rb", <<~RUBY, force: true
    module Admin
      class BaseController < ApplicationController
        layout "admin"
    #{authentication_callback}  end
    end
  RUBY

  create_file "app/controllers/admin/users_controller.rb", <<~RUBY, force: true
    module Admin
      class UsersController < BaseController
        def index
          authorize! User, to: :index?
          users = authorized_scope(User.all).includes(:user_roles).order(:id)
          @pagy, @users = pagy(:offset, users, limit: 25)
        end
      end
    end
  RUBY

  create_file "app/controllers/admin/user_roles_controller.rb", <<~RUBY, force: true
    module Admin
      class UserRolesController < BaseController
        before_action :set_user

        def create
          authorize! @user, to: :manage_roles?
          @user.grant_role!(role_param)
          redirect_to admin_users_path, notice: I18n.t("admin.user_roles.create.notice"), status: :see_other
        rescue KeyError, ActiveRecord::RecordInvalid
          head :unprocessable_content
        end

        def destroy
          authorize! @user, to: :manage_roles?
          if @user == authorization_user
            redirect_to admin_users_path, alert: I18n.t("admin.user_roles.destroy.self_forbidden"), status: :see_other
            return
          end

          @user.revoke_role!(role_param)
          redirect_to admin_users_path, notice: I18n.t("admin.user_roles.destroy.notice"), status: :see_other
        rescue KeyError
          head :unprocessable_content
        rescue ActiveRecord::RecordNotDestroyed => error
          redirect_to admin_users_path, alert: error.record.errors.full_messages.to_sentence, status: :see_other
        end

        private
          def set_user
            @user = User.find(params.expect(:user_id))
          end

          def role_param
            params.expect(:role)
          end
      end
    end
  RUBY

  route <<~RUBY
    namespace :admin do
      resources :users, only: :index do
        resources :roles, only: %i[create destroy], controller: "user_roles", param: :role
      end
    end
  RUBY

  create_file "app/views/admin/users/index.html.erb", <<~ERB, force: true
    <% content_for :title, t("admin.users.title") %>
    <div class="space-y-6">
      <header>
        <p class="text-sm font-semibold text-primary"><%= t("admin.users.eyebrow") %></p>
        <h1 class="mt-1 text-2xl font-bold leading-[1.5]"><%= t("admin.users.title") %></h1>
        <p class="mt-2 text-sm text-neutral"><%= t("admin.users.description") %></p>
      </header>

      <section class="card card-border border-base-300 bg-base-100 shadow-none">
        <div class="card-body">
          <div class="overflow-x-auto">
            <table class="table table-sm table-pin-rows">
              <thead>
                <tr>
                  <th scope="col">ID</th>
                  <th scope="col"><%= t("admin.users.identifier.#{identifier_key}") %></th>
                  <th scope="col"><%= t("admin.users.role") %></th>
                  <th scope="col"><span class="sr-only"><%= t("common.actions") %></span></th>
                </tr>
              </thead>
              <tbody>
                <% @users.each do |user| %>
                  <tr>
                    <td><%= user.id %></td>
                    <td class="break-all"><%= user.#{identifier_attribute} %></td>
                    <td>
                      <% if user.has_role?(:admin) %>
                        <span class="badge"><%= t("admin.users.admin") %></span>
                      <% else %>
                        <span class="text-sm text-neutral"><%= t("common.none") %></span>
                      <% end %>
                    </td>
                    <td class="text-right">
                      <% if user.has_role?(:admin) %>
                        <% if user == authorization_user %>
                          <button type="button" class="btn btn-disabled btn-rapid" disabled><%= t("admin.users.self_forbidden") %></button>
                        <% else %>
                          <%= button_to t("admin.users.revoke"), admin_user_role_path(user, "admin"), method: :delete, class: "btn btn-outline btn-error btn-rapid", data: { turbo_confirm: t("admin.users.revoke_confirm") } %>
                        <% end %>
                      <% else %>
                        <%= button_to t("admin.users.grant"), admin_user_roles_path(user), params: { role: "admin" }, class: "btn btn-rapid" %>
                      <% end %>
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        </div>
      </section>

      <% if @pagy.last > 1 %>
        <nav aria-label="<%= t("admin.users.pagination") %>">
          <div class="join">
            <% if (previous_url = @pagy.page_url(:previous)) %>
              <%= link_to t("common.previous"), previous_url, class: "btn join-item" %>
            <% else %>
              <span class="btn btn-disabled join-item" role="link" aria-disabled="true"><%= t("common.previous") %></span>
            <% end %>
            <span class="btn btn-active join-item" aria-current="page"><%= @pagy.page %> / <%= @pagy.last %></span>
            <% if (next_url = @pagy.page_url(:next)) %>
              <%= link_to t("common.next"), next_url, class: "btn join-item" %>
            <% else %>
              <span class="btn btn-disabled join-item" role="link" aria-disabled="true"><%= t("common.next") %></span>
            <% end %>
          </div>
        </nav>
      <% end %>
    </div>
  ERB

  create_file "lib/tasks/roles.rake", <<~RAKE, force: true
    namespace :roles do
      desc "Grant the admin role to an existing User identified by #{identifier_attribute}"
      task :grant_admin, [:identifier] => :environment do |_task, arguments|
        identifier = arguments[:identifier].to_s.strip
        raise ArgumentError, "identifierを指定してください" if identifier.empty?

        user = User.find_by!(#{identifier_attribute}: identifier.downcase)
        user.grant_role!(:admin)
        puts "admin role granted to #{identifier_attribute}=\#{user.#{identifier_attribute}}"
      end
    end
  RAKE

  append_to_file "db/seeds.rb", <<~RUBY

    local_seeds = Rails.root.join("db/seeds.local.rb")
    load local_seeds if local_seeds.file?
  RUBY
  create_file "db/seeds.local.rb.example", <<~RUBY, force: true
    admin = User.find_by!(#{identifier_attribute}: ENV.fetch("#{identifier_environment}").downcase)
    admin.grant_role!(:admin)
  RUBY
  append_to_file ".gitignore", "\n/db/seeds.local.rb\n" unless File.read(".gitignore").lines.map(&:strip).include?("/db/seeds.local.rb")

  create_locale_pair("roles",
    ja: {
      "roles" => { "errors" => { "last_admin" => "最後の管理者roleは解除できません" } },
      "admin" => {
        "users" => { "eyebrow" => "管理", "title" => "ユーザー管理", "description" => "固定roleをユーザーへ付与または解除します。", "identifier" => { "email" => "メールアドレス", "wallet_address" => "ウォレットアドレス" }, "role" => "Role", "admin" => "管理者", "self_forbidden" => "自分自身は解除不可", "revoke" => "管理者を解除", "revoke_confirm" => "管理者roleを解除しますか？", "grant" => "管理者にする", "pagination" => "ユーザー一覧のページング" },
        "user_roles" => { "create" => { "notice" => "管理者roleを付与しました" }, "destroy" => { "notice" => "管理者roleを解除しました", "self_forbidden" => "自分自身の管理者roleは解除できません" } }
      },
      "accounts" => { "destroy" => { "last_admin" => "最後の管理者はアカウントを削除できません" } }
    },
    en: {
      "roles" => { "errors" => { "last_admin" => "The final administrator role cannot be revoked" } },
      "admin" => {
        "users" => { "eyebrow" => "Administration", "title" => "User management", "description" => "Grant or revoke the fixed role for each user.", "identifier" => { "email" => "Email address", "wallet_address" => "Wallet address" }, "role" => "Role", "admin" => "Administrator", "self_forbidden" => "You cannot revoke your own role", "revoke" => "Revoke administrator", "revoke_confirm" => "Revoke the administrator role?", "grant" => "Make administrator", "pagination" => "User list pagination" },
        "user_roles" => { "create" => { "notice" => "Administrator role granted" }, "destroy" => { "notice" => "Administrator role revoked", "self_forbidden" => "You cannot revoke your own administrator role" } }
      },
      "accounts" => { "destroy" => { "last_admin" => "The final administrator cannot delete their account" } }
    }
  )

  create_file "test/fixtures/user_roles.yml", "# Role assignments are created explicitly by tests.\n", force: true

  create_file "test/models/user_role_test.rb", <<~RUBY, force: true
    require "test_helper"

    class UserRoleTest < ActiveSupport::TestCase
      test "rejects invalid and duplicate roles" do
        user = users(:one)
        invalid = user.user_roles.build(role: "unknown")

        assert_not invalid.valid?
        user.grant_role!(:admin)
        duplicate = user.user_roles.build(role: :admin)
        assert_not duplicate.valid?
      end

      test "grants a role idempotently" do
        user = users(:one)

        assert_difference("UserRole.count", 1) { user.grant_role!(:admin) }
        assert_no_difference("UserRole.count") { user.grant_role!(:admin) }
        assert user.has_role?(:admin)
      end

      test "database constraints reject invalid duplicate and null roles" do
        user = users(:one)
        now = Time.current
        user.grant_role!(:admin)

        # These writes intentionally bypass model validations to exercise database constraints.
        # rubocop:disable Rails/SkipsModelValidations
        assert_raises(ActiveRecord::StatementInvalid) do
          UserRole.insert_all!([{ user_id: user.id, role: "admin", created_at: now, updated_at: now }])
        end
        assert_raises(ActiveRecord::StatementInvalid) do
          UserRole.insert_all!([{ user_id: users(:two).id, role: "unknown", created_at: now, updated_at: now }])
        end
        assert_raises(ActiveRecord::NotNullViolation) do
          UserRole.insert_all!([{ user_id: users(:two).id, role: nil, created_at: now, updated_at: now }])
        end
        # rubocop:enable Rails/SkipsModelValidations
      end

      test "does not remove the final admin assignment" do
        user = users(:one)
        user.grant_role!(:admin)

        assert_raises(ActiveRecord::RecordNotDestroyed) { user.revoke_role!(:admin) }
        assert user.reload.has_role?(:admin)
        assert_not user.destroy
      end

      test "removes an admin when another admin remains" do
        first = users(:one)
        second = users(:two)
        first.grant_role!(:admin)
        second.grant_role!(:admin)

        assert first.revoke_role!(:admin)
        assert_not first.reload.has_role?(:admin)
        assert second.reload.has_role?(:admin)
      end

      test "destroys assignments with a non-final admin user" do
        first = users(:one)
        second = users(:two)
        first.grant_role!(:admin)
        second.grant_role!(:admin)
        role_id = first.user_roles.find_by!(role: :admin).id

        assert first.destroy
        assert_not UserRole.exists?(role_id)
      end
    end
  RUBY

  create_file "test/policies/user_policy_test.rb", <<~RUBY, force: true
    require "test_helper"

    class UserPolicyTest < ActiveSupport::TestCase
      test "allows admins and denies regular users" do
        admin = users(:one)
        regular = users(:two)
        admin.grant_role!(:admin)

        assert UserPolicy.new(User, user: admin).apply(:index?)
        assert UserPolicy.new(regular, user: admin).apply(:manage_roles?)
        assert_not UserPolicy.new(User, user: regular).apply(:index?)
        assert_not UserPolicy.new(admin, user: regular).apply(:manage_roles?)
      end

      test "scopes users to admins" do
        admin = users(:one)
        regular = users(:two)
        admin.grant_role!(:admin)

        assert_equal User.all, UserPolicy.new(User, user: admin).apply_scope(User.all, type: :active_record_relation)
        assert_empty UserPolicy.new(User, user: regular).apply_scope(User.all, type: :active_record_relation)
      end
    end
  RUBY

  controller_test_support = if devise
    <<~RUBY
        include Devise::Test::IntegrationHelpers

        setup do
          @admin = User.create!(email: "role-admin@example.com", password: "password123", password_confirmation: "password123")
          @regular = User.create!(email: "role-regular@example.com", password: "password123", password_confirmation: "password123")
          @admin.grant_role!(:admin)
        end

        private
          def sign_in_as(user, _key = nil)
            sign_in user
          end

          def create_additional_users(count)
            count.times do |index|
              User.create!(
                email: "role-page-\#{index}@example.com",
                password: "password123",
                password_confirmation: "password123"
              )
            end
          end
    RUBY
  else
    <<~RUBY
        require "eth"

        setup do
          @admin, @admin_key = create_wallet_user
          @regular, @regular_key = create_wallet_user
          @admin.grant_role!(:admin)
        end

        private
          def create_wallet_user
            key = Eth::Key.new
            [User.create!(wallet_address: key.address.to_s), key]
          end

          def sign_in_as(_user, key)
            get session_nonce_url, headers: siwe_test_headers(key)
            nonce = response.parsed_body.fetch("nonce")
            message = Siwe::Message.new(
              domain: "www.example.com",
              address: key.address.to_s,
              uri: "http://www.example.com",
              chain_id: 1,
              nonce: nonce,
              issued_at: Time.current.iso8601,
              statement: Rails.configuration.x.application_identity.siwe_statement
            ).prepare_message
            post session_url, params: { message: message, signature: key.personal_sign(message) },
              headers: siwe_test_headers(key), as: :json
            assert_response :success
          end

          def create_additional_users(count)
            count.times { |index| User.create!(wallet_address: format("0x%040x", index + 100)) }
          end
    RUBY
  end

  account_deletion_test = if devise
    <<~RUBY
      test "refuses deletion of the last admin account" do
        sign_in_as(@admin)

        delete user_registration_url

        assert_redirected_to edit_user_registration_url
        assert User.exists?(@admin.id)
        assert @admin.reload.has_role?(:admin)
      end
    RUBY
  else
    <<~RUBY
      test "refuses deletion of the last admin account" do
        sign_in_as(@admin, @admin_key)

        delete account_url

        assert_redirected_to edit_account_url
        assert User.exists?(@admin.id)
        assert @admin.reload.has_role?(:admin)
      end
    RUBY
  end

  create_file "test/controllers/admin/users_controller_test.rb", <<~RUBY, force: true
    require "test_helper"

    class Admin::UsersControllerTest < ActionDispatch::IntegrationTest
    #{controller_test_support}
      test "requires authentication" do
        get admin_users_url

        assert_redirected_to #{devise ? "new_user_session_url" : "new_session_url"}
      end

      test "denies regular users" do
        sign_in_as(@regular, #{devise ? "nil" : "@regular_key"})
        get admin_users_url

        assert_response :forbidden
      end

      test "authorizes scopes and renders the admin list" do
        sign_in_as(@admin, #{devise ? "nil" : "@admin_key"})

        assert_have_authorized_scope(type: :active_record_relation, with: UserPolicy) do
          get admin_users_url
        end
        assert_response :success
        assert_select '[data-layout="admin"] nav[aria-label=?]', I18n.t("navigation.admin_menu"), count: 1
        assert_select '[data-layout="admin"] nav[aria-label=?] li.menu-title', I18n.t("navigation.admin_menu"), text: I18n.t("navigation.admin"), count: 1
        assert_select '[data-layout="admin"] nav[aria-label=?]', I18n.t("navigation.account_menu"), count: 0
        assert_select '[data-layout="admin"] a.menu-active[href=?]', admin_users_path, text: I18n.t("navigation.users"), count: 1
        assert_select 'header li.menu-title', text: I18n.t("navigation.admin"), count: 1
        assert_select 'header a[href=?]', account_path, count: 0
        assert_select "table.table.table-sm.table-pin-rows"
        assert_select ".badge", text: I18n.t("admin.users.admin"), minimum: 1
        assert_select ".join", count: 0
      end


      test "paginates the admin list" do
        create_additional_users(25)
        sign_in_as(@admin, #{devise ? "nil" : "@admin_key"})

        get admin_users_url

        assert_response :success
        assert_select 'nav[aria-label=?] .join', I18n.t("admin.users.pagination"), count: 1
        assert_select '.join .join-item', count: 3
      end
    end
  RUBY

  create_file "test/controllers/admin/user_roles_controller_test.rb", <<~RUBY, force: true
    require "test_helper"

    class Admin::UserRolesControllerTest < ActionDispatch::IntegrationTest
    #{controller_test_support}
      test "allows an admin to grant and revoke another users role" do
        sign_in_as(@admin, #{devise ? "nil" : "@admin_key"})

        assert_difference("UserRole.count", 1) do
          post admin_user_roles_url(@regular), params: { role: "admin" }
        end
        assert_redirected_to admin_users_url

        assert_difference("UserRole.count", -1) do
          delete admin_user_role_url(@regular, "admin")
        end
        assert_redirected_to admin_users_url
      end

      test "denies role changes by regular users" do
        sign_in_as(@regular, #{devise ? "nil" : "@regular_key"})

        assert_no_difference("UserRole.count") do
          post admin_user_roles_url(@regular), params: { role: "admin" }
        end
        assert_response :forbidden
      end

      test "refuses self revocation" do
        sign_in_as(@admin, #{devise ? "nil" : "@admin_key"})

        assert_no_difference("UserRole.count") do
          delete admin_user_role_url(@admin, "admin")
        end
        assert_redirected_to admin_users_url
        assert @admin.reload.has_role?(:admin)
      end

      test "rejects unknown roles" do
        sign_in_as(@admin, #{devise ? "nil" : "@admin_key"})

        post admin_user_roles_url(@regular), params: { role: "unknown" }

        assert_response :unprocessable_content
      end


    #{account_deletion_test.lines.map { |line| "  #{line}" }.join}end
  RUBY

  create_file "test/tasks/roles_task_test.rb", <<~RUBY, force: true
    require "test_helper"
    require "fileutils"
    require "rake"

    class RolesTaskTest < ActiveSupport::TestCase
      setup do
        Rails.application.load_tasks if Rake::Task.tasks.empty?
        @task = Rake::Task["roles:grant_admin"]
      end

      test "grants admin idempotently to an existing user" do
        user = users(:two)
        identifier = user.#{identifier_attribute}

        assert_difference("UserRole.count", 1) { invoke(identifier) }
        assert_no_difference("UserRole.count") { invoke(identifier) }
        assert user.reload.has_role?(:admin)
      end

      test "does not create an unknown user" do
        assert_no_difference("User.count") do
          assert_raises(ActiveRecord::RecordNotFound) { invoke("missing-#{identifier_attribute}") }
        end
      end

      test "loads local seeds only when the ignored file exists" do
        local_seeds = Rails.root.join("db/seeds.local.rb")
        FileUtils.rm_f(local_seeds)

        load Rails.root.join("db/seeds.rb")
        assert_nil ENV["ROLE_LOCAL_SEED_LOADED"]

        File.write(local_seeds, 'ENV["ROLE_LOCAL_SEED_LOADED"] = "yes"\n')
        load Rails.root.join("db/seeds.rb")
        assert_equal "yes", ENV["ROLE_LOCAL_SEED_LOADED"]
      ensure
        FileUtils.rm_f(local_seeds) if local_seeds
        ENV.delete("ROLE_LOCAL_SEED_LOADED")
      end

      private
        def invoke(identifier)
          @task.reenable
          capture_io { @task.invoke(identifier) }
        end
    end
  RUBY

  if devise
    configure_devise_registration_route
    create_file "app/controllers/users/registrations_controller.rb", <<~RUBY, force: true
      module Users
        class RegistrationsController < Devise::RegistrationsController
          def destroy
            if resource.last_admin?
              redirect_to edit_user_registration_path, alert: I18n.t("accounts.destroy.last_admin"), status: :see_other
              return
            end

            super
          end
        end
      end
    RUBY
  end
end

def configure_content_management
  devise = VALUES.fetch("account_authentication") == "devise"
  page_title_keys = {
    "about" => "content_management.pages.about",
    "corp" => "content_management.pages.corp",
    "manual" => "content_management.pages.manual",
    "terms" => "content_management.pages.terms",
    "privacy" => "content_management.pages.privacy",
    "transaction-law" => "content_management.pages.transaction_law"
  }.freeze
  page_title_entries = page_title_keys.map { |slug, key| "    #{slug.inspect} => #{key.inspect}" }.join(",\n")
  public_page_access = devise ? "" : "  allow_unauthenticated_access only: :show\n\n"
  public_faq_access = devise ? "" : "  allow_unauthenticated_access only: :index\n\n"

  generate "model", "Page", "slug:string", "title:string"
  generate "model", "Faq", "question:string", "position:integer", "published:boolean"
  generate "model", "FooterSetting", "key:string", "x_url:string", "github_url:string"

  page_migration = Dir.glob("db/migrate/*_create_pages.rb")
  faq_migration = Dir.glob("db/migrate/*_create_faqs.rb")
  footer_setting_migration = Dir.glob("db/migrate/*_create_footer_settings.rb")
  raise "CreatePages migrationが一意ではありません" unless page_migration.one?
  raise "CreateFaqs migrationが一意ではありません" unless faq_migration.one?
  raise "CreateFooterSettings migrationが一意ではありません" unless footer_setting_migration.one?

  create_file page_migration.first, <<~RUBY, force: true
    class CreatePages < ActiveRecord::Migration[8.1]
      def change
        create_table :pages do |t|
          t.string :slug, null: false
          t.string :title, null: false
          t.timestamps
        end

        add_index :pages, :slug, unique: true
        add_check_constraint :pages,
          "slug IN ('about', 'corp', 'manual', 'terms', 'privacy', 'transaction-law')",
          name: "pages_slug_check"
      end
    end
  RUBY

  create_file faq_migration.first, <<~RUBY, force: true
    class CreateFaqs < ActiveRecord::Migration[8.1]
      def change
        create_table :faqs do |t|
          t.string :question, null: false
          t.integer :position, null: false, default: 0
          t.boolean :published, null: false, default: false
          t.timestamps
        end

        add_index :faqs, [:published, :position, :id]
        add_check_constraint :faqs, "position >= 0", name: "faqs_position_check"
      end
    end
  RUBY

  create_file footer_setting_migration.first, <<~RUBY, force: true
    class CreateFooterSettings < ActiveRecord::Migration[8.1]
      def change
        create_table :footer_settings do |t|
          t.string :key, null: false, default: "default"
          t.string :x_url
          t.string :github_url
          t.timestamps
        end

        add_index :footer_settings, :key, unique: true
        add_check_constraint :footer_settings, "key = 'default'", name: "footer_settings_key_check"
      end
    end
  RUBY

  create_file "app/models/page.rb", <<~RUBY, force: true
    class Page < ApplicationRecord
      TITLE_KEYS = {
    #{page_title_entries}
      }.freeze
      TITLES = TITLE_KEYS.transform_values do |key|
        I18n.t(
          key,
          locale: I18n.default_locale,
          app_name: Rails.configuration.x.application_identity.app_name
        )
      end.freeze

      has_rich_text :content, store_if_blank: false

      validates :slug, presence: true, inclusion: { in: TITLES.keys }, uniqueness: true
      validates :title, presence: true
      validate :title_matches_slug

      def to_param
        slug
      end

      private
        def title_matches_slug
          return unless TITLES.key?(slug)
          return if title == TITLES.fetch(slug)

          errors.add(:title, :invalid)
        end
    end
  RUBY

  create_file "app/models/faq.rb", <<~RUBY, force: true
    class Faq < ApplicationRecord
      has_rich_text :answer

      scope :published_in_display_order, -> {
        where(published: true).order(:position, :id).with_rich_text_answer_and_embeds
      }

      validates :question, presence: true
      validates :answer, presence: true
      validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    end
  RUBY

  create_file "app/models/footer_setting.rb", <<~RUBY, force: true
    require "uri"

    class FooterSetting < ApplicationRecord
      DEFAULT_KEY = "default"
      URL_ATTRIBUTES = %i[x_url github_url].freeze

      normalizes :x_url, :github_url, with: ->(value) { value&.strip.presence }

      validates :key, inclusion: { in: [DEFAULT_KEY] }, uniqueness: true
      validate :external_urls_are_https

      def self.default_record
        find_by!(key: DEFAULT_KEY)
      end

      private
        def external_urls_are_https
          URL_ATTRIBUTES.each do |attribute|
            value = public_send(attribute)
            next if value.blank?

            uri = URI.parse(value)
            next if uri.is_a?(URI::HTTPS) && uri.host.present? && uri.userinfo.nil?

            errors.add(attribute, :invalid_https_url)
          rescue URI::InvalidURIError
            errors.add(attribute, :invalid_https_url)
          end
        end
    end
  RUBY

  create_file "app/policies/page_policy.rb", <<~RUBY, force: true
    class PagePolicy < ApplicationPolicy
      def index?
        admin?
      end

      def update?
        admin?
      end
    end
  RUBY

  create_file "app/policies/faq_policy.rb", <<~RUBY, force: true
    class FaqPolicy < ApplicationPolicy
      def index?
        admin?
      end

      def create?
        admin?
      end

      def update?
        admin?
      end

      def destroy?
        admin?
      end
    end
  RUBY

  create_file "app/policies/footer_setting_policy.rb", <<~RUBY, force: true
    class FooterSettingPolicy < ApplicationPolicy
      def edit?
        admin?
      end

      def update?
        admin?
      end
    end
  RUBY

  inject_into_class "app/controllers/application_controller.rb", "ApplicationController", <<~RUBY
      helper_method :footer_setting

      private
        def footer_setting
          @footer_setting ||= FooterSetting.default_record
        end

  RUBY

  create_file "app/controllers/pages_controller.rb", <<~RUBY, force: true
    class PagesController < ApplicationController
      TEMPLATES = {
        "about" => "pages/about",
        "corp" => "pages/corp",
        "manual" => "pages/manual",
        "terms" => "pages/terms",
        "privacy" => "pages/privacy",
        "transaction-law" => "pages/transaction-law"
      }.freeze

    #{public_page_access}  def show
        @page = Page.find_by!(slug: params.expect(:slug))
        render template: TEMPLATES.fetch(@page.slug)
      end
    end
  RUBY

  create_file "app/controllers/faqs_controller.rb", <<~RUBY, force: true
    class FaqsController < ApplicationController
    #{public_faq_access}  def index
        @faqs = Faq.published_in_display_order
      end
    end
  RUBY

  create_file "app/controllers/admin/pages_controller.rb", <<~RUBY, force: true
    module Admin
      class PagesController < BaseController
        before_action :set_page, only: %i[edit update]

        def index
          authorize! Page, to: :index?
          @pages = Page.order(:id)
        end

        def edit
          authorize! @page, to: :update?
        end

        def update
          authorize! @page, to: :update?
          if @page.update(page_params)
            redirect_to admin_pages_path,
              notice: I18n.t("admin.pages.update.notice"),
              status: :see_other
          else
            render :edit, status: :unprocessable_content
          end
        end

        private
          def set_page
            @page = Page.find_by!(slug: params.expect(:slug))
          end

          def page_params
            params.expect(page: [:content])
          end
      end
    end
  RUBY

  create_file "app/controllers/admin/faqs_controller.rb", <<~RUBY, force: true
    module Admin
      class FaqsController < BaseController
        before_action :set_faq, only: %i[edit update destroy]

        def index
          authorize! Faq, to: :index?
          @faqs = Faq.order(:position, :id).with_rich_text_answer
        end

        def new
          @faq = Faq.new
          authorize! @faq, to: :create?
        end

        def create
          @faq = Faq.new(faq_params)
          authorize! @faq, to: :create?
          if @faq.save
            redirect_to admin_faqs_path,
              notice: I18n.t("admin.faqs.create.notice"),
              status: :see_other
          else
            render :new, status: :unprocessable_content
          end
        end

        def edit
          authorize! @faq, to: :update?
        end

        def update
          authorize! @faq, to: :update?
          if @faq.update(faq_params)
            redirect_to admin_faqs_path,
              notice: I18n.t("admin.faqs.update.notice"),
              status: :see_other
          else
            render :edit, status: :unprocessable_content
          end
        end

        def destroy
          authorize! @faq, to: :destroy?
          @faq.destroy!
          redirect_to admin_faqs_path,
            notice: I18n.t("admin.faqs.destroy.notice"),
            status: :see_other
        end

        private
          def set_faq
            @faq = Faq.find(params.expect(:id))
          end

          def faq_params
            params.expect(faq: [:question, :answer, :position, :published])
          end
      end
    end
  RUBY

  create_file "app/controllers/admin/footer_settings_controller.rb", <<~RUBY, force: true
    module Admin
      class FooterSettingsController < BaseController
        before_action :set_footer_setting

        def edit
          authorize! @footer_setting, to: :edit?
        end

        def update
          authorize! @footer_setting, to: :update?
          if @footer_setting.update(footer_setting_params)
            redirect_to edit_admin_footer_setting_path,
              notice: I18n.t("admin.footer_settings.update.notice"),
              status: :see_other
          else
            render :edit, status: :unprocessable_content
          end
        end

        private
          def set_footer_setting
            @footer_setting = FooterSetting.default_record
          end

          def footer_setting_params
            params.expect(footer_setting: [:x_url, :github_url])
          end
      end
    end
  RUBY

  route <<~RUBY
    get "/about", to: "pages#show", defaults: { slug: "about" }, as: :about
    get "/corp", to: "pages#show", defaults: { slug: "corp" }, as: :corp
    get "/manual", to: "pages#show", defaults: { slug: "manual" }, as: :manual
    get "/terms", to: "pages#show", defaults: { slug: "terms" }, as: :terms
    get "/privacy", to: "pages#show", defaults: { slug: "privacy" }, as: :privacy
    get "/transaction-law", to: "pages#show", defaults: { slug: "transaction-law" }, as: :transaction_law
    get "/faq", to: "faqs#index", as: :faq

    namespace :admin do
      resources :pages, param: :slug, only: %i[index edit update]
      resources :faqs, except: :show
      resource :footer_setting, path: "footer-setting", only: %i[edit update]
    end
  RUBY

  append_to_file "db/seeds.rb", <<~RUBY

    Page::TITLES.each do |slug, title|
      page = Page.find_or_initialize_by(slug: slug)
      page.title = title
      page.save!
    end
    FooterSetting.find_or_create_by!(key: FooterSetting::DEFAULT_KEY)
  RUBY
  create_locale_pair(
    "content_management",
    ja: {
      "content_management" => {
        "pages" => { "about" => "%{app_name}について", "corp" => "運営会社", "manual" => "使い方", "terms" => "利用規約", "privacy" => "プライバシーポリシー", "transaction_law" => "特商法表記" },
        "sections" => { "about" => "概要", "company" => "会社情報", "guides" => "ガイド", "legal" => "法的情報" },
        "faqs" => { "title" => "よくある質問", "empty" => "現在、公開中のよくある質問はありません。" },
        "admin" => {
          "eyebrow" => "管理画面",
          "pages" => { "title" => "固定ページ管理", "page" => "ページ", "url" => "URL", "actions" => "操作", "body" => "本文", "edit_description" => "固定ページの本文を編集します。" },
          "faqs" => { "title" => "FAQ管理", "add" => "FAQを追加", "edit" => "FAQを編集", "question" => "質問", "answer" => "回答", "position" => "表示順", "publication" => "公開設定", "publish" => "公開する", "status" => "状態", "published" => "公開", "unpublished" => "非公開", "empty" => "FAQはまだ登録されていません。", "confirm" => "FAQを削除しますか？" },
          "footer_settings" => { "title" => "外部リンク設定", "description" => "空欄のリンクはfooterに表示されません。" }
        }
      },
      "admin" => {
        "pages" => { "update" => { "notice" => "固定ページを更新しました" } },
        "faqs" => { "create" => { "notice" => "FAQを作成しました" }, "update" => { "notice" => "FAQを更新しました" }, "destroy" => { "notice" => "FAQを削除しました" } },
        "footer_settings" => { "update" => { "notice" => "外部リンクを更新しました" } }
      },
      "errors" => { "messages" => { "invalid_https_url" => "はuserinfoを含まないHTTPS URLを指定してください" } }
    },
    en: {
      "content_management" => {
        "pages" => { "about" => "About %{app_name}", "corp" => "Company", "manual" => "Guides", "terms" => "Terms", "privacy" => "Privacy policy", "transaction_law" => "Commercial transactions disclosure" },
        "sections" => { "about" => "About", "company" => "Company", "guides" => "Guides", "legal" => "Legal" },
        "faqs" => { "title" => "Frequently asked questions", "empty" => "There are no published frequently asked questions." },
        "admin" => {
          "eyebrow" => "Administration",
          "pages" => { "title" => "Manage pages", "page" => "Page", "url" => "URL", "actions" => "Actions", "body" => "Body", "edit_description" => "Edit the body of this page." },
          "faqs" => { "title" => "Manage FAQs", "add" => "Add FAQ", "edit" => "Edit FAQ", "question" => "Question", "answer" => "Answer", "position" => "Position", "publication" => "Publication", "publish" => "Publish", "status" => "Status", "published" => "Published", "unpublished" => "Unpublished", "empty" => "No FAQs have been created.", "confirm" => "Delete this FAQ?" },
          "footer_settings" => { "title" => "External links", "description" => "Blank links are not displayed in the footer." }
        }
      },
      "admin" => {
        "pages" => { "update" => { "notice" => "The page was updated." } },
        "faqs" => { "create" => { "notice" => "The FAQ was created." }, "update" => { "notice" => "The FAQ was updated." }, "destroy" => { "notice" => "The FAQ was deleted." } },
        "footer_settings" => { "update" => { "notice" => "The external links were updated." } }
      },
      "errors" => { "messages" => { "invalid_https_url" => "must be an HTTPS URL without userinfo" } }
    }
  )

  create_file "test/fixtures/pages.yml", <<~YAML, force: true
    about:
      slug: about
      title: <%= Page::TITLES.fetch("about") %>
    corp:
      slug: corp
      title: <%= Page::TITLES.fetch("corp") %>
    manual:
      slug: manual
      title: <%= Page::TITLES.fetch("manual") %>
    terms:
      slug: terms
      title: <%= Page::TITLES.fetch("terms") %>
    privacy:
      slug: privacy
      title: <%= Page::TITLES.fetch("privacy") %>
    transaction_law:
      slug: transaction-law
      title: <%= Page::TITLES.fetch("transaction-law") %>
  YAML
  create_file "test/fixtures/faqs.yml", "# FAQs are created explicitly by tests.\n", force: true
  create_file "test/fixtures/footer_settings.yml", <<~YAML, force: true
    default:
      key: default
  YAML

  create_file "app/views/pages/_page.html.erb", <<~ERB, force: true
    <% content_for :title, @page.title %>
    <div class="mx-auto w-full max-w-[820px] space-y-6 px-5 py-10 md:py-14">
      <header>
        <p class="text-sm font-semibold text-primary"><%= section %></p>
        <h1 class="mt-1 text-2xl font-bold leading-[1.5]"><%= @page.title %></h1>
      </header>
      <section class="card card-border border-base-300 bg-base-100 shadow-none">
        <div class="card-body"><%= @page.content %></div>
      </section>
    </div>
  ERB
  create_file "app/views/pages/about.html.erb", "<%= render \"pages/page\", section: t(\"content_management.sections.about\") %>\n", force: true
  create_file "app/views/pages/corp.html.erb", "<%= render \"pages/page\", section: t(\"content_management.sections.company\") %>\n", force: true
  create_file "app/views/pages/manual.html.erb", "<%= render \"pages/page\", section: t(\"content_management.sections.guides\") %>\n", force: true
  create_file "app/views/pages/terms.html.erb", "<%= render \"pages/page\", section: t(\"content_management.sections.legal\") %>\n", force: true
  create_file "app/views/pages/privacy.html.erb", "<%= render \"pages/page\", section: t(\"content_management.sections.legal\") %>\n", force: true
  create_file "app/views/pages/transaction-law.html.erb", "<%= render \"pages/page\", section: t(\"content_management.sections.legal\") %>\n", force: true

  create_file "app/views/faqs/index.html.erb", <<~ERB, force: true
    <% content_for :title, t("content_management.faqs.title") %>
    <div class="mx-auto w-full max-w-[820px] space-y-6 px-5 py-10 md:py-14">
      <header>
        <p class="text-sm font-semibold text-primary"><%= t("content_management.sections.guides") %></p>
        <h1 class="mt-1 text-2xl font-bold leading-[1.5]"><%= t("content_management.faqs.title") %></h1>
      </header>
      <% if @faqs.any? %>
        <div class="space-y-3">
          <% @faqs.each do |faq| %>
            <details class="collapse collapse-arrow border border-base-300 bg-base-100">
              <summary class="collapse-title font-semibold"><%= faq.question %></summary>
              <div class="collapse-content"><%= faq.answer %></div>
            </details>
          <% end %>
        </div>
      <% else %>
        <div class="alert"><span><%= t("content_management.faqs.empty") %></span></div>
      <% end %>
    </div>
  ERB

  create_file "app/views/admin/pages/index.html.erb", <<~ERB, force: true
    <% content_for :title, t("content_management.admin.pages.title") %>
    <div class="space-y-6">
      <header>
        <p class="text-sm font-semibold text-primary"><%= t("content_management.admin.eyebrow") %></p>
        <h1 class="mt-1 text-2xl font-bold leading-[1.5]"><%= t("content_management.admin.pages.title") %></h1>
      </header>
      <section class="card card-border border-base-300 bg-base-100 shadow-none">
        <div class="card-body">
          <div class="overflow-x-auto">
            <table class="table">
              <thead><tr><th scope="col"><%= t("content_management.admin.pages.page") %></th><th scope="col"><%= t("content_management.admin.pages.url") %></th><th scope="col"><span class="sr-only"><%= t("content_management.admin.pages.actions") %></span></th></tr></thead>
              <tbody>
                <% @pages.each do |page| %>
                  <tr>
                    <td><%= page.title %></td>
                    <td><code>/<%= page.slug %></code></td>
                    <td class="text-right"><%= link_to t("common.edit"), edit_admin_page_path(page), class: "btn btn-rapid" %></td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        </div>
      </section>
    </div>
  ERB

  create_file "app/views/admin/pages/edit.html.erb", <<~ERB, force: true
    <% content_for :title, @page.title %>
    <div class="max-w-[820px] space-y-6">
      <header>
        <p class="text-sm font-semibold text-primary"><%= t("content_management.admin.eyebrow") %></p>
        <h1 class="mt-1 text-2xl font-bold leading-[1.5]"><%= @page.title %></h1>
        <p class="mt-2 text-sm text-neutral"><%= t("content_management.admin.pages.edit_description") %></p>
      </header>
      <section class="card card-border border-base-300 bg-base-100 shadow-none">
        <div class="card-body">
          <%= form_with model: [:admin, @page], class: "space-y-5" do |form| %>
            <fieldset class="fieldset">
              <legend class="fieldset-legend"><%= form.label :content, t("content_management.admin.pages.body") %></legend>
              <%= form.rich_text_area :content %>
            </fieldset>
            <div class="card-actions justify-end">
              <%= link_to t("common.back"), admin_pages_path, class: "btn btn-ghost btn-rapid" %>
              <%= form.submit t("common.update"), class: "btn btn-rapid" %>
            </div>
          <% end %>
        </div>
      </section>
    </div>
  ERB

  create_file "app/views/admin/faqs/_form.html.erb", <<~ERB, force: true
    <%= form_with model: [:admin, faq], class: "space-y-5" do |form| %>
      <% if faq.errors.any? %>
        <div class="alert alert-error" role="alert">
          <ul><% faq.errors.full_messages.each do |message| %><li><%= message %></li><% end %></ul>
        </div>
      <% end %>
      <fieldset class="fieldset">
        <legend class="fieldset-legend"><%= form.label :question, t("content_management.admin.faqs.question") %></legend>
        <%= form.text_field :question, class: "input input-rapid w-full", required: true %>
      </fieldset>
      <fieldset class="fieldset">
        <legend class="fieldset-legend"><%= form.label :answer, t("content_management.admin.faqs.answer") %></legend>
        <%= form.rich_text_area :answer %>
      </fieldset>
      <fieldset class="fieldset">
        <legend class="fieldset-legend"><%= form.label :position, t("content_management.admin.faqs.position") %></legend>
        <%= form.number_field :position, class: "input input-rapid w-full", min: 0, required: true %>
      </fieldset>
      <fieldset class="fieldset">
        <legend class="fieldset-legend"><%= t("content_management.admin.faqs.publication") %></legend>
        <label class="label cursor-pointer justify-start gap-3">
          <%= form.checkbox :published, class: "checkbox" %>
          <span><%= t("content_management.admin.faqs.publish") %></span>
        </label>
      </fieldset>
      <div class="card-actions justify-end">
        <%= link_to t("common.back"), admin_faqs_path, class: "btn btn-ghost btn-rapid" %>
        <%= form.submit(faq.persisted? ? t("common.update") : t("common.create"), class: "btn btn-rapid") %>
      </div>
    <% end %>
  ERB

  create_file "app/views/admin/faqs/index.html.erb", <<~ERB, force: true
    <% content_for :title, t("content_management.admin.faqs.title") %>
    <div class="space-y-6">
      <header class="flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
        <div>
          <p class="text-sm font-semibold text-primary"><%= t("content_management.admin.eyebrow") %></p>
          <h1 class="mt-1 text-2xl font-bold leading-[1.5]"><%= t("content_management.admin.faqs.title") %></h1>
        </div>
        <%= link_to t("content_management.admin.faqs.add"), new_admin_faq_path, class: "btn btn-rapid" %>
      </header>
      <section class="card card-border border-base-300 bg-base-100 shadow-none">
        <div class="card-body">
          <% if @faqs.any? %>
            <div class="overflow-x-auto">
              <table class="table">
                <thead><tr><th scope="col"><%= t("content_management.admin.faqs.position") %></th><th scope="col"><%= t("content_management.admin.faqs.question") %></th><th scope="col"><%= t("content_management.admin.faqs.status") %></th><th scope="col"><span class="sr-only"><%= t("content_management.admin.pages.actions") %></span></th></tr></thead>
                <tbody>
                  <% @faqs.each do |faq| %>
                    <tr>
                      <td><%= faq.position %></td>
                      <td><%= faq.question %></td>
                      <td><span class="badge"><%= faq.published? ? t("content_management.admin.faqs.published") : t("content_management.admin.faqs.unpublished") %></span></td>
                      <td>
                        <div class="flex justify-end gap-2">
                          <%= link_to t("common.edit"), edit_admin_faq_path(faq), class: "btn btn-rapid" %>
                          <%= button_to t("common.delete"), admin_faq_path(faq), method: :delete, class: "btn btn-outline btn-error btn-rapid", data: { turbo_confirm: t("content_management.admin.faqs.confirm") } %>
                        </div>
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>
          <% else %>
            <div class="alert"><span><%= t("content_management.admin.faqs.empty") %></span></div>
          <% end %>
        </div>
      </section>
    </div>
  ERB

  create_file "app/views/admin/faqs/new.html.erb", <<~ERB, force: true
    <% content_for :title, t("content_management.admin.faqs.add") %>
    <div class="max-w-[820px] space-y-6">
      <header><p class="text-sm font-semibold text-primary"><%= t("content_management.admin.eyebrow") %></p><h1 class="mt-1 text-2xl font-bold leading-[1.5]"><%= t("content_management.admin.faqs.add") %></h1></header>
      <section class="card card-border border-base-300 bg-base-100 shadow-none"><div class="card-body"><%= render "form", faq: @faq %></div></section>
    </div>
  ERB

  create_file "app/views/admin/faqs/edit.html.erb", <<~ERB, force: true
    <% content_for :title, t("content_management.admin.faqs.edit") %>
    <div class="max-w-[820px] space-y-6">
      <header><p class="text-sm font-semibold text-primary"><%= t("content_management.admin.eyebrow") %></p><h1 class="mt-1 text-2xl font-bold leading-[1.5]"><%= t("content_management.admin.faqs.edit") %></h1></header>
      <section class="card card-border border-base-300 bg-base-100 shadow-none"><div class="card-body"><%= render "form", faq: @faq %></div></section>
    </div>
  ERB

  create_file "app/views/admin/footer_settings/edit.html.erb", <<~ERB, force: true
    <% content_for :title, t("content_management.admin.footer_settings.title") %>
    <div class="max-w-[820px] space-y-6">
      <header>
        <p class="text-sm font-semibold text-primary"><%= t("content_management.admin.eyebrow") %></p>
        <h1 class="mt-1 text-2xl font-bold leading-[1.5]"><%= t("content_management.admin.footer_settings.title") %></h1>
        <p class="mt-2 text-sm text-neutral"><%= t("content_management.admin.footer_settings.description") %></p>
      </header>
      <section class="card card-border border-base-300 bg-base-100 shadow-none">
        <div class="card-body">
          <%= form_with model: [:admin, @footer_setting], url: admin_footer_setting_path, class: "space-y-5" do |form| %>
            <% if @footer_setting.errors.any? %>
              <div class="alert alert-error" role="alert">
                <ul><% @footer_setting.errors.full_messages.each do |message| %><li><%= message %></li><% end %></ul>
              </div>
            <% end %>
            <fieldset class="fieldset">
              <legend class="fieldset-legend"><%= form.label :x_url, "X(Twitter)" %></legend>
              <%= form.url_field :x_url, class: "input input-rapid w-full", placeholder: "https://example.com/x-account" %>
            </fieldset>
            <fieldset class="fieldset">
              <legend class="fieldset-legend"><%= form.label :github_url, "GitHub" %></legend>
              <%= form.url_field :github_url, class: "input input-rapid w-full", placeholder: "https://example.com/github-account" %>
            </fieldset>
            <div class="card-actions justify-end"><%= form.submit t("common.update"), class: "btn btn-rapid" %></div>
          <% end %>
        </div>
      </section>
    </div>
  ERB

  content_authentication_support = if devise
    <<~RUBY
      module ContentManagementAuthenticationTestSupport
        extend ActiveSupport::Concern

        included do
          include Devise::Test::IntegrationHelpers
        end

        private
          def setup_content_management_users
            @admin = User.create!(
              email: "content-admin@example.com",
              password: "password123",
              password_confirmation: "password123"
            )
            @regular = User.create!(
              email: "content-regular@example.com",
              password: "password123",
              password_confirmation: "password123"
            )
            @admin.grant_role!(:admin)
          end

          def sign_in_content_user(user, _key = nil)
            sign_in user
          end
      end
    RUBY
  else
    <<~RUBY
      require "eth"

      module ContentManagementAuthenticationTestSupport
        private
          def setup_content_management_users
            @admin, @admin_key = create_content_wallet_user
            @regular, @regular_key = create_content_wallet_user
            @admin.grant_role!(:admin)
          end

          def create_content_wallet_user
            key = Eth::Key.new
            [User.create!(wallet_address: key.address.to_s), key]
          end

          def sign_in_content_user(_user, key)
            get session_nonce_url, headers: siwe_test_headers(key)
            nonce = response.parsed_body.fetch("nonce")
            message = Siwe::Message.new(
              domain: "www.example.com",
              address: key.address.to_s,
              uri: "http://www.example.com",
              chain_id: 1,
              nonce: nonce,
              issued_at: Time.current.iso8601,
              statement: Rails.configuration.x.application_identity.siwe_statement
            ).prepare_message
            post session_url, params: { message: message, signature: key.personal_sign(message) },
              headers: siwe_test_headers(key), as: :json
            assert_response :success
          end
      end
    RUBY
  end
  create_file "test/support/content_management_authentication.rb", content_authentication_support, force: true

  create_file "test/models/page_test.rb", <<~RUBY, force: true
    require "test_helper"

    class PageTest < ActiveSupport::TestCase
      test "accepts only fixed slugs and matching titles" do
        page = pages(:about)
        page.assign_attributes(slug: "unknown", title: "Unknown")
        assert_not page.valid?

        page.slug = "about"
        assert_not page.valid?

        page.title = Page::TITLES.fetch("about")
        assert page.valid?
      end

      test "database rejects unknown and duplicate slugs" do
        now = Time.current

        # These writes intentionally bypass model validations to exercise database constraints.
        # rubocop:disable Rails/SkipsModelValidations
        assert_raises(ActiveRecord::StatementInvalid) do
          Page.insert_all!([{ slug: "unknown", title: "Unknown", created_at: now, updated_at: now }])
        end
        assert_raises(ActiveRecord::StatementInvalid) do
          Page.insert_all!([{ slug: "about", title: Page::TITLES.fetch("about"), created_at: now, updated_at: now }])
        end
        # rubocop:enable Rails/SkipsModelValidations
      end

      test "seeds fixed pages and footer setting idempotently" do
        load Rails.root.join("db/seeds.rb")

        assert_equal Page::TITLES, Page.order(:id).to_h { |page| [page.slug, page.title] }
        assert_equal FooterSetting::DEFAULT_KEY, FooterSetting.default_record.key
        assert_no_difference(["Page.count", "FooterSetting.count"]) { load Rails.root.join("db/seeds.rb") }
      end
    end
  RUBY

  create_file "test/models/faq_test.rb", <<~RUBY, force: true
    require "test_helper"

    class FaqTest < ActiveSupport::TestCase
      test "requires question answer and nonnegative position" do
        faq = Faq.new(position: -1)

        assert_not faq.valid?
        faq.assign_attributes(question: "質問", answer: "回答", position: 0)
        assert faq.valid?
      end

      test "returns only published FAQs in display order" do
        later = Faq.create!(question: "後", answer: "後の回答", position: 20, published: true)
        hidden = Faq.create!(question: "非公開", answer: "非公開の回答", position: 0, published: false)
        earlier = Faq.create!(question: "前", answer: "前の回答", position: 10, published: true)

        assert_equal [earlier, later], Faq.published_in_display_order.to_a
        assert_not_includes Faq.published_in_display_order, hidden
      end

      test "database rejects negative positions" do
        now = Time.current

        # This write intentionally bypasses model validations to exercise the database constraint.
        # rubocop:disable Rails/SkipsModelValidations
        assert_raises(ActiveRecord::StatementInvalid) do
          Faq.insert_all!([{ question: "質問", position: -1, published: false, created_at: now, updated_at: now }])
        end
        # rubocop:enable Rails/SkipsModelValidations
      end
    end
  RUBY

  create_file "test/models/footer_setting_test.rb", <<~RUBY, force: true
    require "test_helper"

    class FooterSettingTest < ActiveSupport::TestCase
      test "accepts blank or arbitrary HTTPS URLs and normalizes whitespace" do
        setting = footer_settings(:default)
        setting.update!(x_url: "  https://social.example/x  ", github_url: "")

        assert_equal "https://social.example/x", setting.x_url
        assert_nil setting.github_url
      end

      test "rejects HTTP hostless invalid and userinfo URLs" do
        setting = footer_settings(:default)

        ["http://example.com/x", "https:///missing-host", "not a url", "https://user@example.com/path"].each do |url|
          setting.x_url = url
          assert_not setting.valid?, url
        end
      end

      test "database allows only the singleton key" do
        now = Time.current

        # These writes intentionally bypass model validations to exercise database constraints.
        # rubocop:disable Rails/SkipsModelValidations
        assert_raises(ActiveRecord::StatementInvalid) do
          FooterSetting.insert_all!([{ key: "other", created_at: now, updated_at: now }])
        end
        assert_raises(ActiveRecord::StatementInvalid) do
          FooterSetting.insert_all!([{ key: "default", created_at: now, updated_at: now }])
        end
        # rubocop:enable Rails/SkipsModelValidations
      end
    end
  RUBY

  create_file "test/policies/content_management_policy_test.rb", <<~RUBY, force: true
    require "test_helper"

    class ContentManagementPolicyTest < ActiveSupport::TestCase
      test "allows admins and denies regular users" do
        admin = users(:one)
        regular = users(:two)
        admin.grant_role!(:admin)

        assert PagePolicy.new(Page, user: admin).apply(:index?)
        assert PagePolicy.new(pages(:about), user: admin).apply(:update?)
        assert FaqPolicy.new(Faq, user: admin).apply(:index?)
        assert FaqPolicy.new(Faq.new, user: admin).apply(:create?)
        assert FooterSettingPolicy.new(footer_settings(:default), user: admin).apply(:edit?)

        assert_not PagePolicy.new(Page, user: regular).apply(:index?)
        assert_not PagePolicy.new(pages(:about), user: regular).apply(:update?)
        assert_not FaqPolicy.new(Faq.new, user: regular).apply(:create?)
        assert_not FooterSettingPolicy.new(footer_settings(:default), user: regular).apply(:update?)
      end
    end
  RUBY

  create_file "test/controllers/pages_controller_test.rb", <<~RUBY, force: true
    require "test_helper"

    class PagesControllerTest < ActionDispatch::IntegrationTest
      test "renders every fixed public page through the explicit template map" do
        {
          about_url => ["about", Page::TITLES.fetch("about")],
          corp_url => ["corp", Page::TITLES.fetch("corp")],
          manual_url => ["manual", Page::TITLES.fetch("manual")],
          terms_url => ["terms", Page::TITLES.fetch("terms")],
          privacy_url => ["privacy", Page::TITLES.fetch("privacy")],
          transaction_law_url => ["transaction-law", Page::TITLES.fetch("transaction-law")]
        }.each do |url, (slug, title)|
          get url

          assert_response :success
          assert_select "h1", text: title, count: 1
          assert_equal "pages/\#{slug}", PagesController::TEMPLATES.fetch(slug)
        end
      end

      test "renders Action Text content with Lexxy styles" do
        pages(:about).update!(content: "<p>管理された本文</p>")

        get about_url

        assert_response :success
        assert_select ".lexxy-content", text: "管理された本文", count: 1
      end

      test "keeps Action Text image attachments separate from the avatar policy" do
        page = pages(:about)
        blob = ImageTestFixture.png_blob
        page.update!(content: %(<action-text-attachment sgid="\#{blob.attachable_sgid}"></action-text-attachment>))

        get about_url

        assert_response :success
        assert_select ".lexxy-content figure.attachment img[src]", count: 1
        source = css_select(".lexxy-content figure.attachment img[src]").first["src"]
        if Rails.configuration.active_storage.resolve_model_to_route == :imgproxy_active_storage
          assert source.start_with?("http://localhost:8080/")
          assert_not_includes source, "/unsafe/"
        else
          assert_includes source, "/rails/active_storage/representations/"
        end
        assert_equal ImageTestFixture::PNG, blob.download
        rich_text = page.reload.rich_text_content
        assert_equal [blob], rich_text.embeds.blobs

        page.update!(content: "")
        assert_not ActiveStorage::Attachment.exists?(record: rich_text, blob:)
      ensure
        blob&.purge if blob&.persisted?
      end

      test "hides unset external links and renders configured links safely" do
        get about_url

        assert_select "footer .footer-title", text: I18n.t("footer.links_section"), count: 0
        assert_select "footer .footer-title", count: 3

        footer_settings(:default).update!(
          x_url: "https://social.example/x",
          github_url: "https://code.example/repository"
        )
        get about_url

        assert_select "footer .footer-title", text: I18n.t("footer.links_section"), count: 1
        assert_select 'footer a[href="https://social.example/x"][target="_blank"][rel="noopener noreferrer"]', text: "X(Twitter)", count: 1
        assert_select 'footer a[href="https://code.example/repository"][target="_blank"][rel="noopener noreferrer"]', text: "GitHub", count: 1
      end

      test "footer uses the generated application name and fixed internal routes" do
        get about_url

        assert_select 'footer.footer.footer-vertical[class~="sm:footer-horizontal"]'
        assert_select "footer .footer-title", text: I18n.t("footer.about_section"), count: 1
        assert_select "footer a[href=?]", about_path, text: I18n.t("footer.about", app_name: Rails.configuration.x.application_identity.app_name), count: 1
        assert_select "footer a[href=?]", corp_path, text: I18n.t("footer.company"), count: 1
        assert_select "footer a[href=?]", manual_path, text: I18n.t("footer.manual"), count: 1
        assert_select "footer a[href=?]", faq_path, text: I18n.t("footer.faq"), count: 1
        assert_select "footer a[href=?]", terms_path, text: I18n.t("footer.terms"), count: 1
        assert_select "footer a[href=?]", privacy_path, text: I18n.t("footer.privacy"), count: 1
        assert_select "footer a[href=?]", transaction_law_path, text: I18n.t("footer.transaction_law"), count: 1
        assert_select "footer aside", count: 0
      end
    end
  RUBY

  create_file "test/controllers/faqs_controller_test.rb", <<~RUBY, force: true
    require "test_helper"

    class FaqsControllerTest < ActionDispatch::IntegrationTest
      test "renders the empty state" do
        get faq_url

        assert_response :success
        assert_select ".alert", text: I18n.t("content_management.faqs.empty"), count: 1
      end

      test "renders only published FAQs in order using collapse" do
        Faq.create!(question: "2番目", answer: "回答2", position: 20, published: true)
        Faq.create!(question: "非公開", answer: "秘密", position: 0, published: false)
        Faq.create!(question: "1番目", answer: "回答1", position: 10, published: true)

        get faq_url

        assert_response :success
        assert_equal ["1番目", "2番目"], css_select("details.collapse.collapse-arrow > summary.collapse-title").map { |node| node.text.strip }
        assert_select ".lexxy-content", text: "秘密", count: 0
      end
    end
  RUBY

  create_file "test/controllers/admin/pages_controller_test.rb", <<~RUBY, force: true
    require "test_helper"
    require_relative "../../support/content_management_authentication"

    class Admin::PagesControllerTest < ActionDispatch::IntegrationTest
      include ContentManagementAuthenticationTestSupport

      setup { setup_content_management_users }

      test "requires authentication and denies regular users" do
        get admin_pages_url
        assert_redirected_to #{devise ? "new_user_session_url" : "new_session_url"}

        sign_in_content_user(@regular, #{devise ? "nil" : "@regular_key"})
        get admin_pages_url
        assert_response :forbidden
      end

      test "allows an admin to edit only page content with Lexxy" do
        sign_in_content_user(@admin, #{devise ? "nil" : "@admin_key"})
        page = pages(:about)

        get edit_admin_page_url(page)
        assert_response :success
        assert_select '[data-layout="admin"] nav[aria-label=?]', I18n.t("navigation.admin_menu"), count: 1
        assert_select '[data-layout="admin"] a.menu-active[href=?]', admin_pages_path, text: I18n.t("navigation.pages"), count: 1
        assert_select "lexxy-editor", count: 1

        patch admin_page_url(page), params: {
          page: { content: "<p>更新本文</p>", title: "変更不可", slug: "corp" }
        }

        assert_redirected_to admin_pages_url
        assert_equal Page::TITLES.fetch("about"), page.reload.title
        assert_equal "about", page.slug
        assert_equal "更新本文", page.content.to_plain_text
      end
    end
  RUBY

  create_file "test/controllers/admin/faqs_controller_test.rb", <<~RUBY, force: true
    require "test_helper"
    require_relative "../../support/content_management_authentication"

    class Admin::FaqsControllerTest < ActionDispatch::IntegrationTest
      include ContentManagementAuthenticationTestSupport

      setup { setup_content_management_users }

      test "allows an admin to create update and destroy a FAQ" do
        sign_in_content_user(@admin, #{devise ? "nil" : "@admin_key"})

        get new_admin_faq_url
        assert_response :success
        assert_select '[data-layout="admin"] nav[aria-label=?]', I18n.t("navigation.admin_menu"), count: 1
        assert_select '[data-layout="admin"] a.menu-active[href=?]', admin_faqs_path, text: I18n.t("navigation.faqs"), count: 1
        assert_select "lexxy-editor", count: 1

        assert_difference("Faq.count", 1) do
          post admin_faqs_url, params: {
            faq: { question: "質問", answer: "回答", position: 5, published: "1" }
          }
        end
        faq = Faq.order(:id).last
        assert_redirected_to admin_faqs_url
        assert faq.published?

        patch admin_faq_url(faq), params: {
          faq: { question: "更新質問", answer: "更新回答", position: 2, published: "0" }
        }
        assert_redirected_to admin_faqs_url
        assert_equal ["更新質問", 2, false], faq.reload.values_at(:question, :position, :published)
        assert_equal "更新回答", faq.answer.to_plain_text

        assert_difference("Faq.count", -1) { delete admin_faq_url(faq) }
        assert_redirected_to admin_faqs_url
      end

      test "denies regular users" do
        sign_in_content_user(@regular, #{devise ? "nil" : "@regular_key"})

        get admin_faqs_url

        assert_response :forbidden
      end
    end
  RUBY

  create_file "test/controllers/admin/footer_settings_controller_test.rb", <<~RUBY, force: true
    require "test_helper"
    require_relative "../../support/content_management_authentication"

    class Admin::FooterSettingsControllerTest < ActionDispatch::IntegrationTest
      include ContentManagementAuthenticationTestSupport

      setup { setup_content_management_users }

      test "allows an admin to update HTTPS links" do
        sign_in_content_user(@admin, #{devise ? "nil" : "@admin_key"})

        get edit_admin_footer_setting_url
        assert_response :success
        assert_select '[data-layout="admin"] nav[aria-label=?]', I18n.t("navigation.admin_menu"), count: 1
        assert_select '[data-layout="admin"] a.menu-active[href=?]', edit_admin_footer_setting_path, text: I18n.t("content_management.admin.footer_settings.title"), count: 1

        patch admin_footer_setting_url, params: {
          footer_setting: { x_url: " https://social.example/x ", github_url: "" }
        }

        assert_redirected_to edit_admin_footer_setting_url
        assert_equal "https://social.example/x", footer_settings(:default).reload.x_url
        assert_nil footer_settings(:default).github_url
      end

      test "renders validation errors for unsafe links" do
        sign_in_content_user(@admin, #{devise ? "nil" : "@admin_key"})

        patch admin_footer_setting_url, params: {
          footer_setting: { x_url: "http://social.example/x", github_url: "https://code.example/repository" }
        }

        assert_response :unprocessable_content
        assert_select ".alert.alert-error", count: 1
        assert_nil footer_settings(:default).reload.github_url
      end

      test "denies regular users" do
        sign_in_content_user(@regular, #{devise ? "nil" : "@regular_key"})

        get edit_admin_footer_setting_url

        assert_response :forbidden
      end
    end
  RUBY
end

def configure_profile
  features = VALUES.fetch("profile_features")
  devise = VALUES.fetch("account_authentication") == "devise"
  avatar_enabled = features.include?("avatar")
  attributes = ["user:references"]
  attributes << "screen_name:string" if features.include?("screen_name")
  attributes << "display_name:string" if features.include?("display_name")
  generate "model", "Profile", *attributes

  migration = Dir.glob("db/migrate/*_create_profiles.rb")
  raise "CreateProfiles migrationが一意ではありません" unless migration.one?

  columns = []
  columns << "      t.string :screen_name, null: false" if features.include?("screen_name")
  columns << "      t.string :display_name, null: false" if features.include?("display_name")
  indexes = []
  indexes << "      t.index :screen_name, unique: true" if features.include?("screen_name")
  indexes << "      t.index :display_name, unique: true" if features.include?("display_name")
  create_file migration.first, <<~RUBY, force: true
    class CreateProfiles < ActiveRecord::Migration[8.1]
      def change
        create_table :profiles do |t|
          t.references :user, null: false, foreign_key: true, index: { unique: true }
    #{columns.join("\n")}
    #{indexes.join("\n")}
          t.timestamps
        end
      end
    end
  RUBY

  model_lines = ["  belongs_to :user"]
  if avatar_enabled
    model_lines << <<~RUBY.chomp
      has_one_attached :avatar do |attachment|
        attachment.variant :header_avatar, resize_to_fill: [40, 40]
        attachment.variant :profile_avatar, resize_to_fill: [64, 64]
      end
      attr_accessor :avatar_upload
      validates :avatar_upload, avatar_upload: true
      before_save :assign_avatar_upload, if: -> { avatar_upload.present? }
    RUBY
  end
  if features.include?("screen_name")
    model_lines << '  validates :screen_name, presence: true, uniqueness: true, format: { with: /\\A[a-z0-9_]+\\z/ }'
  end
  model_lines << "  validates :display_name, presence: true, uniqueness: true" if features.include?("display_name")

  generated_name_methods = if features.include?("screen_name") && features.include?("display_name")
    <<~RUBY

      before_validation :assign_generated_names, on: :create

      private
        def assign_generated_names
          self.screen_name = generate_unique_screen_name if screen_name.blank?
          self.display_name = screen_name.camelize if display_name.blank?
        end

        def generate_unique_screen_name
          loop do
            candidate = Haikunator.haikunate(9999, "_")
            next if self.class.exists?(screen_name: candidate)
            next if self.class.exists?(display_name: candidate.camelize)

            return candidate
          end
        end
    RUBY
  elsif features.include?("screen_name")
    <<~RUBY

      before_validation :assign_generated_screen_name, on: :create

      private
        def assign_generated_screen_name
          self.screen_name = generate_unique_screen_name if screen_name.blank?
        end

        def generate_unique_screen_name
          loop do
            candidate = Haikunator.haikunate(9999, "_")
            return candidate unless self.class.exists?(screen_name: candidate)
          end
        end
    RUBY
  elsif features.include?("display_name")
    <<~RUBY

      before_validation :assign_generated_display_name, on: :create

      private
        def assign_generated_display_name
          self.display_name = generate_unique_display_name if display_name.blank?
        end

        def generate_unique_display_name
          loop do
            candidate = Haikunator.haikunate
            return candidate unless self.class.exists?(display_name: candidate)
          end
        end
    RUBY
  else
    ""
  end
  avatar_upload_methods = if avatar_enabled
    <<~RUBY

      private
        def assign_avatar_upload
          self.avatar = avatar_upload
          self.avatar_upload = nil
        end
    RUBY
  else
    ""
  end
  create_file "app/models/profile.rb", <<~RUBY, force: true
    class Profile < ApplicationRecord
    #{model_lines.join("\n")}
    #{generated_name_methods}#{avatar_upload_methods}
    end
  RUBY

  if avatar_enabled
    create_file "app/services/avatar_image_policy.rb", <<~'RUBY', force: true
      require "marcel"
      require "pathname"
      require "vips"

      class AvatarImagePolicy
        MAX_BYTES = 5 * 1024 * 1024
        MAX_SIZE_LABEL = "5 MiB"
        MAX_DIMENSION = 4096
        CONTENT_TYPES = %w[image/jpeg image/png image/webp].freeze

        class ValidationError < StandardError
          attr_reader :code

          def initialize(code)
            @code = code
            super(code.to_s)
          end
        end

        def self.validate!(upload)
          new(upload).validate!
        end

        def initialize(upload)
          @upload = upload
        end

        def validate!
          raise_error(:empty) if upload.size.to_i.zero?
          raise_error(:too_large) if upload.size.to_i > MAX_BYTES

          path = upload.tempfile.path
          actual_type = Marcel::MimeType.for(Pathname(path), name: nil, declared_type: nil)
          declared_type = upload.content_type.to_s.downcase
          raise_error(:unsupported_type) unless CONTENT_TYPES.include?(actual_type)
          raise_error(:content_type_mismatch) unless declared_type == actual_type

          bytes = File.binread(path)
          raise_error(:animated) if animated_png?(bytes) || animated_webp?(bytes)

          image = Vips::Image.new_from_file(path, access: :sequential, fail_on: :truncated)
          raise_error(:too_wide_or_tall) if image.width > MAX_DIMENSION || image.height > MAX_DIMENSION
          if image.get_typeof("n-pages") != 0 && image.get("n-pages").to_i > 1
            raise_error(:animated)
          end
          image.avg
          true
        rescue ValidationError
          raise
        rescue StandardError
          raise_error(:undecodable)
        end

        private
          attr_reader :upload

          def raise_error(code)
            raise ValidationError, code
          end

          def animated_png?(bytes)
            return false unless bytes.start_with?("\x89PNG\r\n\x1A\n".b)

            each_chunk(bytes, offset: 8, length_bytes: 4, byte_order: "N") do |type, _data|
              return true if type == "acTL"
              break if type == "IEND"
            end
            false
          end

          def animated_webp?(bytes)
            return false unless bytes.byteslice(0, 4) == "RIFF" && bytes.byteslice(8, 4) == "WEBP"

            offset = 12
            while offset + 8 <= bytes.bytesize
              type = bytes.byteslice(offset, 4)
              length = bytes.byteslice(offset + 4, 4).unpack1("V")
              data_start = offset + 8
              break if data_start + length > bytes.bytesize

              data = bytes.byteslice(data_start, length)
              return true if %w[ANIM ANMF].include?(type)
              return true if type == "VP8X" && (data.getbyte(0).to_i & 0b0000_0010).positive?

              offset += 8 + length + (length.odd? ? 1 : 0)
            end
            false
          end

          def each_chunk(bytes, offset:, length_bytes:, byte_order:)
            while offset + length_bytes + 4 <= bytes.bytesize
              length = bytes.byteslice(offset, length_bytes).unpack1(byte_order)
              type = bytes.byteslice(offset + length_bytes, 4)
              data_start = offset + length_bytes + 4
              break if data_start + length > bytes.bytesize

              yield type, bytes.byteslice(data_start, length)
              chunk_size = length_bytes + 4 + length
              chunk_size += 4
              offset += chunk_size
            end
          end
      end
    RUBY

    create_file "app/validators/avatar_upload_validator.rb", <<~'RUBY', force: true
      class AvatarUploadValidator < ActiveModel::EachValidator
        def validate_each(record, attribute, upload)
          return if upload.blank?

          AvatarImagePolicy.validate!(upload)
        rescue AvatarImagePolicy::ValidationError => error
          record.errors.add(
            attribute,
            error.code,
            max_size: AvatarImagePolicy::MAX_SIZE_LABEL,
            max_dimension: AvatarImagePolicy::MAX_DIMENSION
          )
        end
      end
    RUBY
  end

  inject_into_class "app/models/user.rb", "User", <<~RUBY
      has_one :profile, dependent: :destroy
      after_create :create_profile!

  RUBY

  profile_owner = devise ? "current_user" : "Current.user"
  authentication = devise ? "  before_action :authenticate_user!\n" : ""
  permitted_features = features.map { |feature| feature == "avatar" ? ":avatar_upload" : ":#{feature}" }.join(", ")
  destroy_avatar_action = if avatar_enabled
    <<~RUBY

        def destroy_avatar
          #{profile_owner}.profile.avatar.purge if #{profile_owner}.profile.avatar.attached?
          redirect_to profile_path, notice: I18n.t("profiles.avatar.destroy.notice"), status: :see_other
        end
    RUBY
  else
    ""
  end
  create_file "app/controllers/profiles_controller.rb", <<~RUBY, force: true
    class ProfilesController < ApplicationController
      layout "account"
    #{authentication}
      def show
        @profile = #{profile_owner}.profile
      end

      def edit
        @profile = #{profile_owner}.profile
      end

      def update
        @profile = #{profile_owner}.profile
        if @profile.update(profile_params)
          redirect_to profile_path, notice: I18n.t("profiles.update.notice"), status: :see_other
        else
          render :edit, status: :unprocessable_content
        end
      end
    #{destroy_avatar_action}

      private
        def profile_params
          params.expect(profile: [#{permitted_features}])
        end
    end
  RUBY
  route "resource :profile, only: %i[show edit update]"
  route 'delete "profile/avatar", to: "profiles#destroy_avatar", as: :profile_avatar' if avatar_enabled

  profile_locale_ja = {
    "profiles" => {
      "title" => "プロフィール", "edit_title" => "プロフィール編集", "eyebrow" => "プロフィール", "edit" => "プロフィールを編集",
      "screen_name_hint" => "小文字の英数字とアンダースコアが使えます。", "current_avatar" => "現在のアバター", "avatar_label" => "アバター", "avatar_hint" => "静止画JPEG、PNG、WebP（5 MiB以下、幅・高さ4096px以下）を選択してください。",
      "avatar_delete_title" => "アバター画像の削除", "avatar_delete_description" => "設定済みの画像を削除し、IDから生成したアバターへ戻します。", "avatar_delete" => "設定済み画像を削除", "avatar_delete_confirm" => "設定済みのアバター画像を削除しますか？",
      "update" => { "notice" => "プロフィールを更新しました" }, "avatar" => { "destroy" => { "notice" => "アバター画像を削除しました" } }
    },
    "activerecord" => {
      "attributes" => { "profile" => { "screen_name" => "スクリーンネーム", "display_name" => "表示名", "avatar" => "アバター画像", "avatar_upload" => "アバター画像" } },
      "errors" => { "models" => { "profile" => { "attributes" => { "avatar_upload" => {
        "empty" => "が空です", "too_large" => "は%{max_size}以下にしてください", "unsupported_type" => "は静止画JPEG、PNG、WebPを選択してください",
        "content_type_mismatch" => "のファイル形式と申告形式が一致しません", "too_wide_or_tall" => "の幅と高さは%{max_dimension}px以下にしてください",
        "animated" => "にanimationを含めることはできません", "undecodable" => "を画像として解析できません"
      } } } } }
    }
  }
  profile_locale_en = {
    "profiles" => {
      "title" => "Profile", "edit_title" => "Edit profile", "eyebrow" => "Profile", "edit" => "Edit profile",
      "screen_name_hint" => "Use lowercase letters, numbers, and underscores.", "current_avatar" => "Current avatar", "avatar_label" => "Avatar", "avatar_hint" => "Choose a static JPEG, PNG, or WebP up to 5 MiB and 4096px on either side.",
      "avatar_delete_title" => "Delete avatar image", "avatar_delete_description" => "Delete the uploaded image and return to the avatar generated from your ID.", "avatar_delete" => "Delete uploaded image", "avatar_delete_confirm" => "Delete the uploaded avatar image?",
      "update" => { "notice" => "Your profile was updated." }, "avatar" => { "destroy" => { "notice" => "Your avatar image was deleted." } }
    },
    "activerecord" => {
      "attributes" => { "profile" => { "screen_name" => "Screen name", "display_name" => "Display name", "avatar" => "Avatar image", "avatar_upload" => "Avatar image" } },
      "errors" => { "models" => { "profile" => { "attributes" => { "avatar_upload" => {
        "empty" => "is empty", "too_large" => "must be no larger than %{max_size}", "unsupported_type" => "must be a static JPEG, PNG, or WebP",
        "content_type_mismatch" => "does not match its declared file type", "too_wide_or_tall" => "must be no wider or taller than %{max_dimension}px",
        "animated" => "must not contain animation", "undecodable" => "could not be decoded as an image"
      } } } } }
    }
  }
  create_locale_pair("profiles", ja: profile_locale_ja, en: profile_locale_en)

  if avatar_enabled
    create_file "app/helpers/avatar_helper.rb", <<~RUBY, force: true
      module AvatarHelper
        BORING_AVATAR_COLORS = %w[#3ea8ff #0f83fd #10b981 #f59e0b #f43f5e].freeze
        AVATAR_VARIANTS = { 40 => :header_avatar, 64 => :profile_avatar }.freeze

        def profile_avatar(profile, size:, alt:)
          variant = AVATAR_VARIANTS.fetch(size)
          if profile.avatar.attached?
            image_tag profile.avatar.variant(variant), alt: alt, class: "object-cover", width: size, height: size
          else
            accessibility = alt.present? ? { label: alt } : { hidden: true }
            boring_avatar(
              profile.user_id.to_s,
              variant: :marble,
              colors: BORING_AVATAR_COLORS,
              size: size,
              class: "object-cover",
              aria: accessibility
            )
          end
        end
      end
    RUBY

    create_file "test/support/avatar_test_image.rb", <<~'RUBY', force: true
      require "base64"
      require "rack/test"
      require "tempfile"
      require "vips"
      require "zlib"

      module AvatarTestImage
        GIF = Base64.decode64("R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==")

        module_function

        def upload(format: :png, width: 96, height: 72, content_type: nil)
          tempfile = Tempfile.new(["avatar-", ".#{format}"])
          tempfile.binmode
          image = Vips::Image.black(width, height, bands: 3).new_from_image([32, 128, 224])
          image.write_to_file(tempfile.path)
          tempfile.rewind
          uploaded_file(tempfile, "avatar.#{format}", content_type || "image/#{format == :jpg ? 'jpeg' : format}")
        end

        def empty_upload
          tempfile = Tempfile.new(["avatar-empty-", ".png"])
          uploaded_file(tempfile, "empty.png", "image/png")
        end

        def corrupt_png_upload
          tempfile = Tempfile.new(["avatar-corrupt-", ".png"])
          tempfile.binmode
          tempfile.write("\x89PNG\r\n\x1A\ncorrupt".b)
          tempfile.rewind
          uploaded_file(tempfile, "corrupt.png", "image/png")
        end

        def gif_upload
          binary_upload(GIF, "avatar.gif", "image/gif")
        end

        def oversized_bytes_upload
          file = upload
          insert_png_chunk(file.tempfile, "tEXt", "padding\0" + ("x" * AvatarImagePolicy::MAX_BYTES))
          file
        end

        def apng_upload
          file = upload
          insert_png_chunk(file.tempfile, "acTL", [2, 0].pack("NN"), after_ihdr: true)
          file
        end

        def animated_webp_upload
          tempfile = Tempfile.new(["avatar-animated-", ".webp"])
          tempfile.binmode
          first = Vips::Image.black(16, 16, bands: 3).new_from_image([255, 0, 0])
          second = Vips::Image.black(16, 16, bands: 3).new_from_image([0, 0, 255])
          pages = Vips::Image.arrayjoin([first, second], across: 1)
          pages = pages.mutate do |image|
            image.set_type! GObject::GINT_TYPE, "page-height", 16
          end
          pages.write_to_file(tempfile.path, page_height: 16)
          tempfile.rewind
          uploaded_file(tempfile, "animated.webp", "image/webp")
        end

        def binary_upload(bytes, filename, content_type)
          tempfile = Tempfile.new(["avatar-binary-", File.extname(filename)])
          tempfile.binmode
          tempfile.write(bytes)
          tempfile.rewind
          uploaded_file(tempfile, filename, content_type)
        end

        def uploaded_file(tempfile, filename, content_type)
          uploaded_file = Rack::Test::UploadedFile.new(
            tempfile.path, content_type, true, original_filename: filename
          )
          tempfile.close!
          uploaded_file
        end

        def insert_png_chunk(tempfile, type, data, after_ihdr: false)
          bytes = File.binread(tempfile.path)
          chunk = [data.bytesize].pack("N") + type + data + [Zlib.crc32(type + data)].pack("N")
          offset = after_ihdr ? 33 : bytes.index("IEND") - 4
          tempfile.rewind
          tempfile.truncate(0)
          tempfile.write(bytes.byteslice(0, offset) + chunk + bytes.byteslice(offset..))
          tempfile.rewind
        end
      end
    RUBY
    append_to_file "test/test_helper.rb", "\nrequire_relative \"support/avatar_test_image\"\n"

    create_file "test/services/avatar_image_policy_test.rb", <<~'RUBY', force: true
      require "test_helper"

      class AvatarImagePolicyTest < ActiveSupport::TestCase
        test "accepts decodable static JPEG PNG and WebP images" do
          { jpg: "image/jpeg", png: "image/png", webp: "image/webp" }.each do |format, content_type|
            assert AvatarImagePolicy.validate!(AvatarTestImage.upload(format:, content_type:))
          end
        end

        test "rejects empty and oversized files before decoding" do
          assert_policy_error :empty, AvatarTestImage.empty_upload
          assert_policy_error :too_large, AvatarTestImage.oversized_bytes_upload
        end

        test "rejects mismatched declared content type and unsupported formats" do
          assert_policy_error :content_type_mismatch, AvatarTestImage.upload(content_type: "image/jpeg")
          assert_policy_error :unsupported_type, AvatarTestImage.gif_upload
        end

        test "rejects excessive dimensions and undecodable images" do
          assert_policy_error :too_wide_or_tall, AvatarTestImage.upload(width: AvatarImagePolicy::MAX_DIMENSION + 1, height: 1)
          assert_policy_error :undecodable, AvatarTestImage.corrupt_png_upload
        end

        test "rejects APNG and animated WebP" do
          assert_policy_error :animated, AvatarTestImage.apng_upload
          assert_policy_error :animated, AvatarTestImage.animated_webp_upload
        end

        private
          def assert_policy_error(code, upload)
            error = assert_raises(AvatarImagePolicy::ValidationError) do
              AvatarImagePolicy.validate!(upload)
            end
            assert_equal code, error.code
          end
      end
    RUBY

    create_file "test/helpers/avatar_helper_test.rb", <<~RUBY, force: true
      require "test_helper"

      class AvatarHelperTest < ActionView::TestCase
        test "generates the default avatar from the user id and Rapid Rails palette" do
          profile = profiles(:one)
          view = ApplicationController.helpers
          expected = view.boring_avatar(
            profile.user_id.to_s,
            variant: :marble,
            colors: AvatarHelper::BORING_AVATAR_COLORS,
            size: 64,
            class: "object-cover",
            aria: { label: "デフォルトアバター" }
          )

          actual = profile_avatar(profile, size: 64, alt: "デフォルトアバター")

          assert_equal normalize_boring_avatar_ids(expected), normalize_boring_avatar_ids(actual)
        end

        test "renders an attached image instead of a Boring Avatar" do
          profile = profiles(:one)
          upload = AvatarTestImage.upload
          profile.avatar.attach(upload)

          rendered = profile_avatar(profile, size: 64, alt: "現在のアバター")

          assert_includes rendered, "<img"
          assert_not_includes rendered, "<svg"
          if Rails.configuration.active_storage.resolve_model_to_route == :imgproxy_active_storage
            assert_includes rendered, "http://localhost:8080/"
            assert_not_includes rendered, "/unsafe/"
          else
            assert_includes rendered, "/rails/active_storage/representations/"
          end
          assert_includes rendered, 'width="64"'
          assert_includes rendered, 'height="64"'
        ensure
          profile&.avatar&.purge
        end

        test "uses only the named variants with their exact output dimensions" do
          profile = profiles(:one)
          profile.avatar.attach(AvatarTestImage.upload(width: 120, height: 80))

          { header_avatar: [40, 40], profile_avatar: [64, 64] }.each do |name, dimensions|
            variant = profile.avatar.variant(name).processed
            variant.image.blob.open do |file|
              image = Vips::Image.new_from_file(file.path)
              assert_equal dimensions, [image.width, image.height]
            end
          end
          assert_equal 2, profile.avatar.blob.variant_records.count
        ensure
          profile&.avatar&.purge
        end

        test "rejects a display size without a named variant" do
          assert_raises(KeyError) do
            profile_avatar(profiles(:one), size: 48, alt: "未定義")
          end
        end

        private
          def boring_avatar(...)
            ApplicationController.helpers.boring_avatar(...)
          end

          def normalize_boring_avatar_ids(svg)
            svg.gsub(/ba-[0-9a-f]{20}/, "ba-normalized")
          end
      end
    RUBY
  end

  fixture_fields = []
  fixture_fields << "  screen_name: profile_one" if features.include?("screen_name")
  fixture_fields << "  display_name: Profile One" if features.include?("display_name")
  second_fixture_fields = []
  second_fixture_fields << "  screen_name: profile_two" if features.include?("screen_name")
  second_fixture_fields << "  display_name: Profile Two" if features.include?("display_name")
  create_file "test/fixtures/profiles.yml", <<~YAML, force: true
    one:
      user: one
    #{fixture_fields.join("\n")}

    two:
      user: two
    #{second_fixture_fields.join("\n")}
  YAML

  profile_tests = []
  if features.include?("screen_name")
    profile_tests << <<~RUBY
      test "screen_name only accepts lowercase alphanumeric characters and underscores" do
        profile = profiles(:one)
        profile.screen_name = "Invalid-Name"

        assert_not profile.valid?
        assert profile.errors.of_kind?(:screen_name, :invalid)
      end

      test "screen_name is required and unique" do
        profile = profiles(:two)
        profile.screen_name = nil

        assert_not profile.valid?
        assert profile.errors.of_kind?(:screen_name, :blank)

        profile.screen_name = profiles(:one).screen_name

        assert_not profile.valid?
        assert profile.errors.of_kind?(:screen_name, :taken)
      end
    RUBY
  end
  if features.include?("display_name")
    profile_tests << <<~RUBY
      test "display_name is required and unique" do
        profile = profiles(:two)
        profile.display_name = nil

        assert_not profile.valid?
        assert profile.errors.of_kind?(:display_name, :blank)

        profile.display_name = profiles(:one).display_name

        assert_not profile.valid?
        assert profile.errors.of_kind?(:display_name, :taken)
      end
    RUBY
  end
  if features.include?("screen_name") && features.include?("display_name")
    profile_tests << <<~RUBY
      test "generates display_name from the CamelCase screen_name" do
        profile = Profile.new(user: users(:one))

        assert profile.valid?

        assert_match(/\\A[a-z0-9_]+\\z/, profile.screen_name)
        assert_equal profile.screen_name.camelize, profile.display_name
      end
    RUBY
  elsif features.include?("screen_name")
    profile_tests << <<~RUBY
      test "generates screen_name with Haikunator" do
        profile = Profile.new(user: users(:one))

        assert profile.valid?

        assert_match(/\\A[a-z0-9_]+\\z/, profile.screen_name)
      end
    RUBY
  elsif features.include?("display_name")
    profile_tests << <<~RUBY
      test "generates display_name with Haikunator" do
        profile = Profile.new(user: users(:one))

        assert profile.valid?

        assert_predicate profile.display_name, :present?
      end
    RUBY
  else
    profile_tests << <<~RUBY
      test "belongs to one user" do
        assert_equal users(:one), profiles(:one).user
      end
    RUBY
  end
  if avatar_enabled
    profile_tests << <<~RUBY
      test "attaches validated JPEG PNG and WebP uploads only when the profile saves" do
        profile = profiles(:one)
        { jpg: "image/jpeg", png: "image/png", webp: "image/webp" }.each do |format, content_type|
          profile.avatar_upload = AvatarTestImage.upload(format:, content_type:)

          assert profile.save
          assert_predicate profile.avatar, :attached?
          assert_equal content_type, profile.avatar.blob.content_type
          profile.avatar.purge
        end
      ensure
        profile&.avatar&.purge
      end

      test "keeps the current avatar when a replacement upload is invalid" do
        profile = profiles(:one)
        profile.avatar.attach(AvatarTestImage.upload)
        original_blob = profile.avatar.blob
        profile.avatar_upload = AvatarTestImage.corrupt_png_upload

        blob_count = ActiveStorage::Blob.count
        file_count = ActiveStorageDB::File.count
        assert_not profile.save
        assert profile.errors.of_kind?(:avatar_upload, :undecodable)
        assert_equal original_blob, profile.reload.avatar.blob
        assert_equal blob_count, ActiveStorage::Blob.count
        assert_equal file_count, ActiveStorageDB::File.count
      ensure
        profile&.avatar&.purge
      end

      test "removes avatar blobs variants and Active Storage DB files with the user" do
        user = users(:one)
        user.profile.avatar.attach(AvatarTestImage.upload(width: 120, height: 80))
        user.profile.avatar.variant(:profile_avatar).processed
        blob_ids = [user.profile.avatar.blob_id, *user.profile.avatar.blob.variant_records.map { |record| record.image.blob_id }]
        storage_refs = ActiveStorage::Blob.where(id: blob_ids).pluck(:key)

        perform_enqueued_jobs { user.destroy! }

        assert_empty ActiveStorage::Blob.where(id: blob_ids)
        assert_empty ActiveStorageDB::File.where(ref: storage_refs)
        assert_empty ActiveStorage::VariantRecord.where(blob_id: blob_ids)
      end
    RUBY
  end
  create_file "test/models/profile_test.rb", <<~RUBY, force: true
    require "test_helper"

    class ProfileTest < ActiveSupport::TestCase
    #{avatar_enabled ? "  include ActiveJob::TestHelper\n" : ""}
    #{profile_tests.join("\n")}end
  RUBY

  form_fields = []
  if features.include?("screen_name")
    form_fields << <<~ERB
      <fieldset class="fieldset">
        <legend class="fieldset-legend"><%= form.label :screen_name %></legend>
        <%= form.text_field :screen_name, class: "input input-rapid w-full", pattern: "[a-z0-9_]+", autocomplete: "username", required: true %>
        <p class="label"><%= t("profiles.screen_name_hint") %></p>
      </fieldset>
    ERB
  end
  if features.include?("display_name")
    form_fields << <<~ERB
      <fieldset class="fieldset">
        <legend class="fieldset-legend"><%= form.label :display_name %></legend>
        <%= form.text_field :display_name, class: "input input-rapid w-full", autocomplete: "name", required: true %>
      </fieldset>
    ERB
  end
  if avatar_enabled
    form_fields << <<~ERB
      <fieldset class="fieldset min-w-0 grid-cols-1">
        <legend class="fieldset-legend"><%= form.label :avatar_upload %></legend>
        <div class="avatar">
          <div class="w-16 rounded-full">
            <%= profile_avatar(profile, size: 64, alt: t("profiles.current_avatar")) %>
          </div>
        </div>
        <%= form.file_field :avatar_upload, class: "file-input min-w-0 w-full", accept: "image/jpeg,image/png,image/webp" %>
        <p class="label"><span class="min-w-0 whitespace-normal"><%= t("profiles.avatar_hint") %></span></p>
      </fieldset>
    ERB
  end
  form_fields = form_fields.join("\n").lines.map { |line| "  #{line}" }.join
  create_file "app/views/profiles/_form.html.erb", <<~ERB, force: true
    <%= form_with model: profile, url: profile_path, class: "space-y-5" do |form| %>
      <% if profile.errors.any? %>
        <div class="alert alert-error" role="alert">
          <ul class="list-disc pl-5">
            <% profile.errors.full_messages.each do |message| %>
              <li><%= message %></li>
            <% end %>
          </ul>
        </div>
      <% end %>

    #{form_fields}  <div class="card-actions justify-end">
        <%= link_to t("common.cancel"), profile_path, class: "btn btn-ghost btn-rapid" %>
        <%= form.submit t("common.save"), class: "btn btn-primary btn-rapid" %>
      </div>
    <% end %>
  ERB

  profile_rows = []
  if avatar_enabled
    profile_rows << <<~ERB
      <li class="list-row">
        <span class="text-sm text-neutral"><%= t("profiles.avatar_label") %></span>
        <div class="avatar">
          <div class="w-16 rounded-full">
            <%= profile_avatar(@profile, size: 64, alt: t("profiles.current_avatar")) %>
          </div>
        </div>
      </li>
    ERB
  end
  if features.include?("display_name")
    profile_rows << <<~ERB
      <li class="list-row">
        <span class="text-sm text-neutral"><%= Profile.human_attribute_name(:display_name) %></span>
        <strong><%= @profile.display_name.presence || t("common.not_set") %></strong>
      </li>
    ERB
  end
  if features.include?("screen_name")
    profile_rows << <<~ERB
      <li class="list-row">
        <span class="text-sm text-neutral"><%= Profile.human_attribute_name(:screen_name) %></span>
        <strong><%= @profile.screen_name.present? ? "@\#{@profile.screen_name}" : t("common.not_set") %></strong>
      </li>
    ERB
  end
  profile_rows = profile_rows.join("\n").lines.map { |line| "        #{line}" }.join
  avatar_delete_section = if avatar_enabled
    <<~ERB

      <% if @profile.avatar.attached? %>
        <section class="card card-border border-error bg-base-100 shadow-none">
          <div class="card-body">
            <h2 class="card-title text-base leading-[1.5]"><%= t("profiles.avatar_delete_title") %></h2>
            <p class="text-sm text-neutral"><%= t("profiles.avatar_delete_description") %></p>
            <div class="card-actions justify-start">
              <%= button_to t("profiles.avatar_delete"), profile_avatar_path, method: :delete, class: "btn btn-outline btn-error btn-rapid", data: { turbo_confirm: t("profiles.avatar_delete_confirm") } %>
            </div>
          </div>
        </section>
      <% end %>
    ERB
  else
    ""
  end
  create_file "app/views/profiles/show.html.erb", <<~ERB, force: true
    <% content_for :title, t("profiles.title") %>
    <div class="space-y-6">
      <header>
        <p class="text-sm font-semibold text-primary"><%= t("profiles.eyebrow") %></p>
        <h1 class="mt-1 text-2xl font-bold leading-[1.5]"><%= t("profiles.title") %></h1>
      </header>

      <section class="card card-border border-base-300 bg-base-100 shadow-none">
        <div class="card-body">
          <ul class="list">
    #{profile_rows}      </ul>
          <div class="card-actions justify-end">
            <%= link_to t("profiles.edit"), edit_profile_path, class: "btn btn-primary btn-outline btn-rapid" %>
          </div>
        </div>
      </section>
    </div>
  ERB

  create_file "app/views/profiles/edit.html.erb", <<~ERB, force: true
    <% content_for :title, t("profiles.edit_title") %>
    <div class="space-y-6">
      <header>
        <p class="text-sm font-semibold text-primary"><%= t("profiles.eyebrow") %></p>
        <h1 class="mt-1 text-2xl font-bold leading-[1.5]"><%= t("profiles.edit_title") %></h1>
      </header>

      <section class="card card-border border-base-300 bg-base-100 shadow-none">
        <div class="card-body">
          <%= render "form", profile: @profile %>
        </div>
      </section>
    #{avatar_delete_section}</div>
  ERB
end

def configure_api
  devise = VALUES.fetch("account_authentication") == "devise"
  generate "model", "ApiCredential", "user:references", "name:string", "api_key:string:uniq", "api_secret_digest:string", "last_used_at:datetime"
  remove_file "test/fixtures/api_credentials.yml"

  migration = Dir.glob("db/migrate/*_create_api_credentials.rb")
  raise "CreateApiCredentials migrationが一意ではありません" unless migration.one?

  create_file migration.first, <<~RUBY, force: true
    class CreateApiCredentials < ActiveRecord::Migration[8.1]
      def change
        create_table :api_credentials do |t|
          t.references :user, null: false, foreign_key: true
          t.string :name, null: false
          t.string :api_key, null: false
          t.string :api_secret_digest, null: false
          t.datetime :last_used_at
          t.timestamps
        end

        add_index :api_credentials, :api_key, unique: true
      end
    end
  RUBY

  create_file "app/models/api_credential.rb", <<~RUBY, force: true
    require "digest"
    require "securerandom"

    class ApiCredential < ApplicationRecord
      belongs_to :user

      attr_reader :api_secret

      validates :name, :api_key, :api_secret_digest, presence: true
      validates :api_key, uniqueness: true

      before_validation :assign_api_key, :assign_api_secret, on: :create

      def authenticate_api_secret(candidate)
        return false if candidate.blank?

        ActiveSupport::SecurityUtils.secure_compare(api_secret_digest, digest(candidate))
      end

      def revoke_api_secret!
        secret = generate_api_secret
        update!(api_secret_digest: digest(secret))
        @api_secret = secret
      end

      private
        def assign_api_key
          self.api_key ||= "rak_" + SecureRandom.urlsafe_base64(24, false)
        end

        def assign_api_secret
          return if api_secret_digest.present?

          @api_secret = generate_api_secret
          self.api_secret_digest = digest(@api_secret)
        end

        def generate_api_secret
          "ras_" + SecureRandom.urlsafe_base64(32, false)
        end

        def digest(value)
          Digest::SHA256.hexdigest(value)
        end
    end
  RUBY

  inject_into_class "app/models/user.rb", "User", <<~RUBY
      has_many :api_credentials, dependent: :destroy

  RUBY

  create_file "app/controllers/api/api_controller.rb", <<~RUBY, force: true
    module Api
      class ApiController < ActionController::API
        include ActionController::HttpAuthentication::Token::ControllerMethods
        include LocalizedRequest

        before_action :authenticate_api_credential!

        attr_reader :current_api_credential, :current_api_user

        rescue_from ActiveRecord::RecordNotFound, with: -> { head :not_found }
        rescue_from ActionController::ParameterMissing do |error|
          render json: { errors: [error.message] }, status: :bad_request
        end

        private
          def authenticate_api_credential!
            token = authenticate_with_http_token { |candidate, _options| candidate }
            api_key, api_secret = token.to_s.split(".", 2)
            credential = ApiCredential.find_by(api_key: api_key)
            return head :unauthorized unless credential&.authenticate_api_secret(api_secret)

            @current_api_credential = credential
            @current_api_user = credential.user
            credential.update!(last_used_at: Time.current)
          end
      end
    end
  RUBY

  create_file "app/controllers/api/api_credentials_controller.rb", <<~RUBY, force: true
    module Api
      class ApiCredentialsController < ApiController
        before_action :set_api_credential, only: %i[show update destroy revoke]

        def index
          render json: current_api_user.api_credentials.order(created_at: :desc).map { |credential| credential_payload(credential) }
        end

        def show
          render json: credential_payload(@api_credential)
        end

        def create
          credential = current_api_user.api_credentials.new(api_credential_params)
          if credential.save
            render json: credential_payload(credential).merge(api_secret: credential.api_secret), status: :created
          else
            render json: { errors: credential.errors.full_messages }, status: :unprocessable_content
          end
        end

        def update
          if @api_credential.update(api_credential_params)
            render json: credential_payload(@api_credential)
          else
            render json: { errors: @api_credential.errors.full_messages }, status: :unprocessable_content
          end
        end

        def destroy
          @api_credential.destroy!
          head :no_content
        end

        def revoke
          secret = @api_credential.revoke_api_secret!
          render json: credential_payload(@api_credential).merge(api_secret: secret)
        end

        private
          def set_api_credential
            @api_credential = current_api_user.api_credentials.find(params.expect(:id))
          end

          def api_credential_params
            params.expect(api_credential: [:name])
          end

          def credential_payload(credential)
            credential.as_json(only: %i[id name api_key last_used_at created_at updated_at])
          end
      end
    end
  RUBY

  account_user = devise ? "current_user" : "Current.user"
  devise_authentication = devise ? "  before_action :authenticate_user!\n" : ""
  create_file "app/controllers/api_credentials_controller.rb", <<~RUBY, force: true
    class ApiCredentialsController < ApplicationController
      layout "account"
    #{devise_authentication}  before_action :set_api_credential, only: %i[show edit update destroy revoke]

      def index
        @api_credentials = account_user.api_credentials.order(created_at: :desc)
      end

      def show; end

      def new
        @api_credential = account_user.api_credentials.new
      end

      def edit; end

      def create
        @api_credential = account_user.api_credentials.new(api_credential_params)
        if @api_credential.save
          @api_secret = @api_credential.api_secret
          render :show, status: :created
        else
          render :new, status: :unprocessable_content
        end
      end

      def update
        if @api_credential.update(api_credential_params)
          redirect_to @api_credential
        else
          render :edit, status: :unprocessable_content
        end
      end

      def destroy
        @api_credential.destroy!
        redirect_to api_credentials_path, status: :see_other
      end

      def revoke
        @api_secret = @api_credential.revoke_api_secret!
        render :show
      end

      private
        def account_user
          #{account_user}
        end

        def set_api_credential
          @api_credential = account_user.api_credentials.find(params.expect(:id))
        end

        def api_credential_params
          params.expect(api_credential: [:name])
        end
    end
  RUBY

  create_file "app/javascript/controllers/clipboard_controller.js", <<~JAVASCRIPT, force: true
    import { Controller } from "@hotwired/stimulus"

    export default class extends Controller {
      static targets = ["source", "button"]
      static values = { copied: String }

      async copy() {
        await navigator.clipboard.writeText(this.sourceTarget.value)
        this.buttonTarget.textContent = this.copiedValue
      }
    }
  JAVASCRIPT

  create_locale_pair("api_credentials",
    ja: {
      "api_credentials" => {
        "title" => "APIキーの管理", "description" => "アプリケーションからAPIへ接続するためのcredentialを管理します。", "new" => "APIキーを作成", "edit" => "APIキーを編集", "details" => "APIキー詳細", "eyebrow" => "API credential", "name_hint" => "利用用途が分かる名前を入力してください。", "api_key" => "API key", "last_used" => "最終利用", "show" => "詳細", "empty" => "APIキーはまだありません。", "api_key_label" => "%{name}のAPI key", "secret_once" => "API Secretはこの画面で一度だけ表示されます。", "information" => "Credential情報", "revoke" => "API Secretを再発行", "revoke_confirm" => "現在のAPI Secretは無効になります。再発行しますか？", "delete_confirm" => "このAPIキーを削除しますか？", "back" => "APIキー一覧へ"
      },
      "activerecord" => { "attributes" => { "api_credential" => { "name" => "名前" } } }
    },
    en: {
      "api_credentials" => {
        "title" => "API credentials", "description" => "Manage credentials used by applications to connect to the API.", "new" => "Create API credential", "edit" => "Edit API credential", "details" => "API credential details", "eyebrow" => "API credential", "name_hint" => "Enter a name that describes how this credential is used.", "api_key" => "API key", "last_used" => "Last used", "show" => "Details", "empty" => "There are no API credentials yet.", "api_key_label" => "%{name} API key", "secret_once" => "The API Secret is shown only once on this screen.", "information" => "Credential information", "revoke" => "Reissue API Secret", "revoke_confirm" => "The current API Secret will be invalidated. Reissue it?", "delete_confirm" => "Delete this API credential?", "back" => "Back to API credentials"
      },
      "activerecord" => { "attributes" => { "api_credential" => { "name" => "Name" } } }
    }
  )

  route <<~RUBY
    resources :api_credentials do
      patch :revoke, on: :member
    end
    namespace :api do
      resources :api_credentials, only: %i[index show create update destroy] do
        patch :revoke, on: :member
      end
    end
  RUBY

  create_file "app/views/api_credentials/_form.html.erb", <<~ERB, force: true
    <%= form_with model: api_credential, class: "space-y-5" do |form| %>
      <% if api_credential.errors.any? %>
        <div class="alert alert-error" role="alert">
          <ul class="list-disc pl-5">
            <% api_credential.errors.full_messages.each do |message| %>
              <li><%= message %></li>
            <% end %>
          </ul>
        </div>
      <% end %>
      <fieldset class="fieldset">
        <legend class="fieldset-legend text-sm font-semibold leading-[1.5]"><%= form.label :name %></legend>
        <%= form.text_field :name, required: true, autocomplete: "off", class: "input input-rapid w-full" %>
        <p class="label"><%= t("api_credentials.name_hint") %></p>
      </fieldset>
      <div class="flex flex-col gap-3 sm:flex-row">
        <%= form.submit class: "btn btn-primary btn-rapid" %>
        <%= link_to t("common.cancel"), api_credential.persisted? ? api_credential_path(api_credential) : api_credentials_path, class: "btn btn-outline btn-rapid" %>
      </div>
    <% end %>
  ERB

  create_file "app/views/api_credentials/index.html.erb", <<~ERB, force: true
    <% content_for :title, t("api_credentials.title") %>
    <div class="space-y-6">
      <header class="flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
        <div>
          <p class="text-sm font-semibold text-primary"><%= t("api_credentials.eyebrow") %></p>
          <h1 class="mt-1 text-2xl font-bold leading-[1.5]"><%= t("api_credentials.title") %></h1>
          <p class="mt-2 text-sm text-neutral"><%= t("api_credentials.description") %></p>
        </div>
        <%= link_to t("api_credentials.new"), new_api_credential_path, class: "btn btn-primary btn-rapid" %>
      </header>

      <section class="card card-border border-base-300 bg-base-100 shadow-none">
        <div class="card-body p-5 sm:p-6">
          <% if @api_credentials.any? %>
            <div class="overflow-x-auto">
              <table class="table">
                <thead><tr><th><%= ApiCredential.human_attribute_name(:name) %></th><th><%= t("api_credentials.api_key") %></th><th><%= t("api_credentials.last_used") %></th><th></th></tr></thead>
                <tbody>
                  <% @api_credentials.each do |credential| %>
                    <tr>
                      <td class="font-semibold"><%= credential.name %></td>
                      <td>
                        <div class="join w-80" data-controller="clipboard" data-clipboard-copied-value="<%= t('common.copied') %>">
                          <input type="text" value="<%= credential.api_key %>" readonly autocomplete="off" aria-label="<%= t('api_credentials.api_key_label', name: credential.name) %>" class="input join-item min-w-0 flex-1 font-mono" data-clipboard-target="source">
                          <button type="button" class="btn join-item" data-clipboard-target="button" data-action="clipboard#copy"><%= t("common.copy") %></button>
                        </div>
                      </td>
                      <td><%= credential.last_used_at ? l(credential.last_used_at, format: :short) : t("common.unused") %></td>
                      <td><%= link_to t("api_credentials.show"), api_credential_path(credential), class: "btn btn-outline btn-sm" %></td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>
          <% else %>
            <div class="alert alert-info alert-soft" role="status"><span><%= t("api_credentials.empty") %></span></div>
          <% end %>
        </div>
      </section>
    </div>
  ERB

  create_file "app/views/api_credentials/show.html.erb", <<~ERB, force: true
    <% content_for :title, t("api_credentials.details") %>
    <div class="space-y-6">
      <header>
        <p class="text-sm font-semibold text-primary"><%= t("api_credentials.eyebrow") %></p>
        <h1 class="mt-1 text-2xl font-bold leading-[1.5]"><%= @api_credential.name %></h1>
      </header>

      <% if @api_secret.present? %>
        <div class="alert alert-warning alert-vertical grid-cols-1 justify-items-stretch" role="status">
          <p class="font-bold"><%= t("api_credentials.secret_once") %></p>
          <fieldset class="fieldset w-full" data-controller="clipboard" data-clipboard-copied-value="<%= t('common.copied') %>">
            <legend class="fieldset-legend">API Secret</legend>
            <div class="join w-full">
              <input type="text" value="<%= @api_secret %>" readonly autocomplete="off" aria-label="API Secret" class="input join-item min-w-0 flex-1 font-mono" data-clipboard-target="source">
              <button type="button" class="btn join-item" data-clipboard-target="button" data-action="clipboard#copy"><%= t("common.copy") %></button>
            </div>
          </fieldset>
        </div>
      <% end %>

      <section class="card card-border border-base-300 bg-base-100 shadow-none">
        <div class="card-body p-5 sm:p-6">
          <h2 class="card-title text-base leading-[1.5]"><%= t("api_credentials.information") %></h2>
          <div class="mt-3 grid gap-4">
            <fieldset class="fieldset w-full" data-controller="clipboard" data-clipboard-copied-value="<%= t('common.copied') %>">
              <legend class="fieldset-legend">API key</legend>
              <div class="join w-full">
                <input type="text" value="<%= @api_credential.api_key %>" readonly autocomplete="off" aria-label="API key" class="input join-item min-w-0 flex-1 font-mono" data-clipboard-target="source">
                <button type="button" class="btn join-item" data-clipboard-target="button" data-action="clipboard#copy"><%= t("common.copy") %></button>
              </div>
            </fieldset>
            <dl>
            <div><dt class="text-sm text-neutral"><%= t("api_credentials.last_used") %></dt><dd><%= @api_credential.last_used_at ? l(@api_credential.last_used_at, format: :short) : t("common.unused") %></dd></div>
            </dl>
          </div>
          <div class="card-actions mt-4 justify-start">
            <%= link_to t("common.edit"), edit_api_credential_path(@api_credential), class: "btn btn-outline btn-rapid" %>
            <%= button_to t("api_credentials.revoke"), revoke_api_credential_path(@api_credential), method: :patch, class: "btn btn-warning btn-outline btn-rapid", data: { turbo_confirm: t("api_credentials.revoke_confirm") } %>
            <%= button_to t("common.delete"), api_credential_path(@api_credential), method: :delete, class: "btn btn-error btn-outline btn-rapid", data: { turbo_confirm: t("api_credentials.delete_confirm") } %>
          </div>
        </div>
      </section>
      <%= link_to t("api_credentials.back"), api_credentials_path, class: "btn btn-outline btn-rapid" %>
    </div>
  ERB

  create_file "app/views/api_credentials/new.html.erb", <<~ERB, force: true
    <% content_for :title, t("api_credentials.new") %>
    <div class="space-y-6">
      <header><p class="text-sm font-semibold text-primary"><%= t("api_credentials.eyebrow") %></p><h1 class="mt-1 text-2xl font-bold leading-[1.5]"><%= t("api_credentials.new") %></h1></header>
      <section class="card card-border border-base-300 bg-base-100 shadow-none"><div class="card-body p-5 sm:p-6"><%= render "form", api_credential: @api_credential %></div></section>
    </div>
  ERB

  create_file "app/views/api_credentials/edit.html.erb", <<~ERB, force: true
    <% content_for :title, t("api_credentials.edit") %>
    <div class="space-y-6">
      <header><p class="text-sm font-semibold text-primary"><%= t("api_credentials.eyebrow") %></p><h1 class="mt-1 text-2xl font-bold leading-[1.5]"><%= t("api_credentials.edit") %></h1></header>
      <section class="card card-border border-base-300 bg-base-100 shadow-none"><div class="card-body p-5 sm:p-6"><%= render "form", api_credential: @api_credential %></div></section>
    </div>
  ERB

  create_file "test/models/api_credential_test.rb", <<~RUBY, force: true
    require "test_helper"

    class ApiCredentialTest < ActiveSupport::TestCase
      test "stores only the digest and invalidates the revoked secret" do
        credential = users(:one).api_credentials.create!(name: "CLI")
        original_secret = credential.api_secret

        assert credential.authenticate_api_secret(original_secret)
        refute credential.authenticate_api_secret("invalid")
        refute_equal original_secret, credential.api_secret_digest

        replacement_secret = credential.revoke_api_secret!

        refute credential.authenticate_api_secret(original_secret)
        assert credential.authenticate_api_secret(replacement_secret)
        assert_equal credential.api_key, credential.reload.api_key
      end
    end
  RUBY

  create_file "test/controllers/api/api_credentials_controller_test.rb", <<~RUBY, force: true
    require "test_helper"

    class Api::ApiCredentialsControllerTest < ActionDispatch::IntegrationTest
      setup do
        @credential = users(:one).api_credentials.create!(name: "Primary")
        @api_secret = @credential.api_secret
      end

      test "requires a valid bearer token" do
        get api_api_credentials_url, headers: { "Authorization" => "Bearer invalid" }

        assert_response :unauthorized
      end

      test "does not expose HTML form routes" do
        helpers = Rails.application.routes.url_helpers

        assert_not_respond_to helpers, :new_api_api_credential_url
        assert_not_respond_to helpers, :edit_api_api_credential_url
      end

      test "manages only the authenticated users credentials" do
        other = users(:two).api_credentials.create!(name: "Other")

        get api_api_credentials_url, headers: authorization
        assert_response :success
        assert_equal [@credential.id], response.parsed_body.pluck("id")

        get api_api_credential_url(other), headers: authorization
        assert_response :not_found

        post api_api_credentials_url, params: { api_credential: { name: "Automation" } }, headers: authorization, as: :json
        assert_response :created
        assert response.parsed_body.fetch("api_secret").start_with?("ras_")
      end

      test "revoke returns a new secret and invalidates the old bearer token" do
        patch revoke_api_api_credential_url(@credential), headers: authorization
        assert_response :success
        replacement_secret = response.parsed_body.fetch("api_secret")

        get api_api_credentials_url, headers: authorization
        assert_response :unauthorized

        get api_api_credentials_url, headers: authorization(replacement_secret)
        assert_response :success
      end

      private
        def authorization(secret = @api_secret)
          { "Authorization" => "Bearer " + [@credential.api_key, secret].join(".") }
        end
    end
  RUBY

  web_test_authentication = if devise
    <<~RUBY
          include Devise::Test::IntegrationHelpers

          setup do
            @user = users(:one)
            sign_in @user
          end
    RUBY
  else
    <<~RUBY
          require "eth"

          setup do
            key = Eth::Key.new
            get session_nonce_url, headers: siwe_test_headers(key)
            nonce = response.parsed_body.fetch("nonce")
            message = Siwe::Message.new(
              domain: "www.example.com",
              address: key.address.to_s,
              uri: "http://www.example.com",
              chain_id: 1,
              nonce: nonce,
              issued_at: Time.current.iso8601,
              statement: Rails.configuration.x.application_identity.siwe_statement
            ).prepare_message
            post session_url, params: { message: message, signature: key.personal_sign(message) },
              headers: siwe_test_headers(key), as: :json
            @user = User.find_by!(wallet_address: key.address.to_s.downcase)
          end
    RUBY
  end
  create_file "test/controllers/api_credentials_controller_test.rb", <<~RUBY, force: true
    require "test_helper"

    class ApiCredentialsControllerTest < ActionDispatch::IntegrationTest
    #{web_test_authentication}
      test "creates updates revokes and deletes an API credential" do
        get api_credentials_url
        assert_response :success
        assert_select "table.table", count: 0

        assert_difference("ApiCredential.count", 1) do
          post api_credentials_url, params: { api_credential: { name: "CLI" } }
        end
        assert_response :created
        credential = @user.api_credentials.find_by!(name: "CLI")
        assert_select '.alert.alert-warning input[aria-label="API Secret"][readonly][value^="ras_"]', count: 1
        assert_select 'input[aria-label="API key"][readonly][value=?]', credential.api_key, count: 1
        assert_select 'button[data-action="clipboard#copy"]', text: I18n.t("common.copy"), count: 2
        assert_select ".alert.alert-warning", text: /Bearer token/, count: 0
        original_digest = credential.api_secret_digest

        patch api_credential_url(credential), params: { api_credential: { name: "Batch" } }
        assert_redirected_to api_credential_url(credential)

        patch revoke_api_credential_url(credential)
        assert_response :success
        assert_select '.alert.alert-warning input[aria-label="API Secret"][readonly][value^="ras_"]', count: 1
        refute_equal original_digest, credential.reload.api_secret_digest

        get api_credential_url(credential)
        assert_response :success
        assert_select ".alert.alert-warning", count: 0
        assert_select 'input[aria-label="API key"][readonly][value=?]', credential.api_key, count: 1

        get api_credentials_url
        assert_response :success
        assert_select 'table.table input[aria-label=?][readonly][value=?]', I18n.t("api_credentials.api_key_label", name: "Batch"), credential.api_key, count: 1
        assert_select 'table.table button[data-action="clipboard#copy"]', text: I18n.t("common.copy"), count: 1

        assert_difference("ApiCredential.count", -1) do
          delete api_credential_url(credential)
        end
        assert_redirected_to api_credentials_url
      end
    end
  RUBY
end

def configure_devise_views
  create_locale_pair("devise_views",
    ja: {
      "devise_views" => {
        "links" => { "sign_in" => "ログイン画面へ", "sign_up" => "アカウントを作成", "forgot_password" => "パスワードをお忘れですか？" },
        "sessions" => { "title" => "ログイン", "eyebrow" => "おかえりなさい", "description" => "登録済みのメールアドレスとパスワードを入力してください。", "remember_me" => "ログイン状態を保持する", "submit" => "ログイン" },
        "registrations" => { "new_title" => "アカウント作成", "new_eyebrow" => "はじめましょう", "new_description" => "利用を始めるためのアカウントを作成します。", "minimum_password" => "%{count}文字以上で入力してください。", "create" => "アカウントを作成", "edit_title" => "アカウント設定", "password_hint" => "変更しない場合は空欄にしてください。", "update" => "設定を更新", "delete_title" => "アカウントの削除", "delete_description" => "この操作は取り消せません。", "delete" => "アカウントを削除", "delete_confirm" => "本当に削除しますか？" },
        "passwords" => { "new_title" => "パスワード再設定", "new_eyebrow" => "パスワード再設定", "new_description" => "再設定用リンクをメールで送信します。", "send" => "再設定メールを送信", "edit_title" => "新しいパスワード", "edit_eyebrow" => "パスワードを選択", "change" => "パスワードを変更" },
        "mailer" => { "greeting" => "%{recipient}さん", "confirmation" => "以下のリンクから%{app_name}のメールアドレスを確認してください。", "confirm" => "メールアドレスを確認", "reset" => "以下のリンクから%{app_name}のパスワードを変更できます。", "reset_link" => "パスワードを変更", "unlock" => "以下のリンクから%{app_name}のアカウントロックを解除できます。", "unlock_link" => "アカウントロックを解除", "email_changed" => "%{app_name}のメールアドレスが変更されたことをお知らせします。", "password_changed" => "%{app_name}のパスワードが変更されたことをお知らせします。" }
      }
    },
    en: {
      "devise_views" => {
        "links" => { "sign_in" => "Back to sign in", "sign_up" => "Create an account", "forgot_password" => "Forgot your password?" },
        "sessions" => { "title" => "Sign in", "eyebrow" => "Welcome back", "description" => "Enter your registered email address and password.", "remember_me" => "Keep me signed in", "submit" => "Sign in" },
        "registrations" => { "new_title" => "Create account", "new_eyebrow" => "Get started", "new_description" => "Create an account to get started.", "minimum_password" => "Enter at least %{count} characters.", "create" => "Create account", "edit_title" => "Account settings", "password_hint" => "Leave blank if you do not want to change it.", "update" => "Update settings", "delete_title" => "Delete account", "delete_description" => "This action cannot be undone.", "delete" => "Delete account", "delete_confirm" => "Are you sure you want to delete your account?" },
        "passwords" => { "new_title" => "Reset password", "new_eyebrow" => "Password reset", "new_description" => "We will email you a password reset link.", "send" => "Send reset email", "edit_title" => "New password", "edit_eyebrow" => "Choose a password", "change" => "Change password" },
        "mailer" => { "greeting" => "Hello %{recipient}", "confirmation" => "Confirm your email address for %{app_name} using the link below.", "confirm" => "Confirm email address", "reset" => "Change your %{app_name} password using the link below.", "reset_link" => "Change password", "unlock" => "Unlock your %{app_name} account using the link below.", "unlock_link" => "Unlock account", "email_changed" => "This is a notice that your %{app_name} email address was changed.", "password_changed" => "This is a notice that your %{app_name} password was changed." }
      }
    }
  )

  create_file "app/views/devise/shared/_error_messages.html.erb", <<~ERB, force: true
    <% if resource.errors.any? %>
      <div class="alert alert-error mb-6" role="alert">
        <div>
          <h2 class="font-bold leading-[1.5]"><%= t("errors.messages.not_saved", count: resource.errors.count, resource: resource.class.model_name.human.downcase) %></h2>
          <ul class="mt-2 list-disc space-y-1 pl-5 text-sm">
            <% resource.errors.full_messages.each do |message| %>
              <li><%= message %></li>
            <% end %>
          </ul>
        </div>
      </div>
    <% end %>
  ERB

  create_file "app/views/devise/shared/_links.html.erb", <<~ERB, force: true
    <div class="divider"></div>
    <ul class="menu menu-sm w-full">
      <% if controller_name != "sessions" %>
        <li><%= link_to t("devise_views.links.sign_in"), new_session_path(resource_name) %></li>
      <% end %>
      <% if devise_mapping.registerable? && controller_name != "registrations" %>
        <li><%= link_to t("devise_views.links.sign_up"), new_registration_path(resource_name) %></li>
      <% end %>
      <% if devise_mapping.recoverable? && controller_name != "passwords" && controller_name != "registrations" %>
        <li><%= link_to t("devise_views.links.forgot_password"), new_password_path(resource_name) %></li>
      <% end %>
    </ul>
  ERB

  create_file "app/views/devise/sessions/new.html.erb", <<~ERB, force: true
    <% content_for :title, t("devise_views.sessions.title") %>
    <header class="mb-8">
      <p class="text-sm font-semibold text-primary"><%= t("devise_views.sessions.eyebrow") %></p>
      <h1 class="mt-2 text-2xl font-bold leading-[1.5]"><%= t("devise_views.sessions.title") %></h1>
      <p class="mt-2 text-sm text-neutral"><%= t("devise_views.sessions.description") %></p>
    </header>

    <%= form_for(resource, as: resource_name, url: session_path(resource_name), html: { class: "space-y-5" }) do |f| %>
      <fieldset class="fieldset">
        <legend class="fieldset-legend text-sm font-semibold leading-[1.5]"><%= f.label :email %></legend>
        <%= f.email_field :email, autofocus: true, autocomplete: "email", required: true, class: "input input-rapid w-full" %>
      </fieldset>
      <fieldset class="fieldset">
        <legend class="fieldset-legend text-sm font-semibold leading-[1.5]"><%= f.label :password %></legend>
        <%= f.password_field :password, autocomplete: "current-password", required: true, class: "input input-rapid w-full" %>
      </fieldset>
      <% if devise_mapping.rememberable? %>
        <label class="label cursor-pointer justify-start gap-3 text-base-content">
          <%= f.check_box :remember_me, class: "checkbox checkbox-sm" %>
          <span><%= t("devise_views.sessions.remember_me") %></span>
        </label>
      <% end %>
      <%= f.submit t("devise_views.sessions.submit"), class: "btn btn-primary btn-block btn-rapid hover:border-secondary hover:bg-secondary" %>
    <% end %>

    <%= render "devise/shared/links" %>
  ERB

  create_file "app/views/devise/registrations/new.html.erb", <<~ERB, force: true
    <% content_for :title, t("devise_views.registrations.new_title") %>
    <header class="mb-8">
      <p class="text-sm font-semibold text-primary"><%= t("devise_views.registrations.new_eyebrow") %></p>
      <h1 class="mt-2 text-2xl font-bold leading-[1.5]"><%= t("devise_views.registrations.new_title") %></h1>
      <p class="mt-2 text-sm text-neutral"><%= t("devise_views.registrations.new_description") %></p>
    </header>

    <%= form_for(resource, as: resource_name, url: registration_path(resource_name), html: { class: "space-y-5" }) do |f| %>
      <%= render "devise/shared/error_messages", resource: resource %>
      <fieldset class="fieldset">
        <legend class="fieldset-legend text-sm font-semibold leading-[1.5]"><%= f.label :email %></legend>
        <%= f.email_field :email, autofocus: true, autocomplete: "email", required: true, class: "input input-rapid w-full" %>
      </fieldset>
      <fieldset class="fieldset">
        <legend class="fieldset-legend text-sm font-semibold leading-[1.5]"><%= f.label :password %></legend>
        <%= f.password_field :password, autocomplete: "new-password", required: true, class: "input input-rapid w-full" %>
        <% if @minimum_password_length %>
          <p class="label text-sm text-neutral"><%= t("devise_views.registrations.minimum_password", count: @minimum_password_length) %></p>
        <% end %>
      </fieldset>
      <fieldset class="fieldset">
        <legend class="fieldset-legend text-sm font-semibold leading-[1.5]"><%= f.label :password_confirmation %></legend>
        <%= f.password_field :password_confirmation, autocomplete: "new-password", required: true, class: "input input-rapid w-full" %>
      </fieldset>
      <%= f.submit t("devise_views.registrations.create"), class: "btn btn-primary btn-block btn-rapid hover:border-secondary hover:bg-secondary" %>
    <% end %>

    <%= render "devise/shared/links" %>
  ERB

  create_file "app/views/devise/registrations/edit.html.erb", <<~ERB, force: true
    <% content_for :title, t("devise_views.registrations.edit_title") %>
    <div class="space-y-6">
      <header>
        <p class="text-sm font-semibold text-primary"><%= t("devise_views.registrations.edit_title") %></p>
        <h1 class="mt-2 text-2xl font-bold leading-[1.5]"><%= t("devise_views.registrations.edit_title") %></h1>
      </header>

      <section class="card card-border border-base-300 bg-base-100 shadow-none">
        <div class="card-body p-5 sm:p-6">
          <%= form_for(resource, as: resource_name, url: registration_path(resource_name), html: { method: :put, class: "space-y-5" }) do |f| %>
            <%= render "devise/shared/error_messages", resource: resource %>
            <fieldset class="fieldset">
              <legend class="fieldset-legend text-sm font-semibold leading-[1.5]"><%= f.label :email %></legend>
              <%= f.email_field :email, autofocus: true, autocomplete: "email", required: true, class: "input input-rapid w-full" %>
            </fieldset>
            <fieldset class="fieldset">
              <legend class="fieldset-legend text-sm font-semibold leading-[1.5]"><%= f.label :password %></legend>
              <%= f.password_field :password, autocomplete: "new-password", class: "input input-rapid w-full" %>
              <p class="label text-sm text-neutral"><%= t("devise_views.registrations.password_hint") %></p>
            </fieldset>
            <fieldset class="fieldset">
              <legend class="fieldset-legend text-sm font-semibold leading-[1.5]"><%= f.label :password_confirmation %></legend>
              <%= f.password_field :password_confirmation, autocomplete: "new-password", class: "input input-rapid w-full" %>
            </fieldset>
            <fieldset class="fieldset">
              <legend class="fieldset-legend text-sm font-semibold leading-[1.5]"><%= f.label :current_password %></legend>
              <%= f.password_field :current_password, autocomplete: "current-password", required: true, class: "input input-rapid w-full" %>
            </fieldset>
            <%= f.submit t("devise_views.registrations.update"), class: "btn btn-primary btn-block btn-rapid hover:border-secondary hover:bg-secondary" %>
          <% end %>
        </div>
      </section>

      <section class="card card-border border-error bg-base-100 shadow-none">
        <div class="card-body p-5 sm:p-6">
          <h2 class="card-title text-base leading-[1.5]"><%= t("devise_views.registrations.delete_title") %></h2>
          <p class="text-sm text-neutral"><%= t("devise_views.registrations.delete_description") %></p>
          <div class="card-actions mt-2 justify-start">
            <%= button_to t("devise_views.registrations.delete"), registration_path(resource_name), method: :delete, class: "btn btn-outline btn-error btn-rapid", data: { turbo_confirm: t("devise_views.registrations.delete_confirm") } %>
          </div>
        </div>
      </section>
    </div>
  ERB

  create_file "app/views/devise/passwords/new.html.erb", <<~ERB, force: true
    <% content_for :title, t("devise_views.passwords.new_title") %>
    <header class="mb-8">
      <p class="text-sm font-semibold text-primary"><%= t("devise_views.passwords.new_eyebrow") %></p>
      <h1 class="mt-2 text-2xl font-bold leading-[1.5]"><%= t("devise_views.passwords.new_title") %></h1>
      <p class="mt-2 text-sm text-neutral"><%= t("devise_views.passwords.new_description") %></p>
    </header>

    <%= form_for(resource, as: resource_name, url: password_path(resource_name), html: { method: :post, class: "space-y-5" }) do |f| %>
      <%= render "devise/shared/error_messages", resource: resource %>
      <fieldset class="fieldset">
        <legend class="fieldset-legend text-sm font-semibold leading-[1.5]"><%= f.label :email %></legend>
        <%= f.email_field :email, autofocus: true, autocomplete: "email", required: true, class: "input input-rapid w-full" %>
      </fieldset>
      <%= f.submit t("devise_views.passwords.send"), class: "btn btn-primary btn-block btn-rapid hover:border-secondary hover:bg-secondary" %>
    <% end %>

    <%= render "devise/shared/links" %>
  ERB

  create_file "app/views/devise/passwords/edit.html.erb", <<~ERB, force: true
    <% content_for :title, t("devise_views.passwords.edit_title") %>
    <header class="mb-8">
      <p class="text-sm font-semibold text-primary"><%= t("devise_views.passwords.edit_eyebrow") %></p>
      <h1 class="mt-2 text-2xl font-bold leading-[1.5]"><%= t("devise_views.passwords.edit_title") %></h1>
    </header>

    <%= form_for(resource, as: resource_name, url: password_path(resource_name), html: { method: :put, class: "space-y-5" }) do |f| %>
      <%= render "devise/shared/error_messages", resource: resource %>
      <%= f.hidden_field :reset_password_token %>
      <fieldset class="fieldset">
        <legend class="fieldset-legend text-sm font-semibold leading-[1.5]"><%= f.label :password %></legend>
        <%= f.password_field :password, autofocus: true, autocomplete: "new-password", required: true, class: "input input-rapid w-full" %>
      </fieldset>
      <fieldset class="fieldset">
        <legend class="fieldset-legend text-sm font-semibold leading-[1.5]"><%= f.label :password_confirmation %></legend>
        <%= f.password_field :password_confirmation, autocomplete: "new-password", required: true, class: "input input-rapid w-full" %>
      </fieldset>
      <%= f.submit t("devise_views.passwords.change"), class: "btn btn-primary btn-block btn-rapid hover:border-secondary hover:bg-secondary" %>
    <% end %>

    <%= render "devise/shared/links" %>
  ERB

  mailer_prefix = '<p><%= t("devise_views.mailer.greeting", recipient: @email) %></p>'
  create_file "app/views/devise/mailer/confirmation_instructions.html.erb", <<~ERB, force: true
    #{mailer_prefix}
    <p><%= t("devise_views.mailer.confirmation", app_name: Rails.configuration.x.application_identity.app_name) %></p>
    <p><%= link_to t("devise_views.mailer.confirm"), confirmation_url(@resource, confirmation_token: @token) %></p>
  ERB
  create_file "app/views/devise/mailer/reset_password_instructions.html.erb", <<~ERB, force: true
    #{mailer_prefix}
    <p><%= t("devise_views.mailer.reset", app_name: Rails.configuration.x.application_identity.app_name) %></p>
    <p><%= link_to t("devise_views.mailer.reset_link"), edit_password_url(@resource, reset_password_token: @token) %></p>
  ERB
  create_file "app/views/devise/mailer/unlock_instructions.html.erb", <<~ERB, force: true
    #{mailer_prefix}
    <p><%= t("devise_views.mailer.unlock", app_name: Rails.configuration.x.application_identity.app_name) %></p>
    <p><%= link_to t("devise_views.mailer.unlock_link"), unlock_url(@resource, unlock_token: @token) %></p>
  ERB
  create_file "app/views/devise/mailer/email_changed.html.erb", <<~ERB, force: true
    #{mailer_prefix}
    <p><%= t("devise_views.mailer.email_changed", app_name: Rails.configuration.x.application_identity.app_name) %></p>
  ERB
  create_file "app/views/devise/mailer/password_change.html.erb", <<~ERB, force: true
    #{mailer_prefix}
    <p><%= t("devise_views.mailer.password_changed", app_name: Rails.configuration.x.application_identity.app_name) %></p>
  ERB
end

def configure_default_views
  devise = VALUES.fetch("account_authentication") == "devise"
  pwa_enabled = VALUES.fetch("pwa") == "use"
  web_push_enabled = VALUES.fetch("web_push") == "use"
  job_operations_enabled = VALUES.fetch("job_operations") == "enable"
  maintenance_tasks_enabled = VALUES.fetch("maintenance_tasks") == "enable"
  api_enabled = VALUES.fetch("api") == "enable"
  profile_features = VALUES.fetch("profile_features")
  profile_enabled = profile_features.any?
  avatar_enabled = profile_features.include?("avatar")
  screen_name_enabled = profile_features.include?("screen_name")
  display_name_enabled = profile_features.include?("display_name")
  account_navigation_count = 2 + (profile_enabled ? 1 : 0) + (api_enabled ? 1 : 0) + (web_push_enabled ? 1 : 0)
  account_page_description = if profile_enabled
    '<%= t("accounts.show.description_with_profile") %>'
  else
    '<%= t("accounts.show.description") %>'
  end
  account_page_action = if profile_enabled
    '<%= t("accounts.show.action_with_profile") %>'
  else
    '<%= t("accounts.show.action") %>'
  end
  home_action = if devise
    '<%= link_to t("home.start_devise"), new_user_registration_path, class: "btn btn-primary btn-rapid px-6 hover:border-secondary hover:bg-secondary" %>'
  else
    '<%= link_to t("home.start_wallet"), new_session_path, class: "btn btn-primary btn-rapid px-6 hover:border-secondary hover:bg-secondary" %>'
  end
  account_navigation_items = <<~ERB
    <li>
      <%= link_to application_routes.account_path, class: ("menu-active" if current_page?(application_routes.account_path)), aria: { current: ("page" if current_page?(application_routes.account_path)) } do %>
        <svg xmlns="http://www.w3.org/2000/svg" class="size-5" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" aria-hidden="true" data-slot="icon">
          <path stroke-linecap="round" stroke-linejoin="round" d="m2.25 12 8.954-8.955a1.125 1.125 0 0 1 1.591 0L21.75 12M4.5 9.75v10.125c0 .621.504 1.125 1.125 1.125H9.75v-4.875c0-.621.504-1.125 1.125-1.125h2.25c.621 0 1.125.504 1.125 1.125V21h4.125c.621 0 1.125-.504 1.125-1.125V9.75" />
        </svg>
        <%= t("navigation.dashboard") %>
      <% end %>
    </li>
  ERB
  if profile_enabled
    account_navigation_items += <<~ERB
      <li>
        <%= link_to application_routes.profile_path, class: ("menu-active" if controller_path == "profiles"), aria: { current: ("page" if controller_path == "profiles") } do %>
          <svg xmlns="http://www.w3.org/2000/svg" class="size-5" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" aria-hidden="true" data-slot="icon">
            <path stroke-linecap="round" stroke-linejoin="round" d="M17.982 18.725A7.488 7.488 0 0 0 12 15.75a7.488 7.488 0 0 0-5.982 2.975m11.963 0a9 9 0 1 0-11.963 0m11.963 0A8.966 8.966 0 0 1 12 21a8.966 8.966 0 0 1-5.982-2.275M15 9.75a3 3 0 1 1-6 0 3 3 0 0 1 6 0Z" />
          </svg>
          <%= t("navigation.profile") %>
        <% end %>
      </li>
    ERB
  end
  account_settings_path = devise ? "application_routes.edit_user_registration_path" : "application_routes.edit_account_path"
  account_navigation_items += <<~ERB
    <li>
      <%= link_to #{account_settings_path}, class: ("menu-active" if current_page?(#{account_settings_path})), aria: { current: ("page" if current_page?(#{account_settings_path})) } do %>
        <svg xmlns="http://www.w3.org/2000/svg" class="size-5" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" aria-hidden="true" data-slot="icon">
          <path stroke-linecap="round" stroke-linejoin="round" d="M9.594 3.94c.09-.542.56-.94 1.11-.94h2.593c.55 0 1.02.398 1.11.94l.213 1.281c.063.374.313.686.645.87.074.04.147.083.22.127.325.196.72.257 1.075.124l1.217-.456a1.125 1.125 0 0 1 1.37.49l1.296 2.247a1.125 1.125 0 0 1-.26 1.431l-1.003.827c-.293.241-.438.613-.43.992a7.723 7.723 0 0 1 0 .255c-.008.378.137.75.43.991l1.004.827c.424.35.534.955.26 1.43l-1.298 2.247a1.125 1.125 0 0 1-1.369.491l-1.217-.456c-.355-.133-.75-.072-1.076.124a6.47 6.47 0 0 1-.22.128c-.331.183-.581.495-.644.869l-.213 1.281c-.09.543-.56.94-1.11.94h-2.594c-.55 0-1.019-.398-1.11-.94l-.213-1.281c-.062-.374-.312-.686-.644-.87a6.52 6.52 0 0 1-.22-.127c-.325-.196-.72-.257-1.076-.124l-1.217.456a1.125 1.125 0 0 1-1.369-.49l-1.297-2.247a1.125 1.125 0 0 1 .26-1.431l1.004-.827c.292-.24.437-.613.43-.991a6.932 6.932 0 0 1 0-.255c.007-.38-.138-.751-.43-.992l-1.004-.827a1.125 1.125 0 0 1-.26-1.43l1.297-2.247a1.125 1.125 0 0 1 1.37-.491l1.216.456c.356.133.751.072 1.076-.124.072-.044.146-.086.22-.128.332-.183.582-.495.644-.869l.214-1.28Z" />
          <path stroke-linecap="round" stroke-linejoin="round" d="M15 12a3 3 0 1 1-6 0 3 3 0 0 1 6 0Z" />
        </svg>
        <%= t("navigation.account_settings") %>
      <% end %>
    </li>
  ERB
  if web_push_enabled
    account_navigation_items += <<~ERB
      <li>
        <%= link_to application_routes.notification_path, class: ("menu-active" if controller_path == "notifications"), aria: { current: ("page" if controller_path == "notifications") } do %>
          <svg xmlns="http://www.w3.org/2000/svg" class="size-5" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" aria-hidden="true" data-slot="icon">
            <path stroke-linecap="round" stroke-linejoin="round" d="M14.857 17.082a23.848 23.848 0 0 0 5.454-1.31A8.967 8.967 0 0 1 18 9.75V9A6 6 0 0 0 6 9v.75a8.967 8.967 0 0 1-2.312 6.022c1.733.64 3.56 1.085 5.455 1.31m5.714 0a24.255 24.255 0 0 1-5.714 0m5.714 0a3 3 0 1 1-5.714 0" />
          </svg>
          <%= t("navigation.notifications") %>
        <% end %>
      </li>
    ERB
  end
  if api_enabled
    account_navigation_items += <<~ERB
      <li>
        <%= link_to application_routes.api_credentials_path, class: ("menu-active" if controller_path == "api_credentials"), aria: { current: ("page" if controller_path == "api_credentials") } do %>
          <svg xmlns="http://www.w3.org/2000/svg" class="size-5" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" aria-hidden="true" data-slot="icon">
            <path stroke-linecap="round" stroke-linejoin="round" d="M17.25 6.75 22.5 12l-5.25 5.25m-10.5 0L1.5 12l5.25-5.25m7.5-3-4.5 16.5" />
          </svg>
          <%= t("navigation.api_credentials") %>
        <% end %>
      </li>
    ERB
  end
  admin_navigation_items = <<~ERB
      <li>
        <%= link_to application_routes.admin_users_path, class: ("menu-active" if controller_path.in?(%w[admin/users admin/user_roles])), aria: { current: ("page" if controller_path.in?(%w[admin/users admin/user_roles])) } do %>
          <svg xmlns="http://www.w3.org/2000/svg" class="size-5" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" aria-hidden="true" data-slot="icon">
            <path stroke-linecap="round" stroke-linejoin="round" d="M9 12.75 11.25 15 15 9.75m6-3c0 7.142-3.75 12-9 13.5C6.75 18.75 3 13.892 3 6.75c3.75 0 7.5-1.5 9-4.5 1.5 3 5.25 4.5 9 4.5Z" />
          </svg>
          <%= application_translate("navigation.users") %>
        <% end %>
      </li>
      <li>
        <%= link_to application_routes.admin_pages_path, class: ("menu-active" if controller_path == "admin/pages"), aria: { current: ("page" if controller_path == "admin/pages") } do %>
          <svg xmlns="http://www.w3.org/2000/svg" class="size-5" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" aria-hidden="true" data-slot="icon">
            <path stroke-linecap="round" stroke-linejoin="round" d="M19.5 14.25v-2.625a3.375 3.375 0 0 0-3.375-3.375h-1.5A1.125 1.125 0 0 1 13.5 7.125v-1.5A3.375 3.375 0 0 0 10.125 2.25H8.25m0 12.75h7.5m-7.5 3h4.5M10.5 2.25H5.625c-.621 0-1.125.504-1.125 1.125v17.25c0 .621.504 1.125 1.125 1.125h12.75c.621 0 1.125-.504 1.125-1.125v-8.25a10.5 10.5 0 0 0-9-10.125Z" />
          </svg>
          <%= application_translate("navigation.pages") %>
        <% end %>
      </li>
      <li>
        <%= link_to application_routes.admin_faqs_path, class: ("menu-active" if controller_path == "admin/faqs"), aria: { current: ("page" if controller_path == "admin/faqs") } do %>
          <svg xmlns="http://www.w3.org/2000/svg" class="size-5" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" aria-hidden="true" data-slot="icon">
            <path stroke-linecap="round" stroke-linejoin="round" d="M8.625 9.75a3.375 3.375 0 1 1 5.775 2.387c-.938.938-1.9 1.424-1.9 2.613M12 18h.008v.008H12V18Zm9-6a9 9 0 1 1-18 0 9 9 0 0 1 18 0Z" />
          </svg>
          <%= application_translate("navigation.faqs") %>
        <% end %>
      </li>
      <li>
        <%= link_to application_routes.edit_admin_footer_setting_path, class: ("menu-active" if controller_path == "admin/footer_settings"), aria: { current: ("page" if controller_path == "admin/footer_settings") } do %>
          <svg xmlns="http://www.w3.org/2000/svg" class="size-5" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" aria-hidden="true" data-slot="icon">
            <path stroke-linecap="round" stroke-linejoin="round" d="M13.19 8.688a4.5 4.5 0 0 1 1.242 7.244l-4.5 4.5a4.5 4.5 0 0 1-6.364-6.364l1.757-1.757m13.35-.622 1.757-1.757a4.5 4.5 0 0 0-6.364-6.364l-4.5 4.5a4.5 4.5 0 0 0 1.242 7.244" />
          </svg>
          <%= application_translate("content_management.admin.footer_settings.title") %>
        <% end %>
      </li>
  ERB
  if job_operations_enabled
    admin_navigation_items += <<~ERB
      <li>
        <%= link_to application_routes.admin_jobs_path, class: ("menu-active" if controller_path.start_with?("mission_control/jobs/")), aria: { current: ("page" if controller_path.start_with?("mission_control/jobs/")) } do %>
          <svg xmlns="http://www.w3.org/2000/svg" class="size-5" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" aria-hidden="true" data-slot="icon">
            <path stroke-linecap="round" stroke-linejoin="round" d="M3.75 12h16.5m-16.5 3.75h16.5M3.75 18h16.5M4.5 6.75h15a.75.75 0 0 1 .75.75v.75a.75.75 0 0 1-.75.75h-15a.75.75 0 0 1-.75-.75V7.5a.75.75 0 0 1 .75-.75Z" />
          </svg>
          <%= application_translate("navigation.job_operations") %>
        <% end %>
      </li>
    ERB
  end
  if maintenance_tasks_enabled
    admin_navigation_items += <<~ERB
      <li>
        <%= link_to application_routes.admin_maintenance_tasks_path, class: ("menu-active" if controller_path.start_with?("maintenance_tasks/")), aria: { current: ("page" if controller_path.start_with?("maintenance_tasks/")) } do %>
          <svg xmlns="http://www.w3.org/2000/svg" class="size-5" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" aria-hidden="true" data-slot="icon">
            <path stroke-linecap="round" stroke-linejoin="round" d="M11.42 15.17 17.25 21A2.652 2.652 0 0 0 21 17.25l-5.877-5.877M11.42 15.17l2.496-3.03c.317-.384.74-.626 1.208-.766m-3.704 3.796-4.655 5.653a2.548 2.548 0 1 1-3.586-3.586l6.837-5.63m5.108-.233c.55-.164 1.163-.188 1.743-.14a4.5 4.5 0 0 0 4.486-6.336l-3.276 3.277a3.004 3.004 0 0 1-2.25-2.25l3.276-3.276a4.5 4.5 0 0 0-6.336 4.486c.091 1.076-.071 2.264-.904 2.95l-.102.085m-1.745 2.437L5.909 7.5H4.5L2.25 3.75l1.5-1.5L7.5 4.5v1.409l4.26 4.26m-1.745 2.437 1.745-2.437m6.615 8.206L15.75 15.75M4.867 19.125h.008v.008h-.008v-.008Z" />
          </svg>
          <%= application_translate("navigation.maintenance_tasks") %>
        <% end %>
      </li>
    ERB
  end
  account_navigation_for_layout = account_navigation_items.lines.map { |line| "                #{line}" }.join
  account_navigation_for_dropdown = account_navigation_items.lines.map { |line| "          #{line}" }.join
  admin_navigation_for_layout = admin_navigation_items.lines.map { |line| "                #{line}" }.join
  signed_in_condition = devise ? "user_signed_in?" : "authenticated?"
  admin_controller_conditions = ['controller_path.start_with?("admin/")']
  admin_controller_conditions << 'controller_path.start_with?("mission_control/jobs/")' if job_operations_enabled
  admin_controller_conditions << 'controller_path.start_with?("maintenance_tasks/")' if maintenance_tasks_enabled
  admin_controller_condition = admin_controller_conditions.join(" || ")
  profile_owner = devise ? "current_user.profile" : "Current.user.profile"
  logout_path = devise ? "application_routes.destroy_user_session_path" : "application_routes.session_path"
  guest_desktop_navigation = if devise
    <<~ERB
      <%= link_to t("navigation.sign_in"), application_routes.new_user_session_path, class: "btn btn-ghost btn-rapid" %>
      <%= link_to t("navigation.sign_up"), application_routes.new_user_registration_path, class: "btn btn-primary btn-outline btn-rapid" %>
    ERB
  else
    <<~ERB
      <%= link_to t("navigation.sign_in"), application_routes.new_session_path, class: "btn btn-ghost btn-rapid" %>
    ERB
  end
  guest_mobile_navigation = if devise
    <<~ERB
      <li><%= link_to t("navigation.sign_in"), application_routes.new_user_session_path %></li>
      <li><%= link_to t("navigation.sign_up"), application_routes.new_user_registration_path %></li>
    ERB
  else
    <<~ERB
      <li><%= link_to t("navigation.sign_in"), application_routes.new_session_path %></li>
    ERB
  end
  profile_identity = if display_name_enabled || screen_name_enabled
    display_name = if display_name_enabled
      <<~ERB
        <% if #{profile_owner}.display_name.present? %>
          <strong class="block"><%= #{profile_owner}.display_name %></strong>
        <% end %>
      ERB
    else
      ""
    end
    screen_name = if screen_name_enabled
      <<~ERB
        <% if #{profile_owner}.screen_name.present? %>
          <span class="block text-neutral">@<%= #{profile_owner}.screen_name %></span>
        <% end %>
      ERB
    else
      ""
    end
    condition = [
      ("#{profile_owner}.display_name.present?" if display_name_enabled),
      ("#{profile_owner}.screen_name.present?" if screen_name_enabled)
    ].compact.join(" || ")
    <<~ERB
      <% if #{condition} %>
        <li class="menu-title">
          <span>
      #{display_name.lines.map { |line| "      #{line}" }.join}#{screen_name.lines.map { |line| "      #{line}" }.join}    </span>
        </li>
      <% end %>
    ERB
  else
    ""
  end
  account_menu_trigger = if avatar_enabled
    <<~ERB
      <summary class="btn btn-circle btn-ghost" aria-label="<%= t('navigation.open_account_menu') %>">
        <div class="avatar">
          <div class="w-10 rounded-full">
            <%= profile_avatar(#{profile_owner}, size: 40, alt: "") %>
          </div>
        </div>
      </summary>
    ERB
  else
    <<~ERB
      <summary class="btn btn-ghost">
        <svg xmlns="http://www.w3.org/2000/svg" class="size-5" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" aria-hidden="true" data-slot="icon">
          <path stroke-linecap="round" stroke-linejoin="round" d="M3.75 6.75h16.5M3.75 12h16.5m-16.5 5.25h16.5" />
        </svg>
        <span><%= t("common.menu") %></span>
      </summary>
    ERB
  end
  layout_method = if devise
    'devise_controller? ? (controller_name == "registrations" && %w[edit update].include?(action_name) ? "account" : "authentication") : "application"'
  else
    'controller_path == "sessions" ? "authentication" : "application"'
  end
  wallet_script = devise ? "" : "    <script src=\"/vendor/web3-4.16.0.min.js\" defer></script>\n"
  pwa_head = if pwa_enabled
    <<~ERB
      <meta name="theme-color" content="#3ea8ff">
      <%= tag.link rel: "manifest", href: application_routes.pwa_manifest_path(format: :json) %>
    ERB
  else
    ""
  end
  body_controllers = []
  body_controllers << "pwa" if pwa_enabled
  body_controllers << "push-subscription" if web_push_enabled
  body_data_attributes = body_controllers.empty? ? "" : %( data-controller="#{body_controllers.join(' ')}")
  if web_push_enabled
    body_data_attributes += <<~ERB.chomp
       data-push-subscription-authenticated-value="<%= #{signed_in_condition} %>"
       data-push-subscription-public-key-url-value="<%= application_routes.vapid_public_key_push_subscription_path %>"
       data-push-subscription-subscription-url-value="<%= application_routes.push_subscription_path %>"
       data-push-subscription-test-url-value="<%= application_routes.test_push_subscription_path %>"
       data-push-subscription-messages-value="<%= t('web_push.client').to_json %>"
    ERB
  end

  inject_into_class "app/controllers/application_controller.rb", "ApplicationController", <<~RUBY
      layout :application_layout

      def application_layout
        #{layout_method}
      end
      private :application_layout

  RUBY

  home_authentication = devise ? "" : "  allow_unauthenticated_access only: :index\n\n"
  create_file "app/controllers/home_controller.rb", <<~RUBY, force: true
    class HomeController < ApplicationController
    #{home_authentication}  def index; end
    end
  RUBY

  accounts_controller = if devise
    <<~RUBY
      class AccountsController < ApplicationController
        layout "account"
        before_action :authenticate_user!

        def show; end
      end
    RUBY
  else
    <<~RUBY
      class AccountsController < ApplicationController
        layout "account"

        def show; end

        def edit; end

        def destroy
          user = Current.user
          if user.last_admin?
            redirect_to edit_account_path, alert: I18n.t("accounts.destroy.last_admin"), status: :see_other
            return
          end

          user.destroy!
          cookies.delete(:session_id)
          Current.session = nil
          redirect_to root_path, notice: I18n.t("accounts.destroy.notice"), status: :see_other
        end
      end
    RUBY
  end
  create_file "app/controllers/accounts_controller.rb", accounts_controller, force: true

  create_file "app/helpers/application_helper.rb", <<~RUBY, force: true
    module ApplicationHelper
      def application_identity
        Rails.configuration.x.application_identity
      end

      def application_routes
        Rails.application.routes.url_helpers
      end

      def document_title
        page_title = content_for(:title).presence
        [page_title, application_identity.app_name].compact.join(" | ")
      end

      def canonical_url
        application_identity.canonical_url(request.path)
      end

      def application_translate(key, **options)
        I18n.backend.translate(application_identity.default_locale, key, **options)
      end
    end
  RUBY

  route 'root "home#index"'
  route devise ? "resource :account, only: :show" : "resource :account, only: %i[show edit destroy]"

  create_file "app/views/layouts/application.html.erb", <<~ERB, force: true
    <!DOCTYPE html>
    <html lang="<%= I18n.locale %>" data-theme="rapid-rails">
      <head>
        <title><%= document_title %></title>
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <meta name="description" content="<%= t('meta.description', app_name: application_identity.app_name) %>">
        <link rel="canonical" href="<%= canonical_url %>">
        <meta property="og:type" content="website">
        <meta property="og:site_name" content="<%= application_identity.app_name %>">
        <meta property="og:title" content="<%= document_title %>">
        <meta property="og:description" content="<%= t('meta.description', app_name: application_identity.app_name) %>">
        <meta property="og:url" content="<%= canonical_url %>">
        <meta property="og:locale" content="<%= I18n.locale == :ja ? 'ja_JP' : 'en_US' %>">
        <%= csrf_meta_tags %>
        <%= csp_meta_tag %>
    #{pwa_head.lines.map { |line| "    #{line}" }.join}        <%= yield :head %>
        <%= stylesheet_link_tag "tailwind", "data-turbo-track": "reload" %>
        <%= stylesheet_link_tag :app, "data-turbo-track": "reload" %>
        <%= stylesheet_link_tag "lexxy", "data-turbo-track": "reload" %>
    #{wallet_script}    <%= content_for?(:javascript_importmap) ? yield(:javascript_importmap) : javascript_importmap_tags %>
      </head>
      <body class="min-h-screen bg-base-100 text-base-content antialiased" data-layout="application"#{body_data_attributes}>
        <div class="flex min-h-screen flex-col">
          <%= render "shared/header" %>
          <main class="flex-1 bg-base-200">
            <%= render "shared/flash" %>
            <%= content_for?(:content) ? yield(:content) : yield %>
          </main>
          <%= render "shared/footer" %>
        </div>
      </body>
    </html>
  ERB

  create_file "app/views/layouts/authentication.html.erb", <<~ERB, force: true
    <% content_for :content do %>
      <section class="hero mx-auto w-full max-w-md px-5 py-10 md:py-16" data-layout="authentication">
        <div class="hero-content w-full max-w-none p-0">
          <div class="card card-border w-full border-base-300 bg-base-100 shadow-none">
            <div class="card-body p-6 sm:p-8">
              <%= yield %>
            </div>
          </div>
        </div>
      </section>
    <% end %>
    <%= render template: "layouts/application" %>
  ERB

  create_file "app/views/layouts/account.html.erb", <<~ERB, force: true
    <% content_for :content do %>
      <div class="mx-auto grid w-full max-w-6xl gap-6 px-5 py-8 min-[961px]:grid-cols-[220px_minmax(0,1fr)] min-[961px]:py-12" data-layout="account">
        <aside class="h-fit">
          <nav aria-label="<%= t('navigation.account_menu') %>">
            <ul class="menu w-full rounded-box bg-base-100">
              <li class="menu-title"><span><%= t("navigation.dashboard") %></span></li>
    #{account_navigation_for_layout}          </ul>
          </nav>
        </aside>
        <div class="min-w-0"><%= yield %></div>
      </div>
    <% end %>
    <%= render template: "layouts/application" %>
  ERB

  create_file "app/views/shared/_admin_navigation.html.erb", admin_navigation_items, force: true
  create_file "app/views/layouts/admin.html.erb", <<~ERB, force: true
    <% content_for :content do %>
      <div class="mx-auto grid w-full max-w-6xl gap-6 px-5 py-8 min-[961px]:grid-cols-[220px_minmax(0,1fr)] min-[961px]:py-12" data-layout="admin"#{maintenance_tasks_enabled ? ' data-maintenance-tasks-shell="<%= controller_path.start_with?("maintenance_tasks/") %>"' : ""}>
        <aside class="h-fit">
          <nav aria-label="<%= application_translate('navigation.admin_menu') %>">
            <ul class="menu w-full rounded-box bg-base-100">
              <li class="menu-title"><span><%= application_translate("navigation.admin") %></span></li>
    #{admin_navigation_for_layout}          </ul>
          </nav>
        </aside>
        <div class="min-w-0"><%= content_for?(:admin_content) ? yield(:admin_content) : yield %></div>
      </div>
    <% end %>
    <%= render template: "layouts/application" %>
  ERB

  create_file "app/views/shared/_header.html.erb", <<~ERB, force: true
    <header class="border-b border-base-300 bg-base-100">
      <nav class="navbar mx-auto w-full max-w-6xl px-5" aria-label="<%= t('navigation.main') %>">
        <div class="navbar-start">
          <%= link_to application_identity.app_name, application_routes.root_path, class: "inline-flex min-h-11 items-center text-lg font-bold text-primary" %>
        </div>
        <% if #{signed_in_condition} %>
          <div class="navbar-end">
            <details class="dropdown dropdown-end dropdown-hover">
    #{account_menu_trigger.lines.map { |line| "          #{line}" }.join}          <ul class="menu menu-sm dropdown-content z-10 mt-3 w-72 rounded-box bg-base-100 shadow-elevation-2">
    #{profile_identity.lines.map { |line| "            #{line}" }.join}            <% if #{admin_controller_condition} %>
                <li class="menu-title"><span><%= application_translate("navigation.admin") %></span></li>
                <%= render "shared/admin_navigation" %>
              <% else %>
    #{account_navigation_for_dropdown}            <% end %>
              <li class="border-t border-base-300"><%= link_to t("navigation.sign_out"), #{logout_path}, data: { turbo_method: :delete } %></li>
              </ul>
            </details>
          </div>
        <% else %>
          <div class="navbar-end hidden items-center gap-1 min-[961px]:flex">
    #{guest_desktop_navigation.lines.map { |line| "        #{line}" }.join}      </div>
          <div class="navbar-end min-[961px]:hidden">
            <details class="dropdown dropdown-end">
              <summary class="btn btn-ghost"><%= t("common.menu") %></summary>
              <ul class="menu menu-sm dropdown-content z-10 mt-3 w-52 rounded-box bg-base-100 shadow-elevation-2">
    #{guest_mobile_navigation.lines.map { |line| "            #{line}" }.join}          </ul>
            </details>
          </div>
        <% end %>
      </nav>
    </header>
  ERB

  create_file "app/views/shared/_flash.html.erb", <<~ERB, force: true
    <% if notice.present? %>
      <div class="mx-auto w-full max-w-[820px] px-5 pt-5">
        <div class="alert alert-success" role="status"><span><%= notice %></span></div>
      </div>
    <% end %>
    <% if alert.present? %>
      <div class="mx-auto w-full max-w-[820px] px-5 pt-5">
        <div class="alert alert-error" role="alert"><span><%= alert %></span></div>
      </div>
    <% end %>
  ERB

  create_file "app/views/shared/_footer.html.erb", <<~ERB, force: true
    <% external_links_configured = footer_setting.x_url.present? || footer_setting.github_url.present? %>
    <div class="border-t border-base-300 bg-base-100">
      <footer class="footer footer-vertical mx-auto w-full max-w-6xl px-5 py-8 text-sm sm:footer-horizontal">
        <nav>
          <h2 class="footer-title leading-[1.5]"><%= t("footer.about_section") %></h2>
          <%= link_to t("footer.about", app_name: application_identity.app_name), application_routes.about_path, class: "link link-hover" %>
          <%= link_to t("footer.company"), application_routes.corp_path, class: "link link-hover" %>
        </nav>
        <nav>
          <h2 class="footer-title leading-[1.5]"><%= t("footer.guides_section") %></h2>
          <%= link_to t("footer.manual"), application_routes.manual_path, class: "link link-hover" %>
          <%= link_to t("footer.faq"), application_routes.faq_path, class: "link link-hover" %>
        </nav>
        <% if external_links_configured %>
          <nav>
            <h2 class="footer-title leading-[1.5]"><%= t("footer.links_section") %></h2>
            <% if footer_setting.x_url.present? %>
              <%= link_to "X(Twitter)", footer_setting.x_url, class: "link link-hover", target: "_blank", rel: "noopener noreferrer" %>
            <% end %>
            <% if footer_setting.github_url.present? %>
              <%= link_to "GitHub", footer_setting.github_url, class: "link link-hover", target: "_blank", rel: "noopener noreferrer" %>
            <% end %>
          </nav>
        <% end %>
        <nav>
          <h2 class="footer-title leading-[1.5]">Legal</h2>
          <%= link_to t("footer.terms"), application_routes.terms_path, class: "link link-hover" %>
          <%= link_to t("footer.privacy"), application_routes.privacy_path, class: "link link-hover" %>
          <%= link_to t("footer.transaction_law"), application_routes.transaction_law_path, class: "link link-hover" %>
        </nav>
      </footer>
    </div>
  ERB

  create_file "app/views/home/index.html.erb", <<~ERB, force: true
    <% content_for :title, t("home.title") %>
    <div class="mx-auto w-full max-w-[820px] space-y-8 px-5 py-10 md:py-14">
      <section class="hero rounded-box border border-base-300 bg-base-100">
        <div class="hero-content w-full max-w-none flex-col items-start gap-6 p-6 sm:p-8 md:p-10">
          <span class="badge badge-outline"><%= t("home.badge") %></span>
          <div>
            <h1 class="text-[1.75rem] font-bold leading-[1.5] min-[961px]:text-[2.4rem]"><%= t("home.heading") %></h1>
            <p class="mt-5 max-w-2xl text-neutral"><%= t("home.description") %></p>
          </div>
          <div class="flex flex-col gap-3 sm:flex-row">
            #{home_action}
            <%= link_to t("home.features_link"), "#features", class: "btn btn-primary btn-outline btn-rapid px-6" %>
          </div>
        </div>
      </section>

      <section id="features" aria-labelledby="features-title">
        <div class="mb-5">
          <p class="text-sm font-semibold text-primary"><%= t("home.starter") %></p>
          <h2 id="features-title" class="mt-1 text-xl font-bold leading-[1.5]"><%= t("home.features_title") %></h2>
        </div>
        <div class="grid gap-4 min-[961px]:grid-cols-3">
          <% [["01", t("home.features.rails.title"), t("home.features.rails.description")], ["02", t("home.features.ui.title"), t("home.features.ui.description")], ["03", t("home.features.production.title"), t("home.features.production.description")]].each do |number, title, description| %>
            <article class="card card-border border-base-300 bg-base-100 shadow-none transition-shadow hover:shadow-elevation-1">
              <div class="card-body gap-3 p-5">
                <span class="text-xs font-bold text-primary"><%= number %></span>
                <h3 class="card-title text-base leading-[1.5]"><%= title %></h3>
                <p class="text-sm text-neutral"><%= description %></p>
              </div>
            </article>
          <% end %>
        </div>
      </section>
    </div>
  ERB

  create_file "app/views/accounts/show.html.erb", <<~ERB, force: true
    <% content_for :title, t("accounts.show.title") %>
    <div class="space-y-6">
      <header>
        <p class="text-sm font-semibold text-primary">Account</p>
        <h1 class="mt-1 text-2xl font-bold leading-[1.5]"><%= t("accounts.show.title") %></h1>
        <p class="mt-2 text-sm text-neutral">#{account_page_description}</p>
      </header>

      <section class="card card-border border-base-300 bg-base-100 shadow-none">
        <div class="card-body p-5 sm:p-6">
          <h2 class="card-title text-base leading-[1.5]"><%= t("accounts.show.next_step") %></h2>
          <p class="text-sm text-neutral">#{account_page_action}</p>
          <div class="card-actions mt-2 justify-end">
            <%= link_to t("accounts.show.back_home"), root_path, class: "btn btn-primary btn-outline btn-rapid" %>
          </div>
        </div>
      </section>
    </div>
  ERB

  unless devise
    create_file "app/views/accounts/edit.html.erb", <<~ERB, force: true
      <% content_for :title, t("accounts.edit.title") %>
      <div class="space-y-6">
        <header>
          <p class="text-sm font-semibold text-primary">Account settings</p>
          <h1 class="mt-2 text-2xl font-bold leading-[1.5]"><%= t("accounts.edit.title") %></h1>
        </header>

        <section class="card card-border border-base-300 bg-base-100 shadow-none">
          <div class="card-body p-5 sm:p-6">
            <h2 class="card-title text-base leading-[1.5]"><%= t("accounts.edit.information") %></h2>
            <ul class="list mt-3">
              <li class="list-row px-0">
                <span class="badge badge-outline">ID</span>
                <div class="list-col-grow min-w-0">
                  <p class="text-xs text-neutral"><%= t("accounts.edit.wallet_address") %></p>
                  <p class="mt-1 break-all font-semibold"><%= Current.user.wallet_address %></p>
                </div>
              </li>
            </ul>
          </div>
        </section>

        <section class="card card-border border-error bg-base-100 shadow-none">
          <div class="card-body p-5 sm:p-6">
            <h2 class="card-title text-base leading-[1.5]"><%= t("accounts.edit.danger_title") %></h2>
            <p class="text-sm text-neutral"><%= t("accounts.edit.danger_description") %></p>
            <div class="card-actions mt-2 justify-start">
              <%= button_to t("accounts.edit.delete"), account_path, method: :delete, class: "btn btn-outline btn-error btn-rapid", data: { turbo_confirm: t("accounts.edit.confirm") } %>
            </div>
          </div>
        </section>
      </div>
    ERB
  end

  if devise
    configure_devise_views
  else
    create_file "app/views/sessions/new.html.erb", <<~ERB, force: true
      <% content_for :title, t("wallet_siwe.title") %>
      <div data-controller="siwe-sign-in"
           data-siwe-sign-in-statement-value="<%= application_identity.siwe_statement %>"
           data-siwe-sign-in-wallet-missing-value="<%= t('wallet_siwe.errors.wallet_missing') %>"
           data-siwe-sign-in-nonce-error-value="<%= t('wallet_siwe.errors.nonce') %>"
           data-siwe-sign-in-verification-error-value="<%= t('wallet_siwe.errors.verification') %>">
        <header class="mb-8">
          <p class="text-sm font-semibold text-primary"><%= t("wallet_siwe.eyebrow") %></p>
          <h1 class="mt-2 text-2xl font-bold leading-[1.5]"><%= t("wallet_siwe.title") %></h1>
          <p class="mt-2 text-sm text-neutral"><%= t("wallet_siwe.description") %></p>
        </header>
        <button type="button" class="btn btn-primary btn-block btn-rapid hover:border-secondary hover:bg-secondary" data-action="click->siwe-sign-in#signIn"><%= t("wallet_siwe.connect") %></button>
        <p class="alert alert-error mt-5 hidden" data-siwe-sign-in-target="error" role="alert"></p>
        <div class="divider"></div>
        <div class="alert alert-info alert-soft text-sm" role="note"><span><%= t("wallet_siwe.note") %></span></div>
      </div>
    ERB
  end

  generated_profile_assertion = if display_name_enabled && screen_name_enabled
    <<~RUBY
      assert_predicate user.profile, :persisted?
      assert_match(/\\A[a-z0-9_]+\\z/, user.profile.screen_name)
      assert_equal user.profile.screen_name.camelize, user.profile.display_name
    RUBY
  elsif screen_name_enabled
    <<~RUBY
      assert_predicate user.profile, :persisted?
      assert_match(/\\A[a-z0-9_]+\\z/, user.profile.screen_name)
    RUBY
  elsif display_name_enabled
    <<~RUBY
      assert_predicate user.profile, :persisted?
      assert_predicate user.profile.display_name, :present?
    RUBY
  else
    ""
  end
  generated_profile_assertion = generated_profile_assertion.lines.map { |line| "      #{line}" }.join
  profile_setup = if display_name_enabled || screen_name_enabled
    attributes = []
    attributes << 'screen_name: "sample_user"' if screen_name_enabled
    attributes << 'display_name: "Sample User"' if display_name_enabled
    "      user.profile.update!(#{attributes.join(', ')})\n"
  else
    ""
  end
  profile_trigger_assertion = if avatar_enabled
    <<~RUBY.lines.map { |line| "      #{line}" }.join
      assert_select 'header details.dropdown.dropdown-end.dropdown-hover > summary.btn.btn-circle .avatar', count: 1 do
        assert_select 'svg[width="40"][height="40"][aria-hidden="true"]', count: 1
      end
      assert_select 'header .avatar-placeholder', count: 0
    RUBY
  else
    <<~RUBY.lines.map { |line| "      #{line}" }.join
      assert_select 'header details.dropdown.dropdown-end.dropdown-hover > summary.btn.btn-ghost', text: I18n.t("common.menu"), count: 1 do
        assert_select 'svg[data-slot="icon"]', count: 1
      end
    RUBY
  end
  profile_identity_assertion = if display_name_enabled && screen_name_enabled
    "      assert_select 'header ul.menu.dropdown-content > li.menu-title', text: /Sample User.*@sample_user/m, count: 1\n"
  elsif display_name_enabled
    "      assert_select 'header ul.menu.dropdown-content > li.menu-title', text: 'Sample User', count: 1\n"
  elsif screen_name_enabled
    "      assert_select 'header ul.menu.dropdown-content > li.menu-title', text: '@sample_user', count: 1\n"
  else
    "      assert_select 'header ul.menu.dropdown-content > li.menu-title', count: 0\n"
  end
  profile_page_assertions = if profile_enabled
    form_assertions = []
    if screen_name_enabled
      form_assertions << <<~RUBY
        assert_select 'form[action=?] input[name="profile[screen_name]"][pattern="[a-z0-9_]+"]', profile_path, count: 1
      RUBY
    end
    if display_name_enabled
      form_assertions << <<~RUBY
        assert_select 'form[action=?] input[name="profile[display_name]"]', profile_path, count: 1
      RUBY
    end
    if avatar_enabled
      form_assertions << <<~RUBY
        assert_select 'form[action=?] fieldset.fieldset.min-w-0.grid-cols-1 input.file-input.min-w-0[name="profile[avatar_upload]"][accept="image/jpeg,image/png,image/webp"]', profile_path, count: 1
        assert_select 'form[action=?] fieldset.fieldset p.label > span.min-w-0.whitespace-normal', profile_path, text: I18n.t("profiles.avatar_hint"), count: 1
        assert_select 'form[action=?] .avatar svg[width="64"][height="64"]', profile_path, count: 1
        assert_select 'form[action=?]', profile_avatar_path, count: 0
      RUBY
    end
    update_assertion = if screen_name_enabled
      <<~RUBY
        patch profile_url, params: { profile: { screen_name: 'updated_user' } }
        assert_redirected_to profile_url
        assert_equal 'updated_user', user.profile.reload.screen_name
      RUBY
    elsif display_name_enabled
      <<~RUBY
        patch profile_url, params: { profile: { display_name: 'Updated User' } }
        assert_redirected_to profile_url
        assert_equal 'Updated User', user.profile.reload.display_name
      RUBY
    else
      ""
    end
    <<~RUBY
      get profile_url
      assert_response :success
      assert_select '[data-layout="account"] .list > .list-row', count: #{profile_features.length}
      assert_select 'a[href=?]', edit_profile_path, text: I18n.t("profiles.edit"), count: 1
      #{avatar_enabled ? "assert_select '.list .avatar svg[width=\"64\"][height=\"64\"]', count: 1\n      assert_select '.avatar-placeholder', count: 0" : ""}

      get edit_profile_url
      assert_response :success
      #{form_assertions.join}#{update_assertion}
      #{if avatar_enabled
          <<~RUBY
            patch profile_url, params: { profile: { avatar_upload: AvatarTestImage.upload } }
            assert_redirected_to profile_url
            assert_predicate user.profile.reload.avatar, :attached?
            get edit_profile_url
            assert_select 'form[action=?] .avatar img[width="64"][height="64"]', profile_path, count: 1
            assert_select 'form[action=?][method="post"]', profile_avatar_path, count: 1 do
              assert_select 'input[name="_method"][value="delete"]', count: 1
              assert_select 'button.btn.btn-outline.btn-error[data-turbo-confirm]', text: I18n.t("profiles.avatar_delete"), count: 1
            end

            original_blob = user.profile.avatar.blob
            patch profile_url, params: { profile: { avatar_upload: AvatarTestImage.corrupt_png_upload } }
            assert_response :unprocessable_content
            error_text = I18n.t("activerecord.errors.models.profile.attributes.avatar_upload.undecodable")
            assert_select '.alert.alert-error[role="alert"]', text: /\#{Regexp.escape(error_text)}/, count: 1
            assert_equal original_blob, user.profile.reload.avatar.blob

            delete profile_avatar_url
            assert_redirected_to profile_url
            assert_not user.profile.reload.avatar.attached?
            follow_redirect!
            assert_select '.alert.alert-success', text: I18n.t("profiles.avatar.destroy.notice"), count: 1
            assert_select '.list .avatar svg[width="64"][height="64"]', count: 1
          RUBY
        else
          ""
        end}
    RUBY
  else
    <<~RUBY
      assert_nil User.reflect_on_association(:profile)
      assert_raises(ActionController::RoutingError) { Rails.application.routes.recognize_path('/profile', method: :get) }
    RUBY
  end
  profile_page_assertions = profile_page_assertions.lines.map { |line| "      #{line}" }.join
  job_operations_route_test = if job_operations_enabled
    <<~RUBY

        test "mounts Mission Control Jobs only below the admin namespace" do
          assert_respond_to Rails.application.routes.url_helpers, :admin_jobs_path
          assert_equal "/admin/jobs", admin_jobs_path
          assert Rails.application.routes.recognize_path("/admin/jobs", method: :get)
          %w[
            config/initializers/mission_control_jobs.rb
            app/controllers/admin/job_operations_controller.rb
            app/policies/job_operation_policy.rb
            app/views/layouts/mission_control/jobs/application.html.erb
            app/assets/stylesheets/mission_control_jobs_scoped.css
            config/locales/job_operations.ja.yml
            config/locales/job_operations.en.yml
            docs/job_operations.md
            test/policies/job_operation_policy_test.rb
            test/controllers/admin/job_operations_controller_test.rb
            test/models/solid_queue_cleanup_test.rb
          ].each { |path| assert Rails.root.join(path).file?, path }
          assert_match(/gem ["']mission_control-jobs["'], ["']1\.1\.0["']/, Rails.root.join("Gemfile").read)
          assert_raises(ActionController::RoutingError) do
            Rails.application.routes.recognize_path("/jobs", method: :get)
          end
        end
    RUBY
  else
    <<~RUBY

        test "does not expose Mission Control Jobs when the feature is disabled" do
          assert_not_respond_to Rails.application.routes.url_helpers, :admin_jobs_path
          %w[
            config/initializers/mission_control_jobs.rb
            app/controllers/admin/job_operations_controller.rb
            app/policies/job_operation_policy.rb
            app/views/layouts/mission_control/jobs/application.html.erb
            app/assets/stylesheets/mission_control_jobs_scoped.css
            config/locales/job_operations.ja.yml
            config/locales/job_operations.en.yml
            docs/job_operations.md
            test/policies/job_operation_policy_test.rb
            test/controllers/admin/job_operations_controller_test.rb
            test/models/solid_queue_cleanup_test.rb
          ].each { |path| assert_not Rails.root.join(path).exist?, path }
          assert_no_match(/gem ["']mission_control-jobs["']/, Rails.root.join("Gemfile").read)
          recurring = YAML.safe_load_file(Rails.root.join("config/recurring.yml"), aliases: true)
            .fetch("production").fetch("clear_solid_queue_finished_jobs")
          assert_equal "SolidQueue::Job.clear_finished_in_batches(sleep_between_batches: 0.3)", recurring.fetch("command")
          assert_equal "every hour at minute 12", recurring.fetch("schedule")
          assert_equal 1, Rails.root.join("Procfile.prod").read.lines.count { |line| line.start_with?("worker:") }
          assert_raises(ActionController::RoutingError) do
            Rails.application.routes.recognize_path("/admin/jobs", method: :get)
          end
          assert_raises(ActionController::RoutingError) do
            Rails.application.routes.recognize_path("/jobs", method: :get)
          end
        end
    RUBY
  end
  maintenance_route_test = if maintenance_tasks_enabled
    <<~RUBY

        test "mounts Maintenance Tasks only below the admin namespace" do
          assert_respond_to Rails.application.routes.url_helpers, :admin_maintenance_tasks_path
          assert_equal "/admin/maintenance_tasks", admin_maintenance_tasks_path
          assert Rails.application.routes.recognize_path("/admin/maintenance_tasks", method: :get)
          assert ActiveRecord::Base.connection.data_source_exists?("maintenance_tasks_runs")
          assert_raises(ActionController::RoutingError) do
            Rails.application.routes.recognize_path("/maintenance_tasks", method: :get)
          end
        end
    RUBY
  else
    <<~RUBY

        test "does not expose Maintenance Tasks when the feature is disabled" do
          assert_not_respond_to Rails.application.routes.url_helpers, :admin_maintenance_tasks_path
          assert_not ActiveRecord::Base.connection.data_source_exists?("maintenance_tasks_runs")
          assert_raises(ActionController::RoutingError) do
            Rails.application.routes.recognize_path("/admin/maintenance_tasks", method: :get)
          end
          assert_raises(ActionController::RoutingError) do
            Rails.application.routes.recognize_path("/maintenance_tasks", method: :get)
          end
        end
    RUBY
  end

  default_pages_test = if devise
    <<~RUBY
      require "test_helper"
      require "stringio"

      class DefaultPagesTest < ActionDispatch::IntegrationTest
        include Devise::Test::IntegrationHelpers

        test "renders public and authentication pages with the custom theme" do
          get root_url
          assert_response :success
          assert_select 'html[data-theme="rapid-rails"]'
          assert_select 'nav.navbar.mx-auto.w-full.max-w-6xl.px-5[aria-label=?]', I18n.t("navigation.main")
          assert_select 'header details.dropdown.dropdown-end > summary.btn.btn-ghost + ul.menu.menu-sm.dropdown-content', count: 1
          assert_select 'header ul.menu.dropdown-content > li > a', count: 2
          assert_select 'header ul.menu.dropdown-content > li > a[class]', count: 0
          assert_select 'header ul.menu.dropdown-content .divider, header ul.menu.dropdown-content .btn', count: 0
          assert_select 'header a[href=?].btn.btn-ghost.btn-rapid', new_user_session_path, count: 1
          assert_select 'header a[href=?].btn.btn-outline.btn-rapid', new_user_registration_path, count: 1
          assert_select '.hero > .hero-content', count: 1
          assert_select '#features article.card > .card-body', count: 3
          assert_select '#features .card-title', count: 3
          assert_select 'footer.footer.mx-auto.w-full.max-w-6xl.px-5', count: 1
          refute_includes response.body, 'Rails 8.1 / Tailwind CSS 4 / daisyUI 5'

          [new_user_session_url, new_user_registration_url, new_user_password_url].each do |url|
            get url
            assert_response :success
            assert_select '[data-layout="authentication"].hero > .hero-content .card > .card-body'
            assert_select 'form fieldset.fieldset', minimum: 1
            assert_select 'form fieldset.fieldset > legend.fieldset-legend > label', minimum: 1
            assert_select 'form .input.input-rapid', minimum: 1
            assert_select 'form .btn.btn-block.btn-rapid', minimum: 1
            assert_select '.divider + .menu > li > a', minimum: 1
            assert_select '.divider + .menu > li > a[class]', count: 0
          end
        end

        test "protects account and renders its sub-layout after login" do
          get account_url
          assert_redirected_to new_user_session_url

          user = User.create!(email: "sample@example.com", password: "password123", password_confirmation: "password123")
    #{generated_profile_assertion}#{profile_setup}      user.grant_role!(:admin)
          sign_in user
          get account_url
          assert_response :success
          assert_select '[data-layout="account"].mx-auto.w-full.max-w-6xl.px-5', count: 1
    #{profile_trigger_assertion}
          assert_select 'header ul.menu.dropdown-content > li > a', count: #{account_navigation_count + 1}
    #{profile_identity_assertion}      assert_select 'header ul.menu.dropdown-content a[data-turbo-method="delete"][href=?]', destroy_user_session_path, count: 1
          account_menu = I18n.t("navigation.account_menu")
          assert_select 'nav[aria-label=?] > .menu > li.menu-title', account_menu, text: I18n.t("navigation.dashboard"), count: 1
          assert_select 'nav[aria-label=?] > .menu > li > a', account_menu, count: #{account_navigation_count}
          assert_select 'nav[aria-label=?] > .menu > li > a > svg.size-5[aria-hidden="true"][data-slot="icon"]', account_menu, count: #{account_navigation_count}
          assert_select 'nav[aria-label=?] a[href=?]', account_menu, root_path, count: 0
          assert_select 'nav[aria-label=?] a.menu-active[aria-current="page"][href=?]', account_menu, account_path, count: 1
          assert_select 'nav[aria-label=?] a.menu-active', account_menu, count: 1
          assert_select 'nav[aria-label=?] a.menu-active[class="menu-active"]', account_menu, count: 1
          assert_select 'nav[aria-label=?] > .menu > li > a[class]', account_menu, count: 1
          assert_select 'nav[aria-label=?] > .menu > li > a.min-h-11', account_menu, count: 0
          assert_select 'nav[aria-label=?]', I18n.t("navigation.admin_menu"), count: 0
          assert_select 'header li.menu-title', text: I18n.t("navigation.admin"), count: 0
          assert_select 'header a[href=?]', admin_users_path, count: 0
          assert_select '.card > .card-body', count: 1

    #{profile_page_assertions}

          get edit_user_registration_url
          assert_response :success
          assert_select '[data-layout="account"].mx-auto.w-full.max-w-6xl.px-5', count: 1
          assert_select 'nav[aria-label=?] > .menu > li > a', account_menu, count: #{account_navigation_count}
          assert_select 'nav[aria-label=?] > .menu > li > a > svg.size-5[aria-hidden="true"][data-slot="icon"]', account_menu, count: #{account_navigation_count}
          assert_select 'nav[aria-label=?] a[href=?]', account_menu, root_path, count: 0
          assert_select 'nav[aria-label=?] a.menu-active[aria-current="page"][href=?]', account_menu, edit_user_registration_path, count: 1
          assert_select 'nav[aria-label=?] a.menu-active', account_menu, count: 1
          assert_select 'nav[aria-label=?] a.menu-active[class="menu-active"]', account_menu, count: 1
          assert_select 'nav[aria-label=?] > .menu > li > a[class]', account_menu, count: 1
          assert_select 'nav[aria-label=?] > .menu > li > a.min-h-11', account_menu, count: 0
          assert_select '.card .fieldset', minimum: 1
          assert_select '.card-actions .btn.btn-error', count: 1
        end
    #{job_operations_route_test}#{maintenance_route_test}
      end
    RUBY
  else
    <<~RUBY
      require "test_helper"

      class DefaultPagesTest < ActionDispatch::IntegrationTest
        test "renders public and wallet login pages with the custom theme" do
          get root_url
          assert_response :success
          assert_select 'html[data-theme="rapid-rails"]'
          assert_select 'nav.navbar.mx-auto.w-full.max-w-6xl.px-5[aria-label=?]', I18n.t("navigation.main")
          assert_select 'header details.dropdown.dropdown-end > summary.btn.btn-ghost + ul.menu.menu-sm.dropdown-content', count: 1
          assert_select 'header ul.menu.dropdown-content > li > a', count: 1
          assert_select 'header ul.menu.dropdown-content > li > a[class]', count: 0
          assert_select 'header ul.menu.dropdown-content .divider, header ul.menu.dropdown-content .btn', count: 0
          assert_select 'header a[href=?].btn.btn-ghost.btn-rapid', new_session_path, count: 1
          assert_select '.hero > .hero-content', count: 1
          assert_select 'footer.footer.mx-auto.w-full.max-w-6xl.px-5', count: 1
          refute_includes response.body, 'Rails 8.1 / Tailwind CSS 4 / daisyUI 5'

          get new_session_url
          assert_response :success
          assert_select '[data-layout="authentication"].hero > .hero-content .card > .card-body'
          assert_select '[data-controller="siwe-sign-in"]'
          assert_select '[data-action="click->siwe-sign-in#signIn"].btn.btn-block.btn-rapid'
          assert_select '[data-siwe-sign-in-target="error"]'
          assert_select '.divider + .alert.alert-info.alert-soft', count: 1
        end

        test "protects account and does not expose unimplemented session actions" do
          get account_url
          assert_redirected_to new_session_url
          get edit_account_url
          assert_redirected_to new_session_url
          assert_raises(ActionController::RoutingError) { Rails.application.routes.recognize_path("/session/edit", method: :get) }
        end
    #{job_operations_route_test}#{maintenance_route_test}
      end
    RUBY
  end
  create_file "test/integration/default_pages_test.rb", default_pages_test, force: true
end

def configure_pwa
  route 'get "manifest" => "rails/pwa#manifest", as: :pwa_manifest'
  route 'get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker'

  create_file "app/views/pwa/manifest.json.erb", <<~ERB, force: true
    <% identity = Rails.configuration.x.application_identity %>
    <%== JSON.pretty_generate(
      name: identity.app_name,
      short_name: identity.app_name,
      lang: identity.default_locale.to_s,
      icons: [
        { src: "/icon.png", type: "image/png", sizes: "512x512" },
        { src: "/icon.png", type: "image/png", sizes: "512x512", purpose: "maskable" }
      ],
      start_url: "/",
      display: "standalone",
      scope: "/",
      description: I18n.t("meta.description", locale: identity.default_locale, app_name: identity.app_name),
      theme_color: "#3ea8ff",
      background_color: "#ffffff"
    ) %>
  ERB

  create_file "app/views/pwa/service-worker.js", <<~JAVASCRIPT, force: true
    self.addEventListener("push", (event) => {
      if (!event.data) return

      try {
        const payload = event.data.json()
        const options = payload.options || {}
        event.waitUntil(self.registration.showNotification(payload.title, options))
      } catch (error) {
        console.error("Invalid Web Push payload", error)
      }
    })

    self.addEventListener("notificationclick", (event) => {
      event.notification.close()

      let targetUrl = new URL("/", self.location.origin)
      try {
        const candidate = new URL(event.notification.data?.path || "/", self.location.origin)
        if (candidate.origin === self.location.origin) targetUrl = candidate
      } catch (error) {
        console.error("Invalid notification path", error)
      }

      event.waitUntil(
        self.clients.matchAll({ type: "window", includeUncontrolled: true }).then(async (clients) => {
          const exactClient = clients.find((client) => client.url === targetUrl.href)
          if (exactClient) return exactClient.focus()

          const sameOriginClient = clients.find((client) => new URL(client.url).origin === self.location.origin)
          if (sameOriginClient && "navigate" in sameOriginClient) {
            const navigatedClient = await sameOriginClient.navigate(targetUrl.href)
            return navigatedClient?.focus()
          }

          return self.clients.openWindow(targetUrl.href)
        })
      )
    })
  JAVASCRIPT

  create_file "app/javascript/controllers/pwa_controller.js", <<~JAVASCRIPT, force: true
    import { Controller } from "@hotwired/stimulus"

    export default class extends Controller {
      connect() {
        this.registerServiceWorker()
      }

      async registerServiceWorker() {
        if (!("serviceWorker" in navigator)) {
          console.error("Service Worker is not supported by this browser")
          return
        }

        try {
          await navigator.serviceWorker.register("/service-worker", { scope: "/" })
        } catch (error) {
          console.error("Service Worker registration failed", error)
        }
      }
    }
  JAVASCRIPT

  create_file "test/integration/pwa_identity_test.rb", <<~RUBY, force: true
    require "test_helper"

    class PwaIdentityTest < ActionDispatch::IntegrationTest
      test "uses the application identity in the manifest" do
        get pwa_manifest_url(format: :json)

        identity = Rails.configuration.x.application_identity
        assert_response :success
        assert_equal identity.app_name, response.parsed_body.fetch("name")
        assert_equal identity.app_name, response.parsed_body.fetch("short_name")
        assert_equal identity.default_locale.to_s, response.parsed_body.fetch("lang")
        assert_equal I18n.t("meta.description", locale: identity.default_locale, app_name: identity.app_name), response.parsed_body.fetch("description")
      end
    end
  RUBY
end

def configure_web_push
  devise = VALUES.fetch("account_authentication") == "devise"
  authentication_callback = devise ? "  before_action :authenticate_user!\n" : ""
  account_user = devise ? "current_user" : "Current.user"

  require "web-push"
  environment "config.action_controller.cache_store = :memory_store", env: "test"
  key = WebPush.generate_key
  create_file "mise.local.toml", <<~TOML, force: true
    [env]
    VAPID_PUBLIC_KEY = #{key.public_key.inspect}
    VAPID_PRIVATE_KEY = #{key.private_key.inspect}
    VAPID_SUBJECT = "https://localhost"
  TOML
  append_to_file ".gitignore", "\n/mise.local.toml\n" unless File.read(".gitignore").lines.map(&:strip).include?("/mise.local.toml")

  generate "model", "PushSubscription", "user:references", "browser_id:string", "endpoint:text", "p256dh:string", "auth:string"
  migration = Dir.glob("db/migrate/*_create_push_subscriptions.rb")
  raise "CreatePushSubscriptions migrationが一意ではありません" unless migration.one?

  create_file migration.first, <<~RUBY, force: true
    class CreatePushSubscriptions < ActiveRecord::Migration[8.1]
      def change
        create_table :push_subscriptions do |t|
          t.references :user, null: false, foreign_key: { on_delete: :cascade }
          t.string :browser_id, null: false
          t.text :endpoint, null: false
          t.string :p256dh, null: false
          t.string :auth, null: false
          t.timestamps
        end

        add_index :push_subscriptions, :browser_id, unique: true
        add_index :push_subscriptions, :endpoint, unique: true
      end
    end
  RUBY

  create_file "app/models/push_subscription.rb", <<~RUBY, force: true
    class PushSubscription < ApplicationRecord
      belongs_to :user

      validates :browser_id, :endpoint, :p256dh, :auth, presence: true
      validates :browser_id, :endpoint, uniqueness: true
      validates :endpoint, format: { with: %r{\\Ahttps://[^\\s]+\\z} }

      def self.register!(user:, attributes:)
        transaction do
          browser_subscription = lock.find_by(browser_id: attributes.fetch(:browser_id))
          endpoint_subscription = lock.find_by(endpoint: attributes.fetch(:endpoint))
          subscription = endpoint_subscription || browser_subscription || new

          browser_subscription.destroy! if browser_subscription && browser_subscription != subscription
          subscription.update!(attributes.merge(user:))
          subscription
        end
      end
    end
  RUBY
  inject_into_class "app/models/user.rb", "User", "  has_many :push_subscriptions, dependent: :destroy\n\n"

  create_file "app/services/vapid_configuration.rb", <<~RUBY, force: true
    require "uri"

    class VapidConfiguration
      Error = Class.new(StandardError)

      attr_reader :public_key, :private_key, :subject

      def self.fetch!
        new(
          public_key: ENV.fetch("VAPID_PUBLIC_KEY"),
          private_key: ENV.fetch("VAPID_PRIVATE_KEY"),
          subject: ENV.fetch("VAPID_SUBJECT")
        )
      rescue KeyError => error
        raise Error, "Web Push environment is incomplete: \#{error.key}"
      end

      def initialize(public_key:, private_key:, subject:)
        @public_key = public_key.presence || raise(Error, "VAPID_PUBLIC_KEY is blank")
        @private_key = private_key.presence || raise(Error, "VAPID_PRIVATE_KEY is blank")
        @subject = subject.presence || raise(Error, "VAPID_SUBJECT is blank")
        uri = URI.parse(@subject)
        raise Error, "VAPID_SUBJECT must use mailto or https" unless %w[mailto https].include?(uri.scheme)
      rescue URI::InvalidURIError => error
        raise Error, "VAPID_SUBJECT is invalid: \#{error.message}"
      end

      def to_h
        { subject:, public_key:, private_key: }
      end
    end
  RUBY

  create_file "app/jobs/push_notification_job.rb", <<~RUBY, force: true
    class PushNotificationJob < ApplicationJob
      queue_as :default

      retry_on WebPush::TooManyRequests, WebPush::PushServiceError,
        Net::OpenTimeout, Net::ReadTimeout, Timeout::Error,
        wait: :polynomially_longer, attempts: 5

      def perform(subscription_id, expected_user_id, payload, ttl)
        subscription = PushSubscription.find_by(id: subscription_id, user_id: expected_user_id)
        return unless subscription

        WebPush.payload_send(
          endpoint: subscription.endpoint,
          message: JSON.generate(payload),
          p256dh: subscription.p256dh,
          auth: subscription.auth,
          vapid: VapidConfiguration.fetch!.to_h,
          ttl:,
          open_timeout: 5,
          read_timeout: 5,
          ssl_timeout: 5
        )
      rescue WebPush::ExpiredSubscription, WebPush::InvalidSubscription
        subscription&.destroy!
      end
    end
  RUBY

  create_file "app/services/push_notifier.rb", <<~RUBY, force: true
    class PushNotifier
      DEFAULT_TTL = 86_400

      def self.deliver_later(user:, title:, body:, path:, tag: nil, icon: "/icon.png", ttl: DEFAULT_TTL)
        raise ArgumentError, "user must be persisted" unless user&.persisted?
        raise ArgumentError, "title is required" if title.blank?
        raise ArgumentError, "body is required" if body.blank?
        raise ArgumentError, "path must be a same-origin absolute path" unless path.start_with?("/") && !path.start_with?("//")
        raise ArgumentError, "ttl must be positive" unless ttl.to_i.positive?

        VapidConfiguration.fetch!
        options = { body:, icon:, data: { path: } }
        options[:tag] = tag if tag.present?
        payload = { title:, options: }

        user.push_subscriptions.find_each do |subscription|
          PushNotificationJob.perform_later(subscription.id, user.id, payload, ttl.to_i)
        end
      end
    end
  RUBY

  route <<~RUBY
    resource :push_subscription, only: %i[create destroy] do
      get :vapid_public_key
      post :test
    end
    resource :notification, only: :show
  RUBY

  create_file "app/controllers/notifications_controller.rb", <<~RUBY, force: true
    class NotificationsController < ApplicationController
      layout "account"
    #{authentication_callback}end
  RUBY

  create_file "app/controllers/push_subscriptions_controller.rb", <<~RUBY, force: true
    class PushSubscriptionsController < ApplicationController
    #{authentication_callback}  rate_limit to: 5, within: 1.minute, only: :test

      def vapid_public_key
        response.set_header("Cache-Control", "no-store")
        render json: { public_key: VapidConfiguration.fetch!.public_key }
      rescue VapidConfiguration::Error
        render json: { error: I18n.t("web_push.errors.configuration") }, status: :service_unavailable
      end

      def create
        PushSubscription.register!(user: account_user, attributes: subscription_params.to_h.symbolize_keys)
        head :no_content
      rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
        head :unprocessable_content
      end

      def destroy
        account_user.push_subscriptions.find_by(browser_id: browser_id_param)&.destroy!
        head :no_content
      end

      def test
        subscription = account_user.push_subscriptions.find_by(browser_id: browser_id_param)
        return head :not_found unless subscription

        VapidConfiguration.fetch!
        payload = {
          title: I18n.t("web_push.test.title"),
          options: {
            body: I18n.t("web_push.test.body"),
            icon: "/icon.png",
            tag: "web-push-test",
            data: { path: notification_path }
          }
        }
        PushNotificationJob.perform_later(subscription.id, account_user.id, payload, PushNotifier::DEFAULT_TTL)
        head :accepted
      rescue VapidConfiguration::Error
        render json: { error: I18n.t("web_push.errors.configuration") }, status: :service_unavailable
      end

      private
        def account_user
          #{account_user}
        end

        def subscription_params
          params.expect(push_subscription: %i[browser_id endpoint p256dh auth])
        end

        def browser_id_param
          params.expect(push_subscription: [:browser_id]).fetch(:browser_id)
        end
    end
  RUBY

  create_file "app/javascript/controllers/push_subscription_controller.js", <<~JAVASCRIPT, force: true
    import { Controller } from "@hotwired/stimulus"

    export default class extends Controller {
      static targets = ["toggle", "testButton", "status"]
      static values = {
        authenticated: Boolean,
        publicKeyUrl: String,
        subscriptionUrl: String,
        testUrl: String,
        messages: Object
      }

      connect() {
        if (!this.authenticatedValue) return
        if (!this.#supported()) {
          this.#render("unsupported", this.messagesValue.unsupported)
          return
        }

        this.browserId = this.#browserId()
        this.#reconcile().catch((error) => this.#fail(error))
      }

      async toggle(event) {
        this.#setBusy(true)
        try {
          if (event.target.checked) {
            await this.#enable()
          } else {
            await this.#disable()
          }
        } catch (error) {
          this.#fail(error)
        } finally {
          this.#setBusy(false)
        }
      }

      async sendTest() {
        this.#setBusy(true)
        try {
          const response = await this.#request(this.testUrlValue, "POST", {
            push_subscription: { browser_id: this.browserId }
          })
          if (response.status !== 202) throw new Error(this.messagesValue.test_failed)
          this.#render("success", this.messagesValue.test_sent)
        } catch (error) {
          this.#fail(error)
        } finally {
          this.#setBusy(false)
        }
      }

      async #reconcile() {
        if (Notification.permission === "denied") {
          this.#render("denied", this.messagesValue.blocked)
          return
        }

        const registration = await this.#registration()
        const subscription = await registration.pushManager.getSubscription()
        if (!subscription) {
          this.#render("off", this.messagesValue.off)
          return
        }

        const publicKey = await this.#publicKey()
        if (!this.#sameApplicationServerKey(subscription, publicKey)) {
          const unsubscribed = await subscription.unsubscribe()
          if (!unsubscribed) throw new Error(this.messagesValue.unsubscribe_failed)
          await this.#deleteServerSubscription()
          const replacement = await this.#subscribe(registration, publicKey)
          await this.#save(replacement)
          this.#render("on", this.messagesValue.reconciled)
          return
        }

        await this.#save(subscription)
        this.#render("on", this.messagesValue.on)
      }

      async #enable() {
        let permission = Notification.permission
        if (permission === "default") permission = await Notification.requestPermission()
        if (permission !== "granted") {
          this.#render("denied", this.messagesValue.denied)
          return
        }

        const registration = await this.#registration()
        const publicKey = await this.#publicKey()
        let subscription = await registration.pushManager.getSubscription()
        if (subscription && !this.#sameApplicationServerKey(subscription, publicKey)) {
          const unsubscribed = await subscription.unsubscribe()
          if (!unsubscribed) throw new Error(this.messagesValue.unsubscribe_failed)
          await this.#deleteServerSubscription()
          subscription = null
        }

        subscription ||= await this.#subscribe(registration, publicKey)
        try {
          await this.#save(subscription)
        } catch (error) {
          await subscription.unsubscribe()
          await this.#deleteServerSubscription()
          throw error
        }
        this.#render("on", this.messagesValue.enabled)
      }

      async #disable() {
        const registration = await this.#registration()
        const subscription = await registration.pushManager.getSubscription()
        if (subscription) {
          const unsubscribed = await subscription.unsubscribe()
          if (!unsubscribed) throw new Error(this.messagesValue.unsubscribe_failed)
        }
        await this.#deleteServerSubscription()
        this.#render("off", this.messagesValue.disabled)
      }

      async #registration() {
        return navigator.serviceWorker.register("/service-worker", { scope: "/" })
      }

      async #publicKey() {
        const response = await fetch(this.publicKeyUrlValue, {
          headers: { Accept: "application/json" },
          credentials: "same-origin"
        })
        if (!response.ok) throw new Error(await this.#responseError(response, this.messagesValue.public_key_failed))
        const payload = await response.json()
        return this.#decodeBase64Url(payload.public_key)
      }

      async #subscribe(registration, publicKey) {
        return registration.pushManager.subscribe({
          userVisibleOnly: true,
          applicationServerKey: publicKey
        })
      }

      async #save(subscription) {
        const payload = subscription.toJSON()
        const response = await this.#request(this.subscriptionUrlValue, "POST", {
          push_subscription: {
            browser_id: this.browserId,
            endpoint: payload.endpoint,
            p256dh: payload.keys?.p256dh,
            auth: payload.keys?.auth
          }
        })
        if (response.status !== 204) throw new Error(this.messagesValue.save_failed)
      }

      async #deleteServerSubscription() {
        const response = await this.#request(this.subscriptionUrlValue, "DELETE", {
          push_subscription: { browser_id: this.browserId }
        })
        if (response.status !== 204) throw new Error(this.messagesValue.delete_failed)
      }

      async #request(url, method, body) {
        const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content
        if (!csrfToken) throw new Error(this.messagesValue.csrf_missing)
        const response = await fetch(url, {
          method,
          headers: {
            Accept: "application/json",
            "Content-Type": "application/json",
            "X-CSRF-Token": csrfToken
          },
          credentials: "same-origin",
          body: JSON.stringify(body)
        })
        if (!response.ok) throw new Error(await this.#responseError(response, this.messagesValue.request_failed))
        return response
      }

      async #responseError(response, fallback) {
        try {
          const payload = await response.json()
          return payload.error || fallback
        } catch (error) {
          console.error("Web Push error response was not JSON", error)
          return fallback
        }
      }

      #browserId() {
        const storageKey = "rapid-rails-push-browser-id"
        let browserId = localStorage.getItem(storageKey)
        if (!browserId) {
          browserId = crypto.randomUUID()
          localStorage.setItem(storageKey, browserId)
        }
        return browserId
      }

      #supported() {
        return typeof window.Notification !== "undefined" &&
          Boolean(navigator.serviceWorker) &&
          typeof window.PushManager !== "undefined" &&
          typeof crypto.randomUUID === "function"
      }

      #sameApplicationServerKey(subscription, expected) {
        const actualKey = subscription.options?.applicationServerKey
        if (!actualKey) return false
        const actual = new Uint8Array(actualKey)
        return actual.length === expected.length && actual.every((value, index) => value === expected[index])
      }

      #decodeBase64Url(value) {
        const padding = "=".repeat((4 - value.length % 4) % 4)
        const base64 = (value + padding).replace(/-/g, "+").replace(/_/g, "/")
        return Uint8Array.from(atob(base64), (character) => character.charCodeAt(0))
      }

      #setBusy(busy) {
        if (this.hasToggleTarget) this.toggleTarget.disabled = busy
        if (this.hasTestButtonTarget) this.testButtonTarget.disabled = busy || !this.testButtonTarget.dataset.subscribed
      }

      #render(state, message) {
        const subscribed = state === "on" || state === "success"
        if (this.hasToggleTarget) {
          this.toggleTarget.checked = subscribed
          this.toggleTarget.disabled = state === "unsupported" || state === "denied"
        }
        if (this.hasTestButtonTarget) {
          this.testButtonTarget.dataset.subscribed = subscribed ? "true" : ""
          this.testButtonTarget.disabled = !subscribed
        }
        if (this.hasStatusTarget) {
          this.statusTarget.classList.remove("hidden", "alert-info", "alert-success", "alert-warning", "alert-error")
          const alertClass = state === "success" || state === "on" ? "alert-success" :
            state === "denied" || state === "unsupported" ? "alert-warning" :
              state === "error" ? "alert-error" : "alert-info"
          this.statusTarget.classList.add(alertClass)
          this.statusTarget.textContent = message
        }
      }

      #fail(error) {
        console.error("Web Push operation failed", error)
        this.#render("error", error.message || this.messagesValue.operation_failed)
      }
    }
  JAVASCRIPT

  create_file "app/views/notifications/show.html.erb", <<~ERB, force: true
    <% content_for :title, t("web_push.page.title") %>
    <div class="space-y-6">
      <header>
        <p class="text-sm font-semibold text-primary"><%= t("web_push.page.eyebrow") %></p>
        <h1 class="mt-2 text-2xl font-bold leading-[1.5]"><%= t("web_push.page.title") %></h1>
        <p class="mt-2 text-sm text-neutral"><%= t("web_push.page.description") %></p>
      </header>

      <section class="card card-border border-base-300 bg-base-100 shadow-none">
        <div class="card-body">
          <div class="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
            <div>
              <h2 class="card-title text-base leading-[1.5]">
                <svg xmlns="http://www.w3.org/2000/svg" class="size-5" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" aria-hidden="true" data-slot="icon">
                  <path stroke-linecap="round" stroke-linejoin="round" d="M14.857 17.082a23.848 23.848 0 0 0 5.454-1.31A8.967 8.967 0 0 1 18 9.75V9A6 6 0 0 0 6 9v.75a8.967 8.967 0 0 1-2.312 6.022c1.733.64 3.56 1.085 5.455 1.31m5.714 0a24.255 24.255 0 0 1-5.714 0m5.714 0a3 3 0 1 1-5.714 0" />
                </svg>
                <%= t("web_push.page.card_title") %>
              </h2>
              <p class="mt-2 text-sm text-neutral"><%= t("web_push.page.card_description") %></p>
            </div>
            <label class="flex cursor-pointer items-center gap-3">
              <span class="text-sm font-semibold"><%= t("web_push.page.receive") %></span>
              <input type="checkbox" class="toggle" data-push-subscription-target="toggle" data-action="change->push-subscription#toggle" aria-label="<%= t("web_push.page.toggle_label") %>">
            </label>
          </div>
          <div class="card-actions">
            <button type="button" class="btn" data-push-subscription-target="testButton" data-action="click->push-subscription#sendTest" disabled><%= t("web_push.page.send_test") %></button>
          </div>
          <div class="alert alert-info hidden" role="status" aria-live="polite" data-push-subscription-target="status"></div>
        </div>
      </section>
    </div>
  ERB

  create_file "test/fixtures/push_subscriptions.yml", "# Push subscriptions are created explicitly by tests.\n", force: true

  create_file "test/models/push_subscription_test.rb", <<~RUBY, force: true
    require "test_helper"

    class PushSubscriptionTest < ActiveSupport::TestCase
      test "registers one subscription per browser and transfers ownership" do
        subscription = PushSubscription.register!(
          user: users(:one),
          attributes: subscription_attributes
        )

        assert_no_difference("PushSubscription.count") do
          replacement = PushSubscription.register!(
            user: users(:two),
            attributes: subscription_attributes(endpoint: "https://push.example.com/replacement")
          )
          assert_equal subscription.id, replacement.id
          assert_equal users(:two), replacement.user
          assert_equal "https://push.example.com/replacement", replacement.endpoint
        end
      end

      test "reconciles browser and endpoint records without duplicates" do
        first = PushSubscription.create!(user: users(:one), **subscription_attributes)
        endpoint_owner = PushSubscription.create!(
          user: users(:two),
          **subscription_attributes(browser_id: "other-browser", endpoint: "https://push.example.com/shared")
        )

        assert_difference("PushSubscription.count", -1) do
          registered = PushSubscription.register!(
            user: users(:one),
            attributes: subscription_attributes(endpoint: endpoint_owner.endpoint)
          )
          assert_equal endpoint_owner.id, registered.id
          assert_equal first.browser_id, registered.browser_id
          assert_equal users(:one), registered.user
        end
      end

      test "validates the complete HTTPS subscription and follows user lifecycle" do
        subscription = PushSubscription.new(user: users(:one), **subscription_attributes(endpoint: "http://example.com"))
        assert_not subscription.valid?

        subscription.update!(endpoint: "https://push.example.com/lifecycle")
        users(:one).destroy!
        assert_not PushSubscription.exists?(subscription.id)
      end

      private
        def subscription_attributes(browser_id: "browser-one", endpoint: "https://push.example.com/one")
          { browser_id:, endpoint:, p256dh: "p256dh-key", auth: "auth-key" }
        end
    end
  RUBY

  create_file "test/jobs/push_notification_job_test.rb", <<~RUBY, force: true
    require "test_helper"

    class PushNotificationJobTest < ActiveJob::TestCase
      setup do
        @subscription = PushSubscription.create!(
          user: users(:one),
          browser_id: "job-browser",
          endpoint: "https://push.example.com/job",
          p256dh: "p256dh-key",
          auth: "auth-key"
        )
      end

      test "sends the structured payload with VAPID and bounded timeouts" do
        captured = nil
        with_vapid_env do
          with_payload_send(->(**options) { captured = options }) do
            PushNotificationJob.perform_now(@subscription.id, users(:one).id, payload, 600)
          end
        end

        assert_equal @subscription.endpoint, captured.fetch(:endpoint)
        assert_equal payload.deep_stringify_keys, JSON.parse(captured.fetch(:message))
        assert_equal 600, captured.fetch(:ttl)
        assert_equal 5, captured.fetch(:open_timeout)
        assert_equal 5, captured.fetch(:read_timeout)
        assert_equal 5, captured.fetch(:ssl_timeout)
        assert_equal "https://example.com", captured.dig(:vapid, :subject)
      end

      test "does not deliver after subscription ownership changes" do
        called = false
        with_payload_send(->(**) { called = true }) do
          PushNotificationJob.perform_now(@subscription.id, users(:two).id, payload, 600)
        end

        assert_not called
      end

      test "removes expired subscriptions" do
        response = Struct.new(:body).new("")
        error = WebPush::ExpiredSubscription.new(response, "push.example.com")

        with_vapid_env do
          with_payload_send(->(**) { raise error }) do
            assert_difference("PushSubscription.count", -1) do
              PushNotificationJob.perform_now(@subscription.id, users(:one).id, payload, 600)
            end
          end
        end
      end

      private
        def with_payload_send(replacement)
          singleton_class = WebPush.singleton_class
          original_method = WebPush.method(:payload_send)
          singleton_class.define_method(:payload_send, replacement)
          yield
        ensure
          singleton_class.define_method(:payload_send, original_method)
        end

        def payload
          { title: "Title", options: { body: "Body", data: { path: "/account" } } }
        end

        def with_vapid_env
          original = %w[VAPID_PUBLIC_KEY VAPID_PRIVATE_KEY VAPID_SUBJECT].index_with { |name| ENV[name] }
          ENV.update(
            "VAPID_PUBLIC_KEY" => "public",
            "VAPID_PRIVATE_KEY" => "private",
            "VAPID_SUBJECT" => "https://example.com"
          )
          yield
        ensure
          original.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
        end
    end
  RUBY

  create_file "test/services/push_notifier_test.rb", <<~RUBY, force: true
    require "test_helper"

    class PushNotifierTest < ActiveSupport::TestCase
      include ActiveJob::TestHelper

      setup do
        2.times do |index|
          PushSubscription.create!(
            user: users(:one),
            browser_id: "notifier-browser-\#{index}",
            endpoint: "https://push.example.com/notifier-\#{index}",
            p256dh: "p256dh-\#{index}",
            auth: "auth-\#{index}"
          )
        end
      end

      test "enqueues one independently owned job per subscription" do
        with_test_queue_adapter do
          with_vapid_env do
            assert_enqueued_jobs 2, only: PushNotificationJob do
              PushNotifier.deliver_later(
                user: users(:one),
                title: "Title",
                body: "Body",
                path: "/account",
                tag: "account"
              )
            end
          end
        end
      end

      test "rejects cross-origin paths and missing configuration" do
        with_vapid_env do
          assert_raises(ArgumentError) do
            PushNotifier.deliver_later(user: users(:one), title: "Title", body: "Body", path: "//example.com")
          end
        end

        %w[VAPID_PUBLIC_KEY VAPID_PRIVATE_KEY VAPID_SUBJECT].each { |name| ENV.delete(name) }
        assert_raises(VapidConfiguration::Error) do
          PushNotifier.deliver_later(user: users(:one), title: "Title", body: "Body", path: "/account")
        end
      end

      private
        def with_test_queue_adapter
          original_adapter = ActiveJob::Base.queue_adapter
          ActiveJob::Base.queue_adapter = :test
          clear_enqueued_jobs
          yield
        ensure
          ActiveJob::Base.queue_adapter = original_adapter
        end

        def with_vapid_env
          original = %w[VAPID_PUBLIC_KEY VAPID_PRIVATE_KEY VAPID_SUBJECT].index_with { |name| ENV[name] }
          ENV.update(
            "VAPID_PUBLIC_KEY" => "public",
            "VAPID_PRIVATE_KEY" => "private",
            "VAPID_SUBJECT" => "https://example.com"
          )
          yield
        ensure
          original.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
        end
    end
  RUBY

  controller_test_support = if devise
    <<~RUBY
        include Devise::Test::IntegrationHelpers
        include ActiveJob::TestHelper

        setup do
          @user = users(:one)
          sign_in @user
          Rails.cache.clear
          configure_vapid
        end
    RUBY
  else
    <<~RUBY
        require "eth"
        include ActiveJob::TestHelper

        setup do
          @user = users(:one)
          Rails.cache.clear
          key = Eth::Key.new(priv: "1".rjust(64, "0"))
          get session_nonce_url, headers: siwe_test_headers(key)
          nonce = response.parsed_body.fetch("nonce")
          @user.update!(wallet_address: key.address.to_s)
          message = Siwe::Message.new(
            domain: "www.example.com",
            address: key.address.to_s,
            uri: "http://www.example.com",
            chain_id: 1,
            nonce:,
            issued_at: Time.current.iso8601,
            statement: Rails.configuration.x.application_identity.siwe_statement
          ).prepare_message
          post session_url, params: { message:, signature: key.personal_sign(message) },
            headers: siwe_test_headers(key), as: :json
          assert_response :success
          configure_vapid
        end
    RUBY
  end
  create_file "test/controllers/push_subscriptions_controller_test.rb", <<~RUBY, force: true
    require "test_helper"

    class PushSubscriptionsControllerTest < ActionDispatch::IntegrationTest
    #{controller_test_support}
      teardown do
        @original_vapid.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
      end

      test "requires authentication" do
        #{devise ? "sign_out @user" : "delete session_url"}
        get vapid_public_key_push_subscription_url

        assert_redirected_to #{devise ? "new_user_session_url" : "new_session_url"}
        get notification_url
        assert_redirected_to #{devise ? "new_user_session_url" : "new_session_url"}
      end

      test "renders the dedicated notification settings page" do
        get notification_url

        assert_response :success
        assert_select "h1", text: I18n.t("web_push.page.title"), count: 1
        assert_select 'nav[aria-label=?] a.menu-active[aria-current="page"][href=?]', I18n.t("navigation.account_menu"), notification_path, count: 1
        assert_select '[data-push-subscription-target="toggle"]', count: 1
        assert_select '[data-push-subscription-target="testButton"]', count: 1
      end

      test "registers synchronizes and removes the current browser" do
        assert_difference("PushSubscription.count", 1) do
          post push_subscription_url, params: subscription_payload, as: :json
        end
        assert_response :no_content
        assert_equal @user, PushSubscription.find_by!(browser_id: "controller-browser").user

        assert_difference("PushSubscription.count", -1) do
          delete push_subscription_url,
            params: { push_subscription: { browser_id: "controller-browser" } },
            as: :json
        end
        assert_response :no_content
      end

      test "returns the public key without caching and reports missing configuration" do
        get vapid_public_key_push_subscription_url
        assert_response :success
        assert_equal({ "public_key" => "public" }, response.parsed_body)
        assert_equal "no-store", response.headers.fetch("Cache-Control")

        ENV.delete("VAPID_PRIVATE_KEY")
        get vapid_public_key_push_subscription_url
        assert_response :service_unavailable
      end

      test "enqueues a test notification only for the requested browser" do
        post push_subscription_url, params: subscription_payload, as: :json

        with_test_queue_adapter do
          assert_enqueued_jobs 1, only: PushNotificationJob do
            post test_push_subscription_url,
              params: { push_subscription: { browser_id: "controller-browser" } },
              as: :json
          end
        end
        assert_response :accepted

        post test_push_subscription_url,
          params: { push_subscription: { browser_id: "missing" } },
          as: :json
        assert_response :not_found
      end

      test "rate limits test notifications after five requests per minute" do
        post push_subscription_url, params: subscription_payload, as: :json

        5.times do
          post test_push_subscription_url,
            params: { push_subscription: { browser_id: "controller-browser" } },
            as: :json
          assert_response :accepted
        end

        post test_push_subscription_url,
          params: { push_subscription: { browser_id: "controller-browser" } },
          as: :json
        assert_response :too_many_requests
      end

      private
        def with_test_queue_adapter
          original_adapter = ActiveJob::Base.queue_adapter
          ActiveJob::Base.queue_adapter = :test
          clear_enqueued_jobs
          yield
        ensure
          ActiveJob::Base.queue_adapter = original_adapter
        end

        def subscription_payload
          {
            push_subscription: {
              browser_id: "controller-browser",
              endpoint: "https://push.example.com/controller",
              p256dh: "p256dh-key",
              auth: "auth-key"
            }
          }
        end

        def configure_vapid
          @original_vapid = %w[VAPID_PUBLIC_KEY VAPID_PRIVATE_KEY VAPID_SUBJECT].index_with { |name| ENV[name] }
          ENV.update(
            "VAPID_PUBLIC_KEY" => "public",
            "VAPID_PRIVATE_KEY" => "private",
            "VAPID_SUBJECT" => "https://example.com"
          )
        end
    end
  RUBY

  create_locale_pair("web_push",
    ja: {
      "web_push" => {
        "errors" => { "configuration" => "Web Pushのサーバー設定が完了していません。" },
        "test" => { "title" => "テスト通知", "body" => "Web Pushは正常に設定されています。" },
        "page" => { "title" => "通知", "eyebrow" => "通知", "description" => "このブラウザで受け取る通知を管理します。", "card_title" => "Web Push通知", "card_description" => "アプリからの更新を、このブラウザへ通知します。", "receive" => "通知を受け取る", "toggle_label" => "このブラウザのWeb Push通知を切り替える", "send_test" => "テスト通知を送信" },
        "client" => { "unsupported" => "このブラウザはWeb Pushに対応していません。", "test_failed" => "テスト通知を送信できませんでした。", "test_sent" => "テスト通知を送信しました。", "blocked" => "通知がブロックされています。ブラウザの設定から許可してください。", "off" => "このブラウザでは通知が無効です。", "unsubscribe_failed" => "Web Push購読を解除できませんでした。", "reconciled" => "VAPID鍵の変更に合わせて通知を再登録しました。", "on" => "このブラウザでは通知が有効です。", "denied" => "通知が許可されていません。ブラウザの設定を確認してください。", "enabled" => "このブラウザの通知を有効にしました。", "disabled" => "このブラウザの通知を無効にしました。", "public_key_failed" => "VAPID公開鍵を取得できませんでした。", "save_failed" => "Web Push購読を保存できませんでした。", "delete_failed" => "Web Push購読を削除できませんでした。", "csrf_missing" => "CSRF tokenが見つかりません。", "request_failed" => "Web Pushリクエストに失敗しました。", "operation_failed" => "Web Pushの処理に失敗しました。" }
      }
    },
    en: {
      "web_push" => {
        "errors" => { "configuration" => "The Web Push server configuration is incomplete." },
        "test" => { "title" => "Test notification", "body" => "Web Push is configured correctly." },
        "page" => { "title" => "Notifications", "eyebrow" => "Notifications", "description" => "Manage notifications received by this browser.", "card_title" => "Web Push notifications", "card_description" => "Receive application updates in this browser.", "receive" => "Receive notifications", "toggle_label" => "Toggle Web Push notifications for this browser", "send_test" => "Send test notification" },
        "client" => { "unsupported" => "This browser does not support Web Push.", "test_failed" => "Could not send the test notification.", "test_sent" => "The test notification was sent.", "blocked" => "Notifications are blocked. Allow them in your browser settings.", "off" => "Notifications are disabled in this browser.", "unsubscribe_failed" => "Could not remove the Web Push subscription.", "reconciled" => "Notifications were re-registered for the new VAPID key.", "on" => "Notifications are enabled in this browser.", "denied" => "Notifications are not allowed. Check your browser settings.", "enabled" => "Notifications were enabled for this browser.", "disabled" => "Notifications were disabled for this browser.", "public_key_failed" => "Could not obtain the VAPID public key.", "save_failed" => "Could not save the Web Push subscription.", "delete_failed" => "Could not delete the Web Push subscription.", "csrf_missing" => "The CSRF token was not found.", "request_failed" => "The Web Push request failed.", "operation_failed" => "The Web Push operation failed." }
      }
    }
  )
end

def install_solid_components
  if VALUES.fetch("active_job") == "solid_queue"
    generate "solid_queue:install"
    environment "config.active_job.queue_adapter = :solid_queue"
    environment "config.active_job.queue_adapter = :test", env: "test"
    append_to_file "config/puma.rb", "\nplugin :solid_queue if ENV.fetch(\"RAILS_ENV\", \"development\") == \"development\"\n"
  end
  generate "solid_cache:install" if VALUES.fetch("solid_cache") == "use"
  generate "solid_cable:install" if VALUES.fetch("action_cable") == "solid_cable"
end

def install_job_operations
  devise = VALUES.fetch("account_authentication") == "devise"
  production_worker = if VALUES.fetch("deployment") == "dokploy"
    "Dokployでは既存の`worker: bin/jobs --mode async`がworker、dispatcher、schedulerを起動します。cleanup専用processは追加しません。"
  else
    "このテンプレートはproduction worker processを設定しません。利用環境に合わせてSolid Queue worker、dispatcher、schedulerの起動と監視を別途構成してください。"
  end
  authentication_route_bridge = if devise
    ""
  else
    <<~RUBY
      def new_session_path
        Rails.application.routes.url_helpers.new_session_path
      end

    RUBY
  end

  environment "config.mission_control.jobs.adapters = [:solid_queue]"
  environment "config.solid_queue.connects_to = { database: { writing: :queue } }", env: "test"
  route 'mount MissionControl::Jobs::Engine, at: "/admin/jobs", as: :admin_jobs'

  create_file "config/initializers/mission_control_jobs.rb", <<~RUBY, force: true
    MissionControl::Jobs.base_controller_class = "Admin::JobOperationsController"
    MissionControl::Jobs.http_basic_auth_enabled = false
  RUBY

  create_file "app/policies/job_operation_policy.rb", <<~RUBY, force: true
    class JobOperationPolicy < ApplicationPolicy
      def manage?
        admin?
      end
    end
  RUBY

  create_file "app/controllers/admin/job_operations_controller.rb", <<~RUBY, force: true
    module Admin
      class JobOperationsController < BaseController
        include Rails.application.routes.url_helpers
        helper Rails.application.routes.url_helpers

        before_action :authorize_job_operations!

    #{authentication_route_bridge.lines.map { |line| "    #{line}" }.join}    private
          def authorize_job_operations!
            authorize! :job_operation, to: :manage?
          end
      end
    end
  RUBY

  mission_control_stylesheet_root = File.join(
    Gem::Specification.find_by_name("mission_control-jobs", "1.1.0").full_gem_path,
    "app/assets/stylesheets/mission_control/jobs"
  )
  mission_control_stylesheet = %w[bulma.min.css forms.css jobs.css].map do |filename|
    path = File.join(mission_control_stylesheet_root, filename)
    raise "Mission Control Jobs 1.1.0の公式stylesheetが見つかりません: #{path}" unless File.file?(path)

    stylesheet = File.binread(path).force_encoding(Encoding::UTF_8)
    raise "Mission Control Jobs 1.1.0の公式stylesheetがUTF-8ではありません: #{path}" unless stylesheet.valid_encoding?

    stylesheet.delete_prefix(%(@charset "UTF-8";\n))
  end.join("\n")
  create_file "app/assets/stylesheets/mission_control_jobs_scoped.css", <<~CSS, force: true
    /* Mission Control Jobs 1.1.0 official styles, scoped to the mounted engine. */
    @scope ([data-mission-control-jobs-root]) {
    #{mission_control_stylesheet}
    }
  CSS

  create_file "app/views/layouts/mission_control/jobs/application.html.erb", <<~ERB, force: true
    <% content_for :title, application_translate("job_operations.title") %>
    <% content_for :head do %>
      <style>
        @layer mission-control-foundation, theme, base, components, utilities;
        @import url("<%= asset_path("mission_control/jobs/bulma.min.css") %>") layer(mission-control-foundation);
      </style>
      <%= stylesheet_link_tag "mission_control_jobs_scoped", "data-turbo-track": "reload" %>
    <% end %>
    <% content_for :javascript_importmap do %>
      <%= javascript_importmap_tags "application", importmap: MissionControl::Jobs.importmap %>
    <% end %>
    <% content_for :admin_content do %>
      <div class="min-w-0 overflow-x-auto" data-mission-control-jobs-root>
        <%= render "layouts/mission_control/jobs/application_selection" %>
        <%= render "layouts/mission_control/jobs/navigation" %>
        <%= yield %>
      </div>
    <% end %>
    <%= render template: "layouts/admin" %>
  ERB

  create_locale_pair(
    "job_operations",
    ja: {
      "navigation" => { "job_operations" => "ジョブ運用" },
      "job_operations" => { "title" => "ジョブ運用" }
    },
    en: {
      "navigation" => { "job_operations" => "Job operations" },
      "job_operations" => { "title" => "Job operations" }
    }
  )

  append_to_file "README.md", <<~MARKDOWN

    ## ジョブ運用

    Solid QueueとMission Control Jobsによる監視、失敗確認、retry/discard、cleanupの運用方法は[ジョブ運用ガイド](docs/job_operations.md)を参照してください。
  MARKDOWN
  create_file "docs/job_operations.md", <<~MARKDOWN, force: true
    # ジョブ運用ガイド

    Mission Control Jobs 1.1.0は`/admin/jobs`で管理者だけが利用できます。guestはログイン画面へ移動し、ログイン済みの一般Userは403 Forbiddenになります。別path、HTTP Basic認証、別queue adapterは設定していません。

    ## 監視と操作

    queue、状態別job、worker、定期task、失敗内容、retry/discard状況を確認できます。失敗jobのretryは同じjobを再度queueへ戻し、discardはjobをqueue databaseから削除します。Mission Control Jobsは運用task自体を定義・開始するMaintenance Tasksとは独立しており、Maintenance Tasksは`/admin/maintenance_tasks`で管理します。

    ## 完了jobのcleanup

    Solid Queue 1.6.0の公式install generatorが生成した`config/recurring.yml`を使用します。完了jobは公式既定の1日だけ保持し、毎時12分に`SolidQueue::Job.clear_finished_in_batches(sleep_between_batches: 0.3)`でbatch削除します。独自SQL、private API、追加のcleanup jobは使用しません。

    失敗jobは`finished_at`を持たないためcleanup対象外です。管理者が原因を確認してretryまたはdiscardするまで`solid_queue_failed_executions`に保持されます。

    ## Production process

    #{production_worker}
  MARKDOWN

  create_file "test/policies/job_operation_policy_test.rb", <<~RUBY, force: true
    require "test_helper"

    class JobOperationPolicyTest < ActiveSupport::TestCase
      test "allows admins and denies regular users" do
        admin = users(:one)
        regular = users(:two)
        admin.grant_role!(:admin)

        assert JobOperationPolicy.new(:job_operation, user: admin).apply(:manage?)
        assert_not JobOperationPolicy.new(:job_operation, user: regular).apply(:manage?)
      end
    end
  RUBY

  controller_test_support = if devise
    <<~RUBY
        include Devise::Test::IntegrationHelpers

        setup do
          @admin = User.create!(email: "jobs-admin@example.com", password: "password123", password_confirmation: "password123")
          @regular = User.create!(email: "jobs-regular@example.com", password: "password123", password_confirmation: "password123")
          @admin.grant_role!(:admin)
        end

        private
          def sign_in_as(user, _key = nil)
            sign_in user
          end
    RUBY
  else
    <<~RUBY
        require "eth"

        setup do
          @admin, @admin_key = create_wallet_user
          @regular, @regular_key = create_wallet_user
          @admin.grant_role!(:admin)
        end

        private
          def create_wallet_user
            key = Eth::Key.new
            [User.create!(wallet_address: key.address.to_s), key]
          end

          def sign_in_as(_user, key)
            get session_nonce_url, headers: siwe_test_headers(key)
            nonce = response.parsed_body.fetch("nonce")
            message = Siwe::Message.new(
              domain: "www.example.com",
              address: key.address.to_s,
              uri: "http://www.example.com",
              chain_id: 1,
              nonce: nonce,
              issued_at: Time.current.iso8601,
              statement: Rails.configuration.x.application_identity.siwe_statement
            ).prepare_message
            post session_url, params: { message: message, signature: key.personal_sign(message) },
              headers: siwe_test_headers(key), as: :json
            assert_response :success
          end
    RUBY
  end

  create_file "test/controllers/admin/job_operations_controller_test.rb", <<~RUBY, force: true
    require "test_helper"

    class Admin::JobOperationsControllerTest < ActionDispatch::IntegrationTest
      class RetryProbeJob < ApplicationJob
        self.queue_adapter = :solid_queue

        def perform
          nil
        end
      end

    #{controller_test_support}
      test "requires authentication" do
        get admin_jobs_url

        assert_redirected_to #{devise ? "new_user_session_url" : "Rails.application.routes.url_helpers.new_session_path"}
      end

      test "denies regular users" do
        sign_in_as(@regular, #{devise ? "nil" : "@regular_key"})

        get admin_jobs_url

        assert_response :forbidden
      end

      test "renders the console for admins inside the admin layout" do
        sign_in_as(@admin, #{devise ? "nil" : "@admin_key"})

        get admin_jobs_url

        assert_response :success
        assert_select "[data-mission-control-jobs-root]", count: 1
        assert_select '[data-layout="admin"] nav[aria-label=?]', host_translate("navigation.admin_menu"), count: 1
        assert_select '[data-layout="admin"] a.menu-active[href=?]', Rails.application.routes.url_helpers.admin_jobs_path,
          text: host_translate("navigation.job_operations"), count: 1
      end

      test "routes every engine action through the authorized base controller" do
        controllers = MissionControl::Jobs::Engine.routes.routes.filter_map do |engine_route|
          engine_route.defaults[:controller]
        end.uniq

        assert_predicate controllers, :any?
        controllers.each do |controller_name|
          namespaced_name = controller_name.start_with?("mission_control/jobs/") ? controller_name : "mission_control/jobs/\#{controller_name}"
          controller = "\#{namespaced_name}_controller".camelize.constantize

          assert_operator controller, :<, Admin::JobOperationsController
          assert_includes controller._process_action_callbacks.map(&:filter), :authorize_job_operations!
        end
      end

      test "allows admins to retry a failed Solid Queue job" do
        sign_in_as(@admin, #{devise ? "nil" : "@admin_key"})
        active_job = RetryProbeJob.perform_later
        solid_queue_job = SolidQueue::Job.find_by!(active_job_id: active_job.job_id)
        solid_queue_job.ready_execution.destroy!
        solid_queue_job.failed_with(RuntimeError.new("expected failure"))
        application = MissionControl::Jobs.applications.first
        server = application.servers.first
        retry_path = MissionControl::Jobs::Engine.routes.url_helpers.application_job_retry_path(
          application_id: application.to_param,
          job_id: active_job.job_id,
          server_id: server.to_param
        )

        post retry_path

        assert_response :redirect
        assert_not SolidQueue::FailedExecution.exists?(job_id: solid_queue_job.id)
        assert SolidQueue::ReadyExecution.exists?(job_id: solid_queue_job.id)
      end

      private
        def host_translate(key)
          locale = Rails.configuration.x.application_identity.default_locale
          I18n.backend.translate(locale, key)
        end
    end
  RUBY

  create_file "test/models/solid_queue_cleanup_test.rb", <<~RUBY, force: true
    require "test_helper"

    class SolidQueueCleanupTest < ActiveSupport::TestCase
      class ProbeJob < ApplicationJob
        self.queue_adapter = :solid_queue

        def perform
          nil
        end
      end

      test "keeps the official one day retention and recurring cleanup" do
        recurring = YAML.safe_load_file(Rails.root.join("config/recurring.yml"), aliases: true).fetch("production")
        cleanup = recurring.fetch("clear_solid_queue_finished_jobs")

        assert_equal 1.day, SolidQueue.clear_finished_jobs_after
        assert_equal "SolidQueue::Job.clear_finished_in_batches(sleep_between_batches: 0.3)", cleanup.fetch("command")
        assert_equal "every hour at minute 12", cleanup.fetch("schedule")
      end

      test "clears only finished jobs older than the retention boundary" do
        old_finished = solid_queue_job
        recent_finished = solid_queue_job
        failed = solid_queue_job
        old_finished.update!(finished_at: 2.days.ago)
        recent_finished.update!(finished_at: 12.hours.ago)
        failed.ready_execution.destroy!
        failed.failed_with(RuntimeError.new("expected failure"))

        SolidQueue::Job.clear_finished_in_batches(finished_before: 1.day.ago, sleep_between_batches: 0)

        assert_not SolidQueue::Job.exists?(old_finished.id)
        assert SolidQueue::Job.exists?(recent_finished.id)
        assert SolidQueue::Job.exists?(failed.id)
        assert SolidQueue::FailedExecution.exists?(job_id: failed.id)
      end

      private
        def solid_queue_job
          active_job = ProbeJob.perform_later
          SolidQueue::Job.find_by!(active_job_id: active_job.job_id)
        end
    end
  RUBY
end

def install_maintenance_tasks
  devise = VALUES.fetch("account_authentication") == "devise"
  identifier_type = devise ? "email" : "wallet_address"
  identifier_expression = devise ? "authorization_user.email" : "authorization_user.wallet_address"
  production_worker = if VALUES.fetch("deployment") == "dokploy"
    "Dokployでは既存の`worker: bin/jobs --mode async`がMaintenance Taskも処理します。専用workerは追加しません。"
  else
    "このテンプレートはproduction worker processを設定しません。利用環境に合わせてSolid Queue workerの起動と監視を別途構成してください。"
  end
  authentication_route_bridge = if devise
    ""
  else
    <<~RUBY
      def new_session_path
        Rails.application.routes.url_helpers.new_session_path
      end

    RUBY
  end

  generate "maintenance_tasks:install"
  configure_maintenance_tasks_route

  create_file "config/initializers/maintenance_tasks.rb", <<~RUBY, force: true
    MaintenanceTasks.parent_controller = "Admin::MaintenanceTasksController"
    MaintenanceTasks.metadata = lambda do
      {
        "triggered_by_type" => "#{identifier_type}",
        "triggered_by_identifier" => #{identifier_expression}
      }
    end

    Rails.application.config.content_security_policy_nonce_generator = ->(_request) { SecureRandom.base64(16) }
    Rails.application.config.content_security_policy_nonce_directives = %w[script-src-elem style-src-elem]
  RUBY

  create_file "app/policies/maintenance_task_policy.rb", <<~RUBY, force: true
    class MaintenanceTaskPolicy < ApplicationPolicy
      def manage?
        admin?
      end
    end
  RUBY

  create_file "app/controllers/admin/maintenance_tasks_controller.rb", <<~RUBY, force: true
    module Admin
      class MaintenanceTasksController < BaseController
        include Rails.application.routes.url_helpers
        helper Rails.application.routes.url_helpers

        layout "maintenance_tasks/admin"

        before_action :authorize_maintenance_tasks!
        after_action :configure_maintenance_tasks_content_security_policy

    #{authentication_route_bridge.lines.map { |line| "    #{line}" }.join}    private
          def authorize_maintenance_tasks!
            authorize! :maintenance_task, to: :manage?
          end

          def configure_maintenance_tasks_content_security_policy
            request.content_security_policy.style_src_elem(
              :self,
              MaintenanceTasks::ApplicationController::BULMA_CDN
            )
            request.content_security_policy.script_src_elem(:self)
          end
      end
    end
  RUBY

  create_file "app/views/layouts/maintenance_tasks/admin.html.erb", <<~ERB, force: true
    <% content_for :title, (content_for(:page_title).presence || t("maintenance_tasks.title")) %>
    <% content_for :head do %>
      <% unless request.xhr? %>
        <%= stylesheet_link_tag "https://cdn.jsdelivr.net/npm/bulma@1.0.4/css/bulma.min.css", media: :all, integrity: "sha256-Z/om3xyp6V2PKtx8BPobFfo9JCV0cOvBDMaLmquRS+4=", crossorigin: "anonymous" %>
        <%= stylesheet_link_tag "maintenance_tasks", "data-turbo-track": "reload" %>
      <% end %>
    <% end %>
    <% content_for :admin_content do %>
      <div data-controller="maintenance-tasks-refresh" data-maintenance-tasks-root>
        <%= yield %>
      </div>
    <% end %>
    <%= render template: "layouts/admin" %>
  ERB

  create_file "app/assets/stylesheets/maintenance_tasks.css", <<~CSS, force: true
    [data-maintenance-tasks-shell="true"] {
      grid-template-columns: minmax(0, 1fr);
    }
    @media (min-width: 961px) {
      [data-maintenance-tasks-shell="true"] {
        grid-template-columns: 220px minmax(0, 1fr);
      }
    }

    [data-maintenance-tasks-root] {
      min-width: 0;
    }

    [data-maintenance-tasks-root] .ruby-comment { color: #6a737d; }
    [data-maintenance-tasks-root] .ruby-const { color: #e36209; }
    [data-maintenance-tasks-root] .ruby-embexpr-beg,
    [data-maintenance-tasks-root] .ruby-embexpr-end,
    [data-maintenance-tasks-root] .ruby-period { color: #24292e; }
    [data-maintenance-tasks-root] .ruby-ident,
    [data-maintenance-tasks-root] .ruby-symbeg { color: #6f42c1; }
    [data-maintenance-tasks-root] .ruby-ivar,
    [data-maintenance-tasks-root] .ruby-cvar,
    [data-maintenance-tasks-root] .ruby-gvar,
    [data-maintenance-tasks-root] .ruby-int,
    [data-maintenance-tasks-root] .ruby-imaginary,
    [data-maintenance-tasks-root] .ruby-float,
    [data-maintenance-tasks-root] .ruby-rational { color: #005cc5; }
    [data-maintenance-tasks-root] .ruby-kw { color: #d73a49; }
    [data-maintenance-tasks-root] .ruby-label,
    [data-maintenance-tasks-root] .ruby-tstring-beg,
    [data-maintenance-tasks-root] .ruby-tstring-content,
    [data-maintenance-tasks-root] .ruby-tstring-end { color: #032f62; }
    [data-maintenance-tasks-root] .select,
    [data-maintenance-tasks-root] select { width: 100%; }
    [data-maintenance-tasks-root] summary { cursor: pointer; }
    [data-maintenance-tasks-root] input[type="datetime-local"],
    [data-maintenance-tasks-root] input[type="date"],
    [data-maintenance-tasks-root] input[type="time"] { width: fit-content; }
    [data-maintenance-tasks-root] details > summary { list-style: none; }
    [data-maintenance-tasks-root] summary::-webkit-details-marker { display: none; }
    [data-maintenance-tasks-root] summary::before {
      content: "► ";
      position: absolute;
      font-size: 16px;
    }
    [data-maintenance-tasks-root] details[open] summary::before { content: "▼ "; }
    [data-maintenance-tasks-root] .box {
      box-shadow: 0 0 6px 0 #0000001a, 0 2px 4px -1px #0000001a;
    }
    [data-maintenance-tasks-root] .label.is-required::after {
      content: " (required)";
      color: #ff6685;
      font-size: 12px;
    }

    [data-maintenance-tasks-root] .grid.is-col-min-20 {
      grid-template-columns: repeat(auto-fit, minmax(min(20rem, 100%), 1fr));
    }
    [data-maintenance-tasks-root] .grid.is-col-min-20 > .cell {
      min-width: 0;
      width: auto;
    }

    @media (max-width: 960px) {
      [data-maintenance-tasks-root] .title.is-flex { flex-wrap: wrap; }
      [data-maintenance-tasks-root] .title.is-flex > a {
        min-width: 0;
        overflow-wrap: anywhere;
      }
      [data-maintenance-tasks-root] .title.is-flex > .tag {
        margin-inline: 0 !important;
      }
    }
  CSS

  create_file "app/javascript/controllers/maintenance_tasks_refresh_controller.js", <<~JAVASCRIPT, force: true
    import { Controller } from "@hotwired/stimulus"

    export default class extends Controller {
      connect() {
        this.scheduleRefresh()
      }

      disconnect() {
        window.clearTimeout(this.timeout)
        this.abortController?.abort()
      }

      scheduleRefresh() {
        window.clearTimeout(this.timeout)
        const target = this.element.querySelector("[data-refresh]")
        if (!target?.dataset.refresh) return

        this.timeout = window.setTimeout(() => this.refresh(target), 3000)
      }

      async refresh(target) {
        this.abortController = new AbortController()
        this.element.style.cursor = "wait"

        try {
          const response = await fetch(window.location.href, {
            headers: { "X-Requested-With": "XMLHttpRequest" },
            credentials: "same-origin",
            signal: this.abortController.signal
          })
          if (!response.ok) throw new Error(`Maintenance Tasks refresh failed: ${response.status}`)

          const document = new DOMParser().parseFromString(await response.text(), "text/html")
          const replacement = document.querySelector("[data-maintenance-tasks-root] [data-refresh]")
          if (replacement) target.replaceWith(replacement)
        } catch (error) {
          if (error.name !== "AbortError") console.error(error)
        } finally {
          this.element.style.cursor = ""
          this.abortController = null
          this.scheduleRefresh()
        }
      }
    }
  JAVASCRIPT

  create_locale_pair(
    "maintenance_tasks",
    ja: {
      "navigation" => { "maintenance_tasks" => "運用タスク" },
      "maintenance_tasks" => { "title" => "運用タスク" }
    },
    en: {
      "navigation" => { "maintenance_tasks" => "Maintenance tasks" },
      "maintenance_tasks" => { "title" => "Maintenance tasks" }
    }
  )

  append_to_file "README.md", <<~MARKDOWN

    ## Maintenance Tasks

    管理者向け運用タスクの追加方法と安全な運用ルールは[Maintenance Tasks運用ガイド](docs/maintenance_tasks.md)を参照してください。
  MARKDOWN
  create_file "docs/maintenance_tasks.md", <<~MARKDOWN, force: true
    # Maintenance Tasks運用ガイド

    Maintenance Tasksは`/admin/maintenance_tasks`で管理者だけが利用できます。guestはログイン画面へ移動し、ログイン済みの一般Userは403 Forbiddenになります。

    ## Taskの追加

    `bin/rails generate maintenance_tasks:task NAME`を実行し、`app/tasks/maintenance/`へ生成されたTaskへ、再実行可能で小さな単位の処理を実装してください。ブラウザから任意のRubyコードを入力・実行する機能はありません。

    実行履歴、status、cursor、job ID、arguments、metadata、error class/message/backtraceは`maintenance_tasks_runs`へGem標準形式で保存されます。実行者はRun metadataの`triggered_by_type`と`triggered_by_identifier`へ実行時点の#{identifier_type}をスナップショットとして保存します。User recordとの関連は持たないため、User削除後も履歴は維持されます。

    ## Worker

    Maintenance TaskはSolid Queueへenqueueされ、同期実行へ切り替わりません。#{production_worker}

    ## 秘密情報

    arguments、metadata、例外message、backtraceは永続化され、管理画面へ表示されます。password、token、秘密鍵、API credentialなどの秘密情報をargumentやmetadataへ渡さず、例外messageにも含めないでください。
  MARKDOWN

  create_file "test/support/maintenance_tasks/safe_test_task.rb", <<~RUBY, force: true
    module Maintenance
      class SafeTestTask < MaintenanceTasks::Task
        no_collection

        def process
          nil
        end
      end
    end
  RUBY
  append_to_file "test/test_helper.rb", <<~RUBY

    require_relative "support/maintenance_tasks/safe_test_task"
  RUBY

  create_file "test/policies/maintenance_task_policy_test.rb", <<~RUBY, force: true
    require "test_helper"

    class MaintenanceTaskPolicyTest < ActiveSupport::TestCase
      test "allows admins and denies regular users" do
        admin = users(:one)
        regular = users(:two)
        admin.grant_role!(:admin)

        assert MaintenanceTaskPolicy.new(:maintenance_task, user: admin).apply(:manage?)
        assert_not MaintenanceTaskPolicy.new(:maintenance_task, user: regular).apply(:manage?)
      end
    end
  RUBY

  controller_test_support = if devise
    <<~RUBY
        include ActiveJob::TestHelper
        include Devise::Test::IntegrationHelpers

        setup do
          @admin = User.create!(email: "maintenance-admin@example.com", password: "password123", password_confirmation: "password123")
          @regular = User.create!(email: "maintenance-regular@example.com", password: "password123", password_confirmation: "password123")
          @admin.grant_role!(:admin)
        end

        private
          def sign_in_as(user, _key = nil)
            sign_in user
          end
    RUBY
  else
    <<~RUBY
        require "eth"

        include ActiveJob::TestHelper

        setup do
          @admin, @admin_key = create_wallet_user
          @regular, @regular_key = create_wallet_user
          @admin.grant_role!(:admin)
        end

        private
          def create_wallet_user
            key = Eth::Key.new
            [User.create!(wallet_address: key.address.to_s), key]
          end

          def sign_in_as(_user, key)
            get session_nonce_url, headers: siwe_test_headers(key)
            nonce = response.parsed_body.fetch("nonce")
            message = Siwe::Message.new(
              domain: "www.example.com",
              address: key.address.to_s,
              uri: "http://www.example.com",
              chain_id: 1,
              nonce: nonce,
              issued_at: Time.current.iso8601,
              statement: Rails.configuration.x.application_identity.siwe_statement
            ).prepare_message
            post session_url, params: { message: message, signature: key.personal_sign(message) },
              headers: siwe_test_headers(key), as: :json
            assert_response :success
          end
    RUBY
  end

  create_file "test/controllers/admin/maintenance_tasks_controller_test.rb", <<~RUBY, force: true
    require "test_helper"
    require "cgi"

    class Admin::MaintenanceTasksControllerTest < ActionDispatch::IntegrationTest
      TASK_NAME = "Maintenance::SafeTestTask"
      TASK_PATH = "/admin/maintenance_tasks/tasks/\#{CGI.escapeURIComponent(TASK_NAME)}"
      RUNS_PATH = "\#{TASK_PATH}/runs"

    #{controller_test_support}
      test "requires authentication" do
        get admin_maintenance_tasks_url

        assert_redirected_to #{devise ? "new_user_session_url" : "Rails.application.routes.url_helpers.new_session_path"}
      end

      test "denies every engine operation to regular users" do
        sign_in_as(@regular, #{devise ? "nil" : "@regular_key"})

        get admin_maintenance_tasks_url
        assert_response :forbidden
        get TASK_PATH
        assert_response :forbidden
        post RUNS_PATH
        assert_response :forbidden
        %w[pause cancel resume].each do |action|
          post "\#{RUNS_PATH}/0/\#{action}"
          assert_response :forbidden
        end
        assert_empty MaintenanceTasks::Run.all
      end

      test "renders the task list and details for admins" do
        sign_in_as(@admin, #{devise ? "nil" : "@admin_key"})

        get admin_maintenance_tasks_url
        assert_response :success
        assert_select "[data-maintenance-tasks-root]", count: 1
        assert_select '[data-layout="admin"] nav[aria-label=?]', I18n.t("navigation.admin_menu"), count: 1
        assert_select '[data-layout="admin"] a.menu-active[href=?]', Rails.application.routes.url_helpers.admin_maintenance_tasks_path,
          text: I18n.t("navigation.maintenance_tasks"), count: 1

        get TASK_PATH
        assert_response :success
        assert_select "[data-maintenance-tasks-root]", count: 1
      end

      test "enqueues and executes a task while preserving standard run history" do
        sign_in_as(@admin, #{devise ? "nil" : "@admin_key"})

        assert_enqueued_with(job: MaintenanceTasks::TaskJob) do
          post RUNS_PATH
        end
        assert_response :redirect

        run = MaintenanceTasks::Run.order(:id).last
        assert_predicate run.job_id, :present?
        assert_equal "enqueued", run.status
        assert_equal "#{identifier_type}", run.metadata.fetch("triggered_by_type")
        assert_equal @admin.#{devise ? "email" : "wallet_address"}, run.metadata.fetch("triggered_by_identifier")

        perform_enqueued_jobs

        assert_equal "succeeded", run.reload.status
        assert_predicate run.started_at, :present?
        assert_predicate run.ended_at, :present?
        assert_equal 1, MaintenanceTasks::Run.where(task_name: TASK_NAME).count
      end
    end
  RUBY
end

def configure_common_files
  require "playwright"
  playwright_version = Playwright::COMPATIBLE_PLAYWRIGHT_VERSION.strip
  run_checked "npm install --save-dev playwright@#{playwright_version}"
  create_file "config/initializers/pagy.rb", "Pagy::DEFAULT.freeze\n"
  create_file "config/initializers/sentry.rb", <<~RUBY
    Sentry.init do |config|
      config.dsn = ENV["SENTRY_DSN"]
      config.enabled_environments = %w[production]
    end
  RUBY
  create_file "test/application_system_test_case.rb", <<~RUBY
    require "test_helper"

    class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
      driven_by :playwright,
        using: :chromium,
        screen_size: [1400, 900],
        options: {
          headless: true,
          playwright_cli_executable_path: Rails.root.join("node_modules/.bin/playwright").to_s
        }
    end
  RUBY
  create_file "test/support/factory_bot.rb", "ActiveSupport.on_load(:active_support_test_case) { include FactoryBot::Syntax::Methods }\n"
  append_to_file "test/test_helper.rb", "\nrequire_relative \"support/factory_bot\"\n"
end

def configure_evidence_capture
  authentication = VALUES.fetch("account_authentication") == "devise" ? "devise" : "siwe"
  image_delivery = VALUES.fetch("image_delivery")
  web_push = VALUES.fetch("web_push") == "use"
  job_operations = VALUES.fetch("job_operations") == "enable"
  maintenance_tasks = VALUES.fetch("maintenance_tasks") == "enable"
  runner = <<~'RUBY'
    # frozen_string_literal: true

    require "application_system_test_case"
    require "digest"
    require "fileutils"
    require "json"
    require "uri"

    class EvidenceCapture < ApplicationSystemTestCase
      self.use_transactional_tests = false

      AUTHENTICATION = __AUTHENTICATION__
      IMAGE_DELIVERY = __IMAGE_DELIVERY__
      LOCALE = I18n.default_locale.to_s
      WEB_PUSH = __WEB_PUSH__
      JOB_OPERATIONS = __JOB_OPERATIONS__
      MAINTENANCE_TASKS = __MAINTENANCE_TASKS__
      if IMAGE_DELIVERY == "imgproxy"
        Capybara.server_host = "0.0.0.0"
        Capybara.server_port = 45_678
        Capybara.app_host = "http://127.0.0.1:45678"
      end
      require "eth" if AUTHENTICATION == "siwe"
      VIEWPORTS = {
        "desktop" => { "width" => 1400, "height" => 900 },
        "mobile" => { "width" => 390, "height" => 844 }
      }.freeze
      PRIVATE_KEY = "1".rjust(64, "0")
      REGULAR_PRIVATE_KEY = "2".rjust(64, "0")
      PASSWORD = "password123"

      test "captures every generated page and key visual state" do
        @output_directory = Pathname(ENV.fetch("EVIDENCE_OUTPUT_DIR")).expand_path
        raise "EVIDENCE_OUTPUT_DIR must be an existing empty directory" unless @output_directory.directory? && @output_directory.children.empty?

        @captures = []
        VIEWPORTS.each do |viewport_name, viewport|
          page.current_window.resize_to(viewport.fetch("width"), viewport.fetch("height"))
          install_web_push_stub if WEB_PUSH
          prepare_guest_data
          verify_footer_geometry if viewport_name == "desktop"
          capture_guest_pages(viewport_name)
          authenticate
          prepare_authenticated_data
          verify_admin_layout_geometry if viewport_name == "desktop"
          verify_job_operations_geometry if viewport_name == "desktop" && JOB_OPERATIONS
          verify_maintenance_tasks_geometry if viewport_name == "desktop" && MAINTENANCE_TASKS
          capture_authenticated_pages(viewport_name)
          capture_regular_user_navigation(viewport_name)
          Capybara.reset_sessions!
        end

        File.write(
          @output_directory.join("captures.json"),
          JSON.pretty_generate(
            "authentication" => AUTHENTICATION,
            "locale" => LOCALE,
            "image_delivery" => IMAGE_DELIVERY,
            "viewports" => VIEWPORTS,
            "captures" => @captures
          ) + "\n"
        )
      end

      private
        def devise?
          AUTHENTICATION == "devise"
        end

        def translate(key, **options)
          I18n.t(key, **options)
        end

        def host_translate(key, **options)
          locale = Rails.configuration.x.application_identity.default_locale
          I18n.backend.translate(locale, key, **options)
        end

        def host_routes
          Rails.application.routes.url_helpers
        end

        def prepare_guest_data
          Page.find_by!(slug: "about").update!(
            content: <<~HTML
              <p>#{Page::TITLES.fetch("about")}は、Railsアプリケーションをすばやく始めるためのテンプレートです。</p>
              <p>管理画面から更新したAction Text本文を表示しています。</p>
            HTML
          )
          @evidence_faq = Faq.find_or_initialize_by(question: "サービスはどのように使えますか？")
          @evidence_faq.update!(
            answer: "<p>アカウントを作成し、マイページから各機能をご利用ください。</p>",
            position: 10,
            published: true
          )
          Faq.find_or_initialize_by(question: "公開前の質問").update!(
            answer: "<p>この回答は公開画面には表示されません。</p>",
            position: 0,
            published: false
          )
          FooterSetting.default_record.update!(
            x_url: "https://x.com/example",
            github_url: "https://github.com/example/example"
          )

          return unless devise?

          @user = User.find_or_create_by!(email: "evidence@example.com") do |user|
            user.password = PASSWORD
            user.password_confirmation = PASSWORD
          end
          @user.profile.update!(screen_name: "evidence_user", display_name: "Evidence User")
        end

        def capture_guest_pages(viewport)
          capture_page("home-guest", "ホーム（未ログイン）", root_path, translate("home.heading"), viewport)
          capture_page("about", "アプリについて", about_path, Page::TITLES.fetch("about"), viewport)
          assert_selector ".lexxy-content", text: "管理画面から更新したAction Text本文"
          capture_faq_page(viewport)
          login_path = devise? ? new_user_session_path : new_session_path
          login_heading = devise? ? translate("devise_views.sessions.title") : translate("wallet_siwe.title")
          capture_page("login", login_heading, login_path, login_heading, viewport)

          if devise?
            capture_page("registration", "アカウント作成", new_user_registration_path, translate("devise_views.registrations.new_title"), viewport)
            capture_page("password-reset-request", "パスワード再設定", new_user_password_path, translate("devise_views.passwords.new_title"), viewport)
            reset_token = @user.send_reset_password_instructions
            capture_page(
              "password-reset-edit",
              translate("devise_views.passwords.edit_title"),
              edit_user_password_path(reset_password_token: reset_token),
              translate("devise_views.passwords.edit_title"),
              viewport
            )
          end

          return unless viewport == "mobile"

          visit root_path
          find("header details.dropdown > summary", visible: :visible).click
          capture_current_page("navigation-guest-open", "モバイルメニュー（未ログイン）", viewport)
        end

        def authenticate
          if devise?
            visit new_user_session_path
            fill_in User.human_attribute_name(:email), with: @user.email
            fill_in User.human_attribute_name(:password), with: PASSWORD
            click_button translate("devise_views.sessions.submit")
            assert_current_path root_path
          else
            authenticate_wallet_siwe
          end
        end

        def authenticate_wallet_siwe(private_key = PRIVATE_KEY)
          visit root_path
          browser_uri = URI(page.current_url)
          integration = ActionDispatch::Integration::Session.new(Rails.application)
          integration.host! browser_uri.host + (browser_uri.port == 80 ? "" : ":#{browser_uri.port}")
          key = Eth::Key.new(priv: private_key)
          integration.get "/session/nonce", headers: siwe_test_headers(key)
          assert_equal 200, integration.response.status

          nonce = integration.response.parsed_body.fetch("nonce")
          origin = "#{browser_uri.scheme}://#{browser_uri.host}:#{browser_uri.port}"
          message = Siwe::Message.new(
            domain: browser_uri.host + (browser_uri.port == 80 ? "" : ":#{browser_uri.port}"),
            address: key.address.to_s,
            uri: origin,
            chain_id: 1,
            nonce: nonce,
            issued_at: Time.zone.parse("2026-01-01 00:00:00 UTC").iso8601,
            statement: Rails.configuration.x.application_identity.siwe_statement
          ).prepare_message
          integration.post "/session", params: { message: message, signature: key.personal_sign(message) },
            headers: siwe_test_headers(key), as: :json
          assert_equal 200, integration.response.status

          cookie = integration.cookies.to_hash.fetch("session_id")
          page.driver.with_playwright_page do |playwright_page|
            playwright_page.context.add_cookies([{ name: "session_id", value: cookie, url: origin }])
          end
          visit root_path
          @user = User.find_by!(wallet_address: key.address.to_s.downcase)
        end

        def prepare_authenticated_data
          @user.profile.update!(screen_name: "evidence_user", display_name: "Evidence User")
          @user.profile.avatar.purge if @user.profile.avatar.attached?
          @user.grant_role!(:admin)
          identifier = devise? ? { email: "member@example.com", password: PASSWORD, password_confirmation: PASSWORD } :
            { wallet_address: Eth::Key.new(priv: REGULAR_PRIVATE_KEY).address.to_s.downcase }
          @regular_user = User.find_or_create_by!(identifier.slice(devise? ? :email : :wallet_address)) do |user|
            identifier.each { |name, value| user.public_send("#{name}=", value) }
          end
        end

        def capture_authenticated_pages(viewport)
          capture_page("home-authenticated", "ホーム（ログイン済み）", root_path, translate("home.heading"), viewport)
          capture_page("account", "マイページ", account_path, translate("accounts.show.title"), viewport)
          assert_account_navigation_scope
          capture_avatar_states(viewport)
          account_settings_path = devise? ? edit_user_registration_path : edit_account_path
          account_settings_heading = devise? ? translate("devise_views.registrations.edit_title") : translate("accounts.edit.title")
          capture_page("account-settings", "アカウント設定", account_settings_path, account_settings_heading, viewport)
          capture_page("notifications", "通知", notification_path, translate("web_push.page.title"), viewport)
          capture_enabled_web_push(viewport) if WEB_PUSH

          @user.api_credentials.destroy_all
          capture_page("api-credentials-empty", "APIキー一覧（空）", api_credentials_path, translate("api_credentials.title"), viewport)
          capture_page("api-credential-new", "APIキー作成", new_api_credential_path, translate("api_credentials.new"), viewport)
          fill_in ApiCredential.human_attribute_name(:name), with: "Evidence CLI"
          with_deterministic_secure_random do
            find('input[type="submit"]').click
          end
          assert_text translate("api_credentials.secret_once")
          capture_current_page("api-credential-secret", "APIキー詳細（初回secret）", viewport)
          credential = @user.api_credentials.find_by!(name: "Evidence CLI")
          capture_page("api-credential-show", "APIキー詳細", api_credential_path(credential), "Evidence CLI", viewport)
          capture_page("api-credential-edit", "APIキー編集", edit_api_credential_path(credential), translate("api_credentials.edit"), viewport)
          capture_page("api-credentials-populated", "APIキー一覧（登録済み）", api_credentials_path, translate("api_credentials.title"), viewport)
          capture_page("admin-users", "ユーザー管理", admin_users_path, translate("admin.users.title"), viewport)
          assert_admin_navigation_active(translate("navigation.users"))
          if JOB_OPERATIONS
            visit host_routes.admin_jobs_path
            assert_equal 200, page.status_code
            assert_selector "[data-mission-control-jobs-root]", count: 1
            assert_admin_navigation_active(host_translate("navigation.job_operations"))
            capture_current_page("admin-job-operations", host_translate("job_operations.title"), viewport)
            if viewport == "mobile"
              find("header details.dropdown > summary", visible: :visible).click
              capture_current_page(
                "admin-job-operations-navigation-open",
                "#{host_translate('job_operations.title')}のモバイルメニュー",
                viewport
              )
            end
          end
          if MAINTENANCE_TASKS
            visit host_routes.admin_maintenance_tasks_path
            assert_equal 200, page.status_code
            assert_selector "[data-maintenance-tasks-root]", count: 1
            assert_admin_navigation_active(translate("navigation.maintenance_tasks"))
            capture_current_page("admin-maintenance-tasks", "運用タスク", viewport)
            if viewport == "mobile"
              find("header details.dropdown > summary", visible: :visible).click
              capture_current_page(
                "admin-maintenance-tasks-navigation-open",
                "運用タスクのモバイルメニュー",
                viewport
              )
            end
          end
          capture_page(
            "admin-page-edit",
            "固定ページ編集",
            edit_admin_page_path(Page.find_by!(slug: "about")),
            Page::TITLES.fetch("about"),
            viewport
          )
          assert_admin_navigation_active(translate("navigation.pages"))
          assert_selector "lexxy-editor"
          capture_page(
            "admin-faq-edit",
            "FAQ編集",
            edit_admin_faq_path(@evidence_faq),
            translate("content_management.admin.faqs.edit"),
            viewport
          )
          assert_admin_navigation_active(translate("navigation.faqs"))
          assert_selector "lexxy-editor"
          capture_page(
            "admin-footer-setting",
            translate("content_management.admin.footer_settings.title"),
            edit_admin_footer_setting_path,
            translate("content_management.admin.footer_settings.title"),
            viewport
          )
          assert_admin_navigation_active(translate("content_management.admin.footer_settings.title"))

          return unless viewport == "mobile"

          visit root_path
          find("header details.dropdown > summary", visible: :visible).click
          capture_current_page("navigation-authenticated-open", "モバイルメニュー（ログイン済み）", viewport)
        end

        def capture_regular_user_navigation(viewport)
          Capybara.reset_sessions!
          viewport_size = VIEWPORTS.fetch(viewport)
          page.current_window.resize_to(viewport_size.fetch("width"), viewport_size.fetch("height"))
          if devise?
            visit new_user_session_path
            fill_in User.human_attribute_name(:email), with: @regular_user.email
            fill_in User.human_attribute_name(:password), with: PASSWORD
            click_button translate("devise_views.sessions.submit")
            assert_current_path root_path
            @user = @regular_user
          else
            authenticate_wallet_siwe(REGULAR_PRIVATE_KEY)
            assert_equal @regular_user, @user
          end

          visit root_path
          find("header details.dropdown > summary", visible: :visible).click if viewport == "mobile"
          assert_no_selector %(header a[href="#{host_routes.admin_users_path}"]), visible: :all
          assert_no_selector %(header a[href="#{host_routes.admin_jobs_path}"]), visible: :all if JOB_OPERATIONS
          assert_no_selector %(header a[href="#{host_routes.admin_maintenance_tasks_path}"]), visible: :all if MAINTENANCE_TASKS
          capture_current_page("navigation-regular-user", "一般Userのナビゲーション", viewport)
        end

        def capture_page(identifier, title, path, heading, viewport)
          visit path
          assert_equal 200, page.status_code
          assert_selector "h1", text: heading
          capture_current_page(identifier, title, viewport)
        end

        def capture_avatar_states(viewport)
          capture_page("profile-boring-avatar", "プロフィール（自動生成アバター）", profile_path, translate("profiles.title"), viewport)
          capture_page("profile-edit-boring-avatar", "プロフィール編集（自動生成アバター）", edit_profile_path, translate("profiles.edit_title"), viewport)

          @user.profile.update!(avatar_upload: AvatarTestImage.upload(width: 320, height: 180))
          capture_page("home-uploaded-avatar", "ホーム（画像アバター）", root_path, translate("home.heading"), viewport)
          assert_avatar_image_geometry(40)
          capture_page("profile-uploaded-avatar", "プロフィール（画像アバター）", profile_path, translate("profiles.title"), viewport)
          assert_avatar_image_geometry(40, 64)
          capture_page("profile-edit-uploaded-avatar", "プロフィール編集（画像アバター）", edit_profile_path, translate("profiles.edit_title"), viewport)
          assert_avatar_image_geometry(40, 64)

          accept_confirm { click_button translate("profiles.avatar_delete") }
          assert_current_path profile_path
          assert_selector ".alert.alert-success", text: translate("profiles.avatar.destroy.notice")
          capture_current_page("profile-avatar-deleted", "プロフィール（画像削除後）", viewport)
          capture_page("home-avatar-deleted", "ホーム（画像削除後）", root_path, translate("home.heading"), viewport)
        end

        def assert_avatar_image_geometry(*sizes)
          geometry = page.driver.with_playwright_page do |playwright_page|
            javascript = <<~JAVASCRIPT
              () => {
                const expectedSizes = __EXPECTED_SIZES__
                return {
                documentWidth: document.documentElement.scrollWidth,
                viewportWidth: window.innerWidth,
                images: expectedSizes.map((size) => {
                  const image = document.querySelector(`img[width="${size}"][height="${size}"]`)
                  if (!image) return null
                  const bounds = image.getBoundingClientRect()
                  return {
                    expectedSize: size,
                    naturalWidth: image.naturalWidth,
                    naturalHeight: image.naturalHeight,
                    renderedWidth: bounds.width,
                    renderedHeight: bounds.height
                  }
                })
                }
              }
            JAVASCRIPT
            playwright_page.evaluate(javascript.sub("__EXPECTED_SIZES__", JSON.generate(sizes)))
          end

          assert_operator geometry.fetch("documentWidth"), :<=, geometry.fetch("viewportWidth"),
            "avatar page must not overflow horizontally"
          geometry.fetch("images").each do |image|
            assert_not_nil image, "expected an attached avatar image"
            size = image.fetch("expectedSize")
            assert_equal size, image.fetch("naturalWidth"), "avatar variant width"
            assert_equal size, image.fetch("naturalHeight"), "avatar variant height"
            assert_in_delta size, image.fetch("renderedWidth"), 0.5, "rendered avatar width"
            assert_in_delta size, image.fetch("renderedHeight"), 0.5, "rendered avatar height"
          end
        end

        def capture_enabled_web_push(viewport)
          install_evidence_csrf_token
          toggle = find('[data-push-subscription-target="toggle"]')
          assert_not toggle.checked?
          toggle.click
          assert_selector '[data-push-subscription-target="status"].alert-success', text: translate("web_push.client.enabled")
          assert_selector '[data-push-subscription-target="testButton"]:not([disabled])', text: translate("web_push.page.send_test")
          capture_current_page("web-push-enabled", "Web Push（購読済み・テスト通知可能）", viewport)

          find('[data-push-subscription-target="testButton"]').click
          assert_selector '[data-push-subscription-target="status"].alert-success', text: translate("web_push.client.test_sent")

          set_evidence_web_push_mode("rotated")
          visit notification_path
          install_evidence_csrf_token
          assert_selector '[data-push-subscription-target="status"].alert-success',
            text: translate("web_push.client.reconciled")
          assert_equal({ "subscribeCount" => 1, "unsubscribeCount" => 1, "subscribed" => true,
                         "permissionRequests" => 0 }, evidence_web_push_stats)

          find('[data-push-subscription-target="toggle"]').click
          assert_selector '[data-push-subscription-target="status"].alert-info',
            text: translate("web_push.client.disabled")
          assert_equal false, evidence_web_push_stats.fetch("subscribed")

          set_evidence_web_push_mode("default")
          visit notification_path
          install_evidence_csrf_token
          find('[data-push-subscription-target="toggle"]').click
          assert_selector '[data-push-subscription-target="status"].alert-success',
            text: translate("web_push.client.enabled")
          assert_equal 1, evidence_web_push_stats.fetch("permissionRequests")

          set_evidence_web_push_mode("denied")
          visit notification_path
          assert_selector '[data-push-subscription-target="status"].alert-warning',
            text: translate("web_push.client.blocked")
          assert find('[data-push-subscription-target="toggle"]').disabled?

          set_evidence_web_push_mode("unsupported")
          visit notification_path
          assert_selector '[data-push-subscription-target="status"].alert-warning',
            text: translate("web_push.client.unsupported")
          assert find('[data-push-subscription-target="toggle"]').disabled?
        ensure
          page.execute_script('localStorage.removeItem("evidence-web-push-mode")')
        end

        def install_evidence_csrf_token
          page.execute_script(<<~JAVASCRIPT)
            if (!document.querySelector('meta[name="csrf-token"]')) {
              const csrf = document.createElement("meta")
              csrf.name = "csrf-token"
              csrf.content = "evidence-csrf-token"
              document.head.appendChild(csrf)
            }
          JAVASCRIPT
        end

        def set_evidence_web_push_mode(mode)
          page.execute_script("localStorage.setItem('evidence-web-push-mode', #{mode.to_json})")
        end

        def evidence_web_push_stats
          page.evaluate_script("window.__evidencePush.stats()")
        end

        def install_web_push_stub
          page.driver.with_playwright_page do |playwright_page|
            playwright_page.add_init_script(script: <<~JAVASCRIPT)
              (() => {
                const installCsrfToken = () => {
                  if (!document.head) return false
                  if (!document.querySelector('meta[name="csrf-token"]')) {
                    const csrf = document.createElement("meta")
                    csrf.name = "csrf-token"
                    csrf.content = "evidence-csrf-token"
                    document.head.appendChild(csrf)
                  }
                  return true
                }
                if (!installCsrfToken()) {
                  const csrfObserver = new MutationObserver(() => {
                    if (installCsrfToken()) csrfObserver.disconnect()
                  })
                  csrfObserver.observe(document, { childList: true, subtree: true })
                }

                let mode = "granted"
                try {
                  mode = localStorage.getItem("evidence-web-push-mode") || mode
                } catch (error) {
                  console.debug("Web Push evidence mode is unavailable for this origin", error)
                }

                if (mode === "unsupported") {
                  Object.defineProperty(window, "Notification", { configurable: true, value: undefined })
                  Object.defineProperty(window, "PushManager", { configurable: true, value: undefined })
                  Object.defineProperty(navigator, "serviceWorker", { configurable: true, value: undefined })
                  return
                }

                let subscription = null
                let subscribeCount = 0
                let unsubscribeCount = 0
                let permissionRequests = 0
                const buildSubscription = (applicationServerKey) => {
                  const current = {
                    endpoint: `https://push.example.com/evidence-${window.innerWidth}`,
                    options: { applicationServerKey },
                    async unsubscribe() {
                      unsubscribeCount += 1
                      if (subscription === current) subscription = null
                      return true
                    },
                    toJSON() {
                      return {
                        endpoint: this.endpoint,
                        keys: { p256dh: "evidence-p256dh", auth: "evidence-auth" }
                      }
                    }
                  }
                  return current
                }

                if (mode === "rotated") subscription = buildSubscription(new Uint8Array([0]))

                const pushManager = {
                  async getSubscription() {
                    return subscription
                  },
                  async subscribe({ applicationServerKey }) {
                    subscribeCount += 1
                    subscription = buildSubscription(applicationServerKey)
                    return subscription
                  }
                }
                const registration = { pushManager }
                const notification = {
                  permission: mode === "denied" ? "denied" : mode === "default" ? "default" : "granted",
                  async requestPermission() {
                    permissionRequests += 1
                    this.permission = "granted"
                    return this.permission
                  }
                }

                window.__evidencePush = {
                  stats() {
                    return { subscribeCount, unsubscribeCount, subscribed: Boolean(subscription), permissionRequests }
                  }
                }

                Object.defineProperty(window, "Notification", {
                  configurable: true,
                  value: notification
                })
                Object.defineProperty(window, "PushManager", { configurable: true, value: class PushManager {} })
                Object.defineProperty(navigator, "serviceWorker", {
                  configurable: true,
                  value: { register: async () => registration }
                })
              })()
            JAVASCRIPT
          end
        end

        def assert_admin_navigation_active(label)
          assert_selector %([data-layout="admin"] nav[aria-label="#{host_translate("navigation.admin_menu")}"])
          assert_selector %([data-layout="admin"] nav[aria-label="#{host_translate("navigation.admin_menu")}"] li.menu-title), text: host_translate("navigation.admin"), count: 1
          assert_no_selector %([data-layout="admin"] nav[aria-label="#{host_translate("navigation.account_menu")}"])
          assert_selector '[data-layout="admin"] a.menu-active[aria-current="page"]', text: label, count: 1
          assert_selector 'header li.menu-title', text: host_translate("navigation.admin"), count: 1, visible: :all
          assert_no_selector %(header a[href="\#{account_path}"]), visible: :all
        end

        def assert_account_navigation_scope
          assert_selector %([data-layout="account"] nav[aria-label="#{translate("navigation.account_menu")}"])
          assert_no_selector %([data-layout="account"] nav[aria-label="#{translate("navigation.admin_menu")}"])
          assert_no_selector 'header li.menu-title', text: translate("navigation.admin"), visible: :all
          assert_no_selector %(header a[href="\#{admin_users_path}"]), visible: :all
        end

        def capture_faq_page(viewport)
          visit faq_path
          assert_equal 200, page.status_code
          assert_selector "h1", text: translate("content_management.faqs.title")
          find("details.collapse > summary", text: @evidence_faq.question).click
          assert_selector "details[open] .lexxy-content", text: "アカウントを作成し"
          assert_no_text "公開前の質問"
          capture_current_page("faq", "よくある質問", viewport)
        end

        def verify_footer_geometry
          {
            320 => "row",
            640 => "column",
            960 => "column",
            961 => "column"
          }.each do |width, expected_flow|
            page.current_window.resize_to(width, 900)
            visit root_path
            geometry = page.driver.with_playwright_page do |playwright_page|
              playwright_page.evaluate(<<~JAVASCRIPT)
                () => {
                  const footer = document.querySelector("footer.footer")
                  return {
                    flow: getComputedStyle(footer).gridAutoFlow,
                    documentWidth: document.documentElement.scrollWidth,
                    viewportWidth: window.innerWidth
                  }
                }
              JAVASCRIPT
            end

            assert_equal expected_flow, geometry.fetch("flow"), "footer layout at #{width}px"
            assert_operator geometry.fetch("documentWidth"), :<=, geometry.fetch("viewportWidth"),
              "horizontal overflow at #{width}px"
          end
        ensure
          desktop = VIEWPORTS.fetch("desktop")
          page.current_window.resize_to(desktop.fetch("width"), desktop.fetch("height"))
        end

        def verify_admin_layout_geometry
          [320, 640, 960, 961].each do |width|
            page.current_window.resize_to(width, 900)
            visit admin_pages_path
            geometry = page.driver.with_playwright_page do |playwright_page|
              playwright_page.evaluate(<<~JAVASCRIPT)
                () => {
                  const layout = document.querySelector('[data-layout="admin"]')
                  const sidebar = layout.querySelector(':scope > aside').getBoundingClientRect()
                  const content = layout.querySelector(':scope > div').getBoundingClientRect()
                  return {
                    documentWidth: document.documentElement.scrollWidth,
                    viewportWidth: window.innerWidth,
                    sidebarTop: sidebar.top,
                    sidebarBottom: sidebar.bottom,
                    sidebarRight: sidebar.right,
                    contentTop: content.top,
                    contentLeft: content.left
                  }
                }
              JAVASCRIPT
            end

            assert_operator geometry.fetch("documentWidth"), :<=, geometry.fetch("viewportWidth"),
              "admin layout horizontal overflow at #{width}px"
            if width < 961
              assert_operator geometry.fetch("contentTop"), :>=, geometry.fetch("sidebarBottom"),
                "admin layout should use one column at #{width}px"
            else
              assert_in_delta geometry.fetch("sidebarTop"), geometry.fetch("contentTop"), 0.5
              assert_operator geometry.fetch("contentLeft"), :>=, geometry.fetch("sidebarRight"),
                "admin layout should use two columns at #{width}px"
            end
          end
        ensure
          desktop = VIEWPORTS.fetch("desktop")
          page.current_window.resize_to(desktop.fetch("width"), desktop.fetch("height"))
        end

        def verify_job_operations_geometry
          [320, 390, 640, 960, 961].each do |width|
            page.current_window.resize_to(width, 900)
            visit host_routes.admin_jobs_path
            assert_equal 200, page.status_code
            assert_selector "[data-mission-control-jobs-root]", count: 1
            assert_admin_navigation_active(host_translate("navigation.job_operations"))

            geometry = page.driver.with_playwright_page do |playwright_page|
              playwright_page.evaluate(<<~JAVASCRIPT)
                () => {
                  const root = document.querySelector("[data-mission-control-jobs-root]")
                  return {
                    documentWidth: document.documentElement.scrollWidth,
                    viewportWidth: window.innerWidth,
                    rootWidth: root.getBoundingClientRect().width,
                    rootScrollWidth: root.scrollWidth,
                    rootClientWidth: root.clientWidth
                  }
                }
              JAVASCRIPT
            end

            assert_operator geometry.fetch("documentWidth"), :<=, geometry.fetch("viewportWidth"),
              "Mission Control Jobs page overflow at #{width}px"
            assert_operator geometry.fetch("rootWidth"), :>, 0,
              "Mission Control Jobs content should be visible at #{width}px"
            assert_operator geometry.fetch("rootScrollWidth"), :>=, geometry.fetch("rootClientWidth")
          end
        ensure
          desktop = VIEWPORTS.fetch("desktop")
          page.current_window.resize_to(desktop.fetch("width"), desktop.fetch("height"))
        end

        def verify_maintenance_tasks_geometry
          [320, 390, 640, 960, 961].each do |width|
            page.current_window.resize_to(width, 900)
            visit host_routes.admin_maintenance_tasks_path
            assert_equal 200, page.status_code
            assert_selector "[data-maintenance-tasks-root]", count: 1
            assert_admin_navigation_active(translate("navigation.maintenance_tasks"))

            geometry = page.driver.with_playwright_page do |playwright_page|
              playwright_page.evaluate(<<~JAVASCRIPT)
                () => {
                  const shell = document.querySelector('[data-maintenance-tasks-shell="true"]')
                  const sidebar = shell.querySelector(":scope > aside").getBoundingClientRect()
                  const content = shell.querySelector(":scope > div").getBoundingClientRect()
                  return {
                    documentWidth: document.documentElement.scrollWidth,
                    viewportWidth: window.innerWidth,
                    rootWidth: document.querySelector("[data-maintenance-tasks-root]").getBoundingClientRect().width,
                    sidebarTop: sidebar.top,
                    sidebarBottom: sidebar.bottom,
                    sidebarRight: sidebar.right,
                    contentTop: content.top,
                    contentLeft: content.left
                  }
                }
              JAVASCRIPT
            end
            assert_operator geometry.fetch("documentWidth"), :<=, geometry.fetch("viewportWidth"),
              "Maintenance Tasks horizontal overflow at #{width}px"
            assert_operator geometry.fetch("rootWidth"), :>, 0,
              "Maintenance Tasks content should be visible at #{width}px"
            if width < 961
              assert_operator geometry.fetch("contentTop"), :>=, geometry.fetch("sidebarBottom"),
                "Maintenance Tasks admin shell should use one column at #{width}px"
            else
              assert_in_delta geometry.fetch("sidebarTop"), geometry.fetch("contentTop"), 0.5
              assert_operator geometry.fetch("contentLeft"), :>=, geometry.fetch("sidebarRight"),
                "Maintenance Tasks admin shell should use two columns at #{width}px"
            end
          end
        ensure
          desktop = VIEWPORTS.fetch("desktop")
          page.current_window.resize_to(desktop.fetch("width"), desktop.fetch("height"))
        end

        def with_deterministic_secure_random
          singleton_class = SecureRandom.singleton_class
          original_method = SecureRandom.method(:urlsafe_base64)
          singleton_class.define_method(:urlsafe_base64) do |length, _padding = false|
            length == 24 ? "A" * 32 : "B" * 43
          end
          yield
        ensure
          singleton_class.define_method(:urlsafe_base64, original_method)
        end

        def capture_current_page(identifier, title, viewport)
          filename = "#{identifier}--#{viewport}.png"
          path = @output_directory.join(filename)
          page.driver.with_playwright_page do |playwright_page|
            playwright_page.emulate_media(reducedMotion: "reduce")
            playwright_page.evaluate(<<~JAVASCRIPT)
              () => {
                const style = document.createElement("style")
                const nonce = document.querySelector('meta[name="csp-nonce"]')?.content
                if (nonce) style.nonce = nonce
                style.textContent = `
                  *, *::before, *::after {
                    animation: none !important;
                    caret-color: transparent !important;
                    scroll-behavior: auto !important;
                    transition: none !important;
                  }
                `
                document.head.append(style)
              }
            JAVASCRIPT
            playwright_page.evaluate("() => document.fonts.ready")
            playwright_page.screenshot(path: path.to_s, fullPage: true, animations: "disabled")
          end
          @captures << { "id" => identifier, "title" => title, "viewport" => viewport, "path" => filename }
        end
    end
  RUBY
  runner = runner.sub("__AUTHENTICATION__", authentication.inspect)
  runner = runner.sub("__IMAGE_DELIVERY__", image_delivery.inspect)
  runner = runner.sub("__WEB_PUSH__", web_push.inspect)
  runner = runner.sub("__JOB_OPERATIONS__", job_operations.inspect)
  runner = runner.sub("__MAINTENANCE_TASKS__", maintenance_tasks.inspect)
  create_file "test/support/evidence_capture.rb", runner, force: true
  create_file "lib/tasks/evidence.rake", <<~'RAKE', force: true
    # frozen_string_literal: true

    require "fileutils"
    require "rbconfig"

    namespace :evidence do
      desc "CapybaraとPlaywrightでUIエビデンスを撮影する"
      task capture: :environment do
        raise "evidence:captureはRAILS_ENV=testでのみ実行できます" unless Rails.env.test?

        output_directory = Pathname(ENV.fetch("EVIDENCE_OUTPUT_DIR")).expand_path
        raise "EVIDENCE_OUTPUT_DIRにroot directoryは指定できません" if output_directory.root?
        FileUtils.mkdir_p(output_directory)
        raise "EVIDENCE_OUTPUT_DIRは空である必要があります" unless output_directory.children.empty?

        rails = Rails.root.join("bin/rails").to_s
        rebuild_test_database = lambda do
          system({ "RAILS_ENV" => "test" }, rails, "db:test:purge", "db:test:prepare")
        end
        capture_error = nil
        web_push_environment = if defined?(PushSubscription)
          require "web-push"
          vapid_key = WebPush.generate_key
          {
            "VAPID_PUBLIC_KEY" => vapid_key.public_key,
            "VAPID_PRIVATE_KEY" => vapid_key.private_key,
            "VAPID_SUBJECT" => "https://localhost"
          }
        else
          {}
        end

        begin
          raise "test databaseの再構築に失敗しました" unless rebuild_test_database.call

          system(
            { "RAILS_ENV" => "test", "EVIDENCE_OUTPUT_DIR" => output_directory.to_s }.merge(web_push_environment),
            RbConfig.ruby,
            "-Itest",
            Rails.root.join("test/support/evidence_capture.rb").to_s
          ) || raise("UIエビデンスの撮影に失敗しました")
        rescue StandardError => error
          capture_error = error
        ensure
          cleanup_succeeded = rebuild_test_database.call
        end

        if capture_error
          raise "#{capture_error.message}\ntest databaseの後始末にも失敗しました" unless cleanup_succeeded

          raise capture_error
        end
        raise "test databaseの後始末に失敗しました" unless cleanup_succeeded
      end
    end
  RAKE
end

def configure_annotaterb
  generate "annotate_rb:install"
  create_file "test/annotations_test.rb", <<~RUBY, force: true
    # frozen_string_literal: true

    require "test_helper"
    require "open3"

    class AnnotationsTest < ActiveSupport::TestCase
      test "schema annotations are up to date" do
        stdout, stderr, status = Open3.capture3(
          { "RAILS_ENV" => "test" },
          Rails.root.join("bin/annotaterb").to_s,
          "models",
          "--frozen"
        )
        output = [stdout, stderr].reject(&:empty?).join("\\n")

        assert status.success?, <<~MESSAGE
          Schema annotations are out of date.
          Run bin/annotaterb models and commit the updated annotations.

          \#{output}
        MESSAGE
      end
    end
  RUBY
end

def configure_database
  dokploy = VALUES.fetch("deployment") == "dokploy"
  production_paths = if dokploy
    {
      "primary" => "<%= ENV.fetch(\"DATABASE_PATH\", \"/data/production.sqlite3\") %>",
      "storage" => "<%= ENV.fetch(\"STORAGE_DATABASE_PATH\", \"/data/production_storage.sqlite3\") %>",
      "queue" => "<%= ENV.fetch(\"QUEUE_DATABASE_PATH\", \"/data/production_queue.sqlite3\") %>",
      "cache" => "<%= ENV.fetch(\"CACHE_DATABASE_PATH\", \"/data/production_cache.sqlite3\") %>",
      "cable" => "<%= ENV.fetch(\"CABLE_DATABASE_PATH\", \"/data/production_cable.sqlite3\") %>"
    }
  else
    {
      "primary" => "storage/production.sqlite3",
      "storage" => "storage/production_storage.sqlite3",
      "queue" => "storage/production_queue.sqlite3",
      "cache" => "storage/production_cache.sqlite3",
      "cable" => "storage/production_cable.sqlite3"
    }
  end
  databases = {
    "primary" => { "database" => production_paths.fetch("primary") },
    "storage" => { "database" => production_paths.fetch("storage"), "migrations_paths" => "db/storage_migrate" }
  }
  if VALUES.fetch("active_job") == "solid_queue"
    databases["queue"] = { "database" => production_paths.fetch("queue"), "migrations_paths" => "db/queue_migrate" }
  end
  if VALUES.fetch("solid_cache") == "use"
    databases["cache"] = { "database" => production_paths.fetch("cache"), "migrations_paths" => "db/cache_migrate" }
  end
  if VALUES.fetch("action_cable") == "solid_cable"
    databases["cable"] = { "database" => production_paths.fetch("cable"), "migrations_paths" => "db/cable_migrate" }
  end
  production = databases.transform_values do |database|
    { "adapter" => "sqlite3", "pool" => "<%= ENV.fetch(\"DATABASE_POOL_SIZE\", ENV.fetch(\"RAILS_MAX_THREADS\", 5)) %>", "timeout" => 20_000, "transaction_mode" => "immediate" }.merge(database)
  end
  test_databases = {
    "primary" => { "database" => "storage/test.sqlite3" },
    "storage" => { "database" => "storage/test_storage.sqlite3", "migrations_paths" => "db/storage_migrate" }
  }
  if VALUES.fetch("job_operations") == "enable"
    test_databases["queue"] = { "database" => "storage/test_queue.sqlite3", "migrations_paths" => "db/queue_migrate" }
  end
  config = {
    "default" => { "adapter" => "sqlite3", "pool" => "<%= ENV.fetch(\"RAILS_MAX_THREADS\", 5) %>", "timeout" => 5000 },
    "development" => {
      "primary" => { "database" => "storage/development.sqlite3" },
      "storage" => { "database" => "storage/development_storage.sqlite3", "migrations_paths" => "db/storage_migrate" }
    },
    "test" => test_databases,
    "production" => production
  }
  database_yaml = YAML.dump(config, line_width: -1)
    .sub("default:\n", "default: &default\n")
    .gsub(/^  ([a-z]+):\n(?=    (?:adapter|database):)/, "  \\1:\n    <<: *default\n")
  create_file "config/database.yml", database_yaml, force: true
end

def configure_dokploy
  processes = ["web: bundle exec puma -p 3000 -C ./config/puma.rb"]
  processes << "worker: bin/jobs --mode async" if VALUES.fetch("active_job") == "solid_queue"
  create_file "Procfile.prod", processes.join("\n") + "\n"

  replicas = [
    "  - path: ${DATABASE_PATH}\n    replicas:\n      - url: ${LITESTREAM_REPLICA_URL}",
    "  - path: ${STORAGE_DATABASE_PATH}\n    replicas:\n      - url: ${LITESTREAM_STORAGE_REPLICA_URL}"
  ]
  replicas << "  - path: ${QUEUE_DATABASE_PATH}\n    replicas:\n      - url: ${LITESTREAM_QUEUE_REPLICA_URL}" if VALUES.fetch("active_job") == "solid_queue"
  replicas << "  - path: ${CABLE_DATABASE_PATH}\n    replicas:\n      - url: ${LITESTREAM_CABLE_REPLICA_URL}" if VALUES.fetch("action_cable") == "solid_cable"
  create_file "litestream.yml", "dbs:\n#{replicas.join("\n")}\n"
  create_file ".dockerignore", ".git\nlog/*\ntmp/*\nstorage/*\nnode_modules\nconfig/master.key\nmise.local.toml\n"
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
    RUN apt-get update -qq && apt-get install --no-install-recommends -y build-essential git nodejs npm pkg-config autoconf automake libtool libssl-dev libsqlite3-dev libyaml-dev && rm -rf /var/lib/apt/lists/*
    COPY Gemfile Gemfile.lock ./
    RUN bundle install
    COPY package.json package-lock.json ./
    RUN npm ci
    COPY . .
    RUN APPLICATION_ORIGIN=https://build.example.com SECRET_KEY_BASE_DUMMY=1 bundle exec rails assets:precompile && rm -rf node_modules

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
  install_action_text
  install_active_storage_db
  configure_lexxy
  install_daisyui
  configure_generator_view_templates
  configure_rubocop
  configure_common_files
  configure_evidence_capture
  configure_annotaterb
  configure_application_identity
  configure_image_delivery
  VALUES.fetch("account_authentication") == "devise" ? install_devise : install_wallet_siwe
  configure_roles
  configure_content_management
  configure_profile if VALUES.fetch("profile_features").any?
  configure_api if VALUES.fetch("api") == "enable"
  configure_pwa if VALUES.fetch("pwa") == "use"
  configure_web_push if VALUES.fetch("web_push") == "use"
  configure_default_views
  install_solid_components
  install_job_operations if VALUES.fetch("job_operations") == "enable"
  install_maintenance_tasks if VALUES.fetch("maintenance_tasks") == "enable"
  configure_database
  configure_active_storage_db
  configure_dokploy if VALUES.fetch("deployment") == "dokploy"
  run_checked "bin/rails db:prepare"
  run_checked "bundle binstubs annotaterb"
  run_checked "bin/annotaterb models"
  run_checked "bin/rails tailwindcss:build"
  run_checked "bundle binstubs rubocop"
  run_checked "bin/rubocop -a"
end
