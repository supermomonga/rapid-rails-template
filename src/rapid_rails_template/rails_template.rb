# frozen_string_literal: true

require "json"
require "yaml"
require "digest"

CONFIG_PATH = ENV.fetch("RAPID_RAILS_TEMPLATE_CONFIG")
PLAN = JSON.parse(File.read(CONFIG_PATH), freeze: true)
VALUES = PLAN.fetch("configuration").fetch("values")
EXPECTED_KEYS = %w[pwa web_push active_job job_operations maintenance_tasks solid_cache additional_login_methods profile_features api action_cable mail deployment default_locale].freeze
raise "configuration schema mismatch" unless VALUES.keys.sort == EXPECTED_KEYS.sort

RUBOCOP_URL = "https://gist.githubusercontent.com/supermomonga/3ffe073e1c11cd9025d35d507038b9e2/raw/38a485963395626171243dce796e6dc541d61450/.rubocop.yml"

gem "pagy"
gem "active_link_to"
gem "action_policy"
gem "sentry-ruby"
gem "sentry-rails"
gem "lexxy", "~> 0.9.21"
gem "active_storage_db"
gem "prism"
gem "rails-i18n"
gem "sorbet-runtime"

gem_group :development do
  gem "annotaterb"
  gem "sorbet", require: false
  gem "ruby-lsp", require: false
  gem "ruby-lsp-rails", require: false
  gem "rubocop-rails", require: false
  gem "rubocop-thread_safety", require: false
  gem "momocop", require: false
end

gem_group :development, :test do
  gem "tapioca", require: false
end

gem_group :test do
  gem "capybara"
  gem "capybara-playwright-driver"
  gem "factory_bot"
  gem "factory_bot_rails"
end

gem "devise", "~> 5.0.4"
gem "devise-i18n"
gem "webauthn", "~> 3.4"
gem "siwe-rb", "~> 0.2.0", require: "siwe" if VALUES.fetch("additional_login_methods").include?("siwe")
gem "haikunator" if (VALUES.fetch("profile_features") & %w[screen_name display_name]).any?
gem "boring_avatars", "~> 0.1.0", require: "boring_avatars/bindings/rails" if VALUES.fetch("profile_features").include?("avatar")
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

def configure_devise_routes
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

  replacement = "devise_for :users, skip: :all"
  File.binwrite(
    path,
    source.byteslice(0, call.location.start_offset) + replacement + source.byteslice(call.location.end_offset..)
  )

  siwe_routes = if VALUES.fetch("additional_login_methods").include?("siwe")
    <<~RUBY
      post "users/sign_in/siwe/challenge", to: "users/siwe_sessions#challenge", as: :user_siwe_challenge
      post "users/sign_in/siwe", to: "users/siwe_sessions#create", as: :user_siwe
      post "users/sign_up/siwe/challenge", to: "users/siwe_registrations#challenge", as: :user_siwe_registration_challenge
      post "users/sign_up/siwe", to: "users/siwe_registrations#create", as: :user_siwe_registration
    RUBY
  else
    ""
  end

  route <<~RUBY
    devise_scope :user do
      get "users/sign_in", to: "users/passkey_sessions#new", as: :new_user_session
      post "users/sign_in/passkey/options", to: "users/passkey_sessions#options", as: :user_passkey_session_options
      post "users/sign_in/passkey", to: "users/passkey_sessions#create", as: :user_passkey_session
      delete "users/sign_out", to: "users/passkey_sessions#destroy", as: :destroy_user_session
      get "users/sign_up", to: "users/passkey_registrations#new", as: :new_user_registration
      post "users/sign_up/passkey/options", to: "users/passkey_registrations#options", as: :user_passkey_registration_options
      post "users/sign_up/passkey", to: "users/passkey_registrations#create", as: :user_passkey_registration
    #{siwe_routes.lines.map { |line| "  #{line}" }.join}end
  RUBY
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
      extend T::Sig

      Error = Class.new(StandardError)
      AVAILABLE_LOCALES = %i[ja en].freeze

      sig { returns(String) }
      attr_reader :app_name

      sig { returns(String) }
      attr_reader :canonical_origin

      sig { returns(Symbol) }
      attr_reader :default_locale

      sig do
        params(
          configuration: T::Hash[Symbol, T.nilable(String)],
          environment: T::Hash[String, String]
        ).returns(ApplicationIdentity)
      end
      def self.build(configuration, environment: ENV.to_h)
        canonical_origin = configuration[:canonical_origin]
        canonical_origin_env = configuration[:canonical_origin_env]
        if canonical_origin_env.present?
          canonical_origin = environment.fetch(canonical_origin_env) do
            raise Error, "\#{canonical_origin_env} is required"
          end
        end
        new(
          app_name: T.must(configuration[:app_name]),
          canonical_origin: T.must(canonical_origin),
          default_locale: T.must(configuration[:default_locale])
        )
      end

      sig { params(app_name: T.any(String, Symbol), canonical_origin: String, default_locale: T.any(String, Symbol)).void }
      def initialize(app_name:, canonical_origin:, default_locale:)
        @app_name = T.let(app_name.to_s.strip, String)
        raise Error, "app_name is required" if @app_name.empty?

        @default_locale = T.let(default_locale.to_s.to_sym, Symbol)
        raise Error, "default_locale must be ja or en" unless AVAILABLE_LOCALES.include?(@default_locale)

        @canonical_origin = T.let(validate_origin(canonical_origin), String)
        freeze
      end

      sig { returns(T::Hash[Symbol, T.any(String, Integer)]) }
      def default_url_options
        uri = URI.parse(canonical_origin)
        options = { protocol: T.must(uri.scheme), host: T.must(uri.host) }
        options[:port] = uri.port unless uri.port == URI::HTTP.default_port || uri.port == URI::HTTPS.default_port
        options
      end

      sig { params(path: String).returns(String) }
      def canonical_url(path)
        raise ArgumentError, "path must be a same-origin absolute path" unless path.start_with?("/") && !path.start_with?("//")

        canonical_origin + path
      end

      sig { params(locale: T.any(String, Symbol)).returns(String) }
      def siwe_statement(locale: default_locale)
        locale = locale.to_s.to_sym
        raise ArgumentError, "locale must be ja or en" unless AVAILABLE_LOCALES.include?(locale)

        encoded_app_name = URI.encode_uri_component(app_name).gsub("%20", " ")
        I18n.t("siwe.statement", locale:, app_name: encoded_app_name)
      end

      private
        sig { params(value: String).returns(String) }
        def validate_origin(value)
          raise Error, "canonical_origin is required" if value.blank?

          uri = URI.parse(value.to_s)
          valid = uri.is_a?(URI::HTTP) && uri.host.present? && uri.userinfo.nil? &&
            uri.path.to_s.empty? && uri.query.nil? && uri.fragment.nil?
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
    config.x.application_identity = ApplicationIdentity.build(config_for(:application_identity).to_h)
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
        T.bind(self, T.any(T.class_of(ActionController::Base), T.class_of(ActionController::API)))
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
        "badge" => "Railsアプリケーションテンプレート", "heading" => "迷わず始められる、モダンなRails開発環境。",
        "description" => "Rails 8.1の標準を活かしながら、認証、UI、テスト、デプロイまでを再現可能な構成で整えます。",
        "start_devise" => "無料で始める", "features_link" => "構成を見る", "starter" => "スターターキット", "features_title" => "最初から揃う開発基盤",
        "features" => { "rails" => { "title" => "Railsネイティブ", "description" => "Generator APIを中心に、安全な初期構成を生成します。" }, "ui" => { "title" => "読みやすいUI", "description" => "daisyUIとsemantic colorで、読みやすい画面を用意します。" }, "production" => { "title" => "本番運用対応", "description" => "SQLiteとLitestreamを前提に、運用経路まで設計します。" } }
      },
      "accounts" => {
        "show" => { "title" => "マイページ", "description" => "アプリケーションの状態を確認できます。", "description_with_profile" => "プロフィールとアプリケーションの状態を確認できます。", "next_step" => "次のステップ", "action" => "サイドメニューから利用設定を管理できます。", "action_with_profile" => "サイドメニューからプロフィールや利用設定を管理できます。", "back_home" => "ホームへ戻る" },
        "delete" => { "title" => "アカウント削除", "description" => "この操作は取り消せません。現在使えるログイン方法で再認証してください。", "with_passkey" => "Passkeyでアカウントを削除", "with_wallet" => "ウォレットでアカウントを削除" },
        "destroy" => { "notice" => "アカウントを削除しました", "last_admin" => "最後の管理者はアカウントを削除できません" }
      },
      "credential_risk" => { "warning" => "現在のログイン方法は未バックアップのPasskey 1件だけです。端末の紛失・故障に備えて別のログイン方法を追加してください。", "add_login_method" => "ログイン方法を追加" },
      "siwe" => { "statement" => "Login to %{app_name}" },
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
        "badge" => "Rails application template", "heading" => "A modern Rails environment without the guesswork.",
        "description" => "Build on Rails 8.1 defaults with reproducible authentication, UI, testing, and deployment foundations.",
        "start_devise" => "Get started", "features_link" => "View features", "starter" => "Starter kit", "features_title" => "A complete development foundation",
        "features" => { "rails" => { "title" => "Rails native", "description" => "Generate a safe baseline centered on the Generator API." }, "ui" => { "title" => "Readable UI", "description" => "Start with readable screens built with daisyUI and semantic colors." }, "production" => { "title" => "Production ready", "description" => "Include an operational path designed for SQLite and Litestream." } }
      },
      "accounts" => {
        "show" => { "title" => "Dashboard", "description" => "Review the state of your application.", "description_with_profile" => "Review your profile and application state.", "next_step" => "Next step", "action" => "Manage your preferences from the side menu.", "action_with_profile" => "Manage your profile and preferences from the side menu.", "back_home" => "Back to home" },
        "delete" => { "title" => "Delete account", "description" => "This action cannot be undone. Reauthenticate with a sign-in method that currently works.", "with_passkey" => "Delete account with passkey", "with_wallet" => "Delete account with wallet" },
        "destroy" => { "notice" => "Your account was deleted.", "last_admin" => "The last administrator cannot delete their account." }
      },
      "credential_risk" => { "warning" => "Your only sign-in method is a passkey that is not backed up. Add another sign-in method in case this device is lost or damaged.", "add_login_method" => "Add sign-in method" },
      "siwe" => { "statement" => "Sign in to %{app_name}" },
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
        configuration[:app_name] = "Sample App"
        configuration[:default_locale] = "ja"
        configuration[:canonical_origin_env] = "APPLICATION_ORIGIN"

        error = assert_raises(ApplicationIdentity::Error) { ApplicationIdentity.build(configuration.to_h, environment: {}) }
        assert_equal "APPLICATION_ORIGIN is required", error.message

        identity = ApplicationIdentity.build(configuration.to_h, environment: { "APPLICATION_ORIGIN" => "https://example.com" })
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
          assert_select "title", text: identity.app_name, count: 1
          assert_select 'meta[property="og:site_name"][content=?]', identity.app_name, count: 1
          assert_select 'meta[property="og:title"][content=?]', identity.app_name, count: 1
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
  environment <<~RUBY
    config.active_storage.variant_processor = :vips
    config.active_storage.track_variants = true
    config.active_storage.resolve_model_to_route = :rails_storage_proxy
  RUBY

  create_file "docs/image_delivery.md", <<~MARKDOWN, force: true
    # Image delivery

    Active Storageのattachmentとblob metadataはprimary SQLite database、元画像と処理済みvariant本体はActive Storage DBの専用storage SQLite databaseをsource of truthとします。variant processorはlibvipsで、生成済みvariantはvariant recordを使って再処理せず再利用します。
    Docker外で開発・testするhostにもlibvips runtimeが必要です（macOSでは例: `brew install vips`）。

    attachment、blob、representationのURLはActive Storage公式の`rails_storage_proxy` routeへ解決します。初回requestはThrusterからPuma、Rails、Active Storage DBへ転送され、Railsが`public`かつ`immutable`なresponseを返します。同じURLがThrusterのHTTP cacheに残っている間は、ThrusterがPuma、Rails、SQLiteを通さずresponseを返します。variantが生成済みであることと、ThrusterのHTTP cacheがwarmであることは別の状態です。

    Thrusterのcacheはprocess内memoryに保持され、既定の全体容量は64 MiB、1 responseあたりの上限は1 MiBです。process再起動、eviction、上限を超えるresponse、Range requestではcacheを利用できません。容量は必要な場合だけThrusterの環境変数で調整し、このtemplateはCDNや永続cacheを追加しません。

    Active Storageのproxy controllerが発行するsigned URLは恒久的で、URLを知る利用者には公開されます。認証必須の添付にはglobal proxy routeを使用せず、認証済みcontrollerを別途設計してください。

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

  create_file "test/integration/image_delivery_test.rb", <<~'RUBY', force: true
    require "test_helper"

    class ImageDeliveryTest < ActionDispatch::IntegrationTest
      test "serves stored variants through the permanent public proxy route" do
        blob = ImageTestFixture.png_blob
        variant = blob.variant(resize_to_limit: [1, 1])
        path = Rails.application.routes.url_helpers.rails_storage_proxy_path(variant)

        assert_includes path, "/rails/active_storage/representations/proxy/"
        assert_difference -> { blob.variant_records.count }, 1 do
          get path
        end

        assert_response :success
        assert_equal "image/png", response.media_type
        assert_includes response.headers.fetch("cache-control"), "public"
        assert_includes response.headers.fetch("cache-control"), "immutable"
        first_body = response.body

        assert_no_difference -> { blob.variant_records.count } do
          get path
        end
        assert_response :success
        assert_equal first_body, response.body
      ensure
        blob&.purge
      end
    end
  RUBY
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
    <%% content_for :page_title, "<%= human_name.pluralize %>" %>

    <div class="mx-auto w-full max-w-6xl space-y-6 px-5 py-10 md:py-14">
      <header class="flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
        <h1 class="text-2xl font-bold leading-[1.5]"><%%= content_for(:page_title) %></h1>
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
    <%% content_for :page_title, "<%= human_name %>" %>

    <div class="mx-auto w-full max-w-[820px] space-y-6 px-5 py-10 md:py-14">
      <h1 class="text-2xl font-bold leading-[1.5]"><%%= content_for(:page_title) %></h1>

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
    <%% content_for :page_title, "New <%= human_name.downcase %>" %>

    <div class="mx-auto w-full max-w-[820px] space-y-6 px-5 py-10 md:py-14">
      <header class="flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
        <h1 class="text-2xl font-bold leading-[1.5]"><%%= content_for(:page_title) %></h1>
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
    <%% content_for :page_title, "Editing <%= human_name.downcase %>" %>

    <div class="mx-auto w-full max-w-[820px] space-y-6 px-5 py-10 md:py-14">
      <header class="flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
        <h1 class="text-2xl font-bold leading-[1.5]"><%%= content_for(:page_title) %></h1>
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
    <%% content_for :page_title, "<%= class_name %>#<%= @action %>" %>

    <div class="mx-auto w-full max-w-[820px] px-5 py-10 md:py-14">
      <section class="card card-border border-base-300 bg-base-100 shadow-none">
        <div class="card-body">
          <h1 class="card-title text-2xl leading-[1.5]"><%%= content_for(:page_title) %></h1>
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
  generate "migration", "CreatePasskeyCredentials"
  generate "migration", "CreateWebauthnChallenges"

  user_migrations = Dir.glob("db/migrate/*_devise_create_users.rb")
  passkey_migrations = Dir.glob("db/migrate/*_create_passkey_credentials.rb")
  challenge_migrations = Dir.glob("db/migrate/*_create_webauthn_challenges.rb")
  raise "DeviseCreateUsers migrationが一意ではありません" unless user_migrations.one?
  raise "CreatePasskeyCredentials migrationが一意ではありません" unless passkey_migrations.one?
  raise "CreateWebauthnChallenges migrationが一意ではありません" unless challenge_migrations.one?

  create_file user_migrations.first, <<~'RUBY', force: true
    class DeviseCreateUsers < ActiveRecord::Migration[8.1]
      def change
        create_table :users do |t|
          t.string :webauthn_id, null: false
          t.datetime :remember_created_at
          t.timestamps null: false
        end

        add_index :users, :webauthn_id, unique: true
      end
    end
  RUBY

  create_file passkey_migrations.first, <<~'RUBY', force: true
    class CreatePasskeyCredentials < ActiveRecord::Migration[8.1]
      def change
        create_table :passkey_credentials do |t|
          t.references :user, null: false, foreign_key: { on_delete: :cascade }
          t.string :name, null: false
          t.string :webauthn_id, null: false
          t.text :public_key, null: false
          t.bigint :sign_count, null: false, default: 0
          t.json :transports, null: false, default: []
          t.boolean :backup_eligible, null: false
          t.boolean :backup_state, null: false
          t.datetime :last_used_at
          t.timestamps null: false
        end

        add_index :passkey_credentials, :webauthn_id, unique: true
        add_check_constraint :passkey_credentials, "NOT backup_state OR backup_eligible",
          name: "passkey_credentials_valid_backup_flags"
      end
    end
  RUBY

  create_file challenge_migrations.first, <<~'RUBY', force: true
    class CreateWebauthnChallenges < ActiveRecord::Migration[8.1]
      def change
        create_table :webauthn_challenges do |t|
          t.references :user, null: true, foreign_key: { on_delete: :cascade }
          t.string :purpose, null: false
          t.string :token_digest, null: false
          t.string :session_digest, null: false
          t.string :challenge, null: false
          t.string :webauthn_user_id
          t.string :action
          t.string :target_type
          t.bigint :target_id
          t.datetime :expires_at, null: false
          t.datetime :consumed_at
          t.timestamps null: false
        end

        add_index :webauthn_challenges, :token_digest, unique: true
        add_index :webauthn_challenges, :expires_at
        add_index :webauthn_challenges, :consumed_at
        add_check_constraint :webauthn_challenges, "purpose IN ('signup', 'login', 'link', 'destroy')",
          name: "webauthn_challenges_purpose"
        add_check_constraint :webauthn_challenges,
          "(purpose IN ('signup', 'login') AND user_id IS NULL) OR (purpose IN ('link', 'destroy') AND user_id IS NOT NULL)",
          name: "webauthn_challenges_user_matches_purpose"
        add_check_constraint :webauthn_challenges,
          "purpose = 'destroy' OR (action IS NULL AND target_type IS NULL AND target_id IS NULL)",
          name: "webauthn_challenges_target_matches_purpose"
      end
    end
  RUBY

  create_file "lib/devise/models/passkey_authenticatable.rb", <<~'RUBY', force: true
    module Devise
      module Models
        module PasskeyAuthenticatable
          extend ActiveSupport::Concern

          included do
            T.bind(self, T.class_of(User))
            has_many :passkey_credentials, dependent: :destroy
            has_many :webauthn_challenges, dependent: :destroy
          end
        end
      end
    end
  RUBY
  create_file "lib/devise/passkey_authenticatable.rb", <<~'RUBY', force: true
    require "devise"
    require_relative "models/passkey_authenticatable"

    module Devise
      module PasskeyAuthenticatable; end
    end

    Devise.add_module(:passkey_authenticatable, model: "devise/models/passkey_authenticatable")
  RUBY
  create_file "config/initializers/devise_passkey_authenticatable.rb", <<~'RUBY', force: true
    require Rails.root.join("lib/devise/passkey_authenticatable")

    Rails.application.config.filter_parameters += %i[challenge_token credential signature]
  RUBY
  create_file "config/initializers/webauthn.rb", <<~'RUBY', force: true
    require "uri"

    identity = Rails.configuration.x.application_identity
    origin = URI.parse(identity.canonical_origin)

    WebAuthn.configure do |config|
      config.allowed_origins = [identity.canonical_origin]
      config.rp_id = origin.host
      config.rp_name = identity.app_name
    end
  RUBY

  devise_modules = %w[passkey_authenticatable rememberable]
  devise_modules << "siweable" if VALUES.fetch("additional_login_methods").include?("siwe")
  devise_declaration = devise_modules.map { |name| ":#{name}" }.join(", ")
  create_file "app/models/user.rb", <<~RUBY, force: true
    class User < ApplicationRecord
      devise #{devise_declaration}

      validates :webauthn_id, presence: true, uniqueness: { case_sensitive: true }

      before_validation :assign_webauthn_id, on: :create
      validate :webauthn_id_cannot_change, on: :update

      sig { returns(Integer) }
      def authentication_credentials_count
        passkey_credentials.count#{VALUES.fetch("additional_login_methods").include?("siwe") ? " + siwe_identities.count" : ""}
      end

      sig { returns(T::Boolean) }
      def credential_loss_risk?
        return false unless authentication_credentials_count == 1

        only_passkey = passkey_credentials.first
        only_passkey.present? && !only_passkey.backup_state?
      end

      private
        sig { void }
        def assign_webauthn_id
          return if webauthn_id.present?

          loop do
            candidate = WebAuthn.generate_user_id
            next if self.class.exists?(webauthn_id: candidate)

            self.webauthn_id = candidate
            break
          end
        end

        sig { void }
        def webauthn_id_cannot_change
          errors.add(:webauthn_id, :readonly) if will_save_change_to_webauthn_id?
        end
    end
  RUBY

  configure_devise_routes
  configure_passkey_routes
  install_passkey_runtime
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
  create_file "test/fixtures/users.yml", <<~'YAML', force: true
    one:
      webauthn_id: "dGVzdC11c2VyLW9uZQ"

    two:
      webauthn_id: "dGVzdC11c2VyLXR3bw"
  YAML
  create_file "test/fixtures/passkey_credentials.yml", <<~'YAML', force: true
    one:
      user: one
      name: Passkey #1
      webauthn_id: dGVzdC1jcmVkZW50aWFsLW9uZQ
      public_key: dGVzdC1wdWJsaWMta2V5
      sign_count: 0
      transports: '["internal"]'
      backup_eligible: true
      backup_state: false

    two:
      user: two
      name: Passkey #1
      webauthn_id: dGVzdC1jcmVkZW50aWFsLXR3bw
      public_key: dGVzdC1wdWJsaWMta2V5
      sign_count: 0
      transports: '["internal"]'
      backup_eligible: true
      backup_state: true
  YAML
  create_file "test/models/user_test.rb", <<~'RUBY', force: true
    require "test_helper"

    class UserTest < ActiveSupport::TestCase
      test "generates an immutable WebAuthn user handle" do
        user = User.new
        user.save!

        original = user.webauthn_id
        assert_predicate original, :present?
        assert_not user.update(webauthn_id: WebAuthn.generate_user_id)
        assert user.errors.added?(:webauthn_id, :readonly)
        assert_equal original, user.reload.webauthn_id
      end

      test "preserves the WebAuthn user handle bound to a registration ceremony" do
        handle = WebAuthn.generate_user_id
        user = User.create!(webauthn_id: handle)

        assert_equal handle, user.webauthn_id
      end

      test "reports risk only for a sole passkey with backup state false" do
        user = User.create!
        passkey = user.passkey_credentials.create!(
          name: "Device bound", webauthn_id: "risk-device-bound", public_key: "key",
          backup_eligible: false, backup_state: false
        )
        assert_predicate user, :credential_loss_risk?

        passkey.destroy!
        passkey = user.passkey_credentials.create!(
          name: "Sync eligible", webauthn_id: "risk-sync-eligible", public_key: "key",
          backup_eligible: true, backup_state: false
        )
        assert_predicate user.reload, :credential_loss_risk?

        passkey.update!(backup_state: true)
        assert_not user.reload.credential_loss_risk?

        user.passkey_credentials.create!(
          name: "Second", webauthn_id: "risk-second", public_key: "key",
          backup_eligible: false, backup_state: false
        )
        assert_not user.reload.credential_loss_risk?

        if user.respond_to?(:siwe_identities)
          user.passkey_credentials.where.not(id: passkey.id).delete_all
          passkey.update!(backup_state: false)
          T.unsafe(user).siwe_identities.create!(
            name: "Wallet", address: "0xabcdef0123456789abcdef0123456789abcdef01"
          )
          assert_not user.reload.credential_loss_risk?
        end
      end
    end
  RUBY
  create_file "test/models/passkey_credential_test.rb", <<~'RUBY', force: true
    require "test_helper"

    class PasskeyCredentialTest < ActiveSupport::TestCase
      test "rejects backup state without backup eligibility" do
        passkey = PasskeyCredential.new(
          user: users(:one), name: "Invalid", webauthn_id: "invalid-backup-flags",
          public_key: "test-public-key", backup_eligible: false, backup_state: true
        )

        assert_not passkey.valid?
        assert passkey.errors.added?(:backup_state, :invalid)
      end

      test "does not allow backup eligibility to change" do
        passkey = passkey_credentials(:one)

        assert_not passkey.update(backup_eligible: false)
        assert passkey.errors.added?(:backup_eligible, :readonly)
      end
    end
  RUBY
end

def configure_passkey_routes
  route <<~'RUBY'
    namespace :account do
      resources :passkeys, except: :destroy do
        post :options, on: :collection
      end
      post "credential_destructions/passkey/options",
        to: "credential_destructions#passkey_options",
        as: :passkey_credential_destruction_options
      post "credential_destructions/passkey",
        to: "credential_destructions#destroy_with_passkey",
        as: :passkey_credential_destruction
    end
    get "account/delete", to: "accounts#delete", as: :delete_account
  RUBY
end

def install_passkey_runtime
  create_file "app/models/passkey_credential.rb", <<~'RUBY', force: true
    class PasskeyCredential < ApplicationRecord
      extend T::Sig

      VerificationError = Class.new(StandardError)

      belongs_to :user

      normalizes :name, with: ->(name) { name.to_s.strip }

      validates :name, presence: true, length: { maximum: 50 }
      validates :webauthn_id, :public_key, presence: true
      validates :webauthn_id, uniqueness: { case_sensitive: true }
      validates :sign_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
      validate :backup_flags_are_valid
      validate :backup_eligibility_does_not_change, on: :update

      sig do
        params(credential: WebAuthn::PublicKeyCredentialWithAssertion, challenge: String).void
      end
      def verify_and_update!(credential, challenge:)
        credential.verify(
          challenge,
          public_key:,
          sign_count:,
          user_verification: true
        )
        asserted_backup_eligible = credential.backup_eligible?
        asserted_backup_state = credential.backed_up?
        raise VerificationError, "invalid backup flags" if asserted_backup_state && !asserted_backup_eligible
        raise VerificationError, "backup eligibility changed" unless asserted_backup_eligible == backup_eligible?

        update!(
          sign_count: credential.sign_count,
          backup_state: asserted_backup_state,
          last_used_at: Time.current
        )
      end

      private
        def backup_flags_are_valid
          errors.add(:backup_state, :invalid) if backup_state? && !backup_eligible?
        end

        def backup_eligibility_does_not_change
          errors.add(:backup_eligible, :readonly) if will_save_change_to_backup_eligible?
        end
    end
  RUBY

  create_file "app/models/webauthn_challenge.rb", <<~'RUBY', force: true
    require "digest"
    require "securerandom"

    class WebauthnChallenge < ApplicationRecord
      extend T::Sig

      VerificationError = Class.new(StandardError)
      TTL = 5.minutes
      PURPOSES = %w[signup login link destroy].freeze
      ACTIONS = %w[delete_passkey delete_siwe delete_account].freeze

      belongs_to :user, optional: true

      validates :purpose, inclusion: { in: PURPOSES }
      validates :token_digest, :session_digest, :challenge, :expires_at, presence: true
      validates :token_digest, uniqueness: true
      validates :action, inclusion: { in: ACTIONS }, allow_nil: true
      validate :context_matches_purpose

      sig do
        params(
          purpose: String,
          challenge: String,
          session_binding: String,
          user: T.nilable(User),
          webauthn_user_id: T.nilable(String),
          action: T.nilable(String),
          target: T.nilable(ActiveRecord::Base)
        ).returns([WebauthnChallenge, String])
      end
      def self.issue!(purpose:, challenge:, session_binding:, user: nil, webauthn_user_id: nil, action: nil, target: nil)
        now = Time.current
        where("expires_at <= ? OR consumed_at IS NOT NULL", now).delete_all
        raw_token = SecureRandom.urlsafe_base64(32)
        record = create!(
          user:,
          purpose:,
          token_digest: digest(raw_token),
          session_digest: digest(session_binding),
          challenge:,
          webauthn_user_id:,
          action:,
          target_type: target&.class&.name,
          target_id: target&.id,
          expires_at: now + TTL
        )
        [record, raw_token]
      end

      def self.for_token!(raw_token)
        find_by!(token_digest: digest(raw_token.to_s))
      end

      def self.digest(value)
        Digest::SHA256.hexdigest(value.to_s)
      end

      def verify_context!(purpose:, session_binding:, user: nil, action: nil, target: nil)
        raise VerificationError, "purpose mismatch" unless self.purpose == purpose
        raise VerificationError, "user mismatch" unless user_id == user&.id
        raise VerificationError, "action mismatch" unless self.action == action
        raise VerificationError, "target mismatch" unless target_type == target&.class&.name && target_id == target&.id
        raise VerificationError, "challenge expired" unless consumed_at.nil? && expires_at.future?
        actual_session_digest = self.class.digest(session_binding)
        unless ActiveSupport::SecurityUtils.secure_compare(session_digest, actual_session_digest)
          raise VerificationError, "session mismatch"
        end
      end

      def consume!
        # This conditional update makes challenge consumption atomic.
        # rubocop:disable Rails/SkipsModelValidations
        consumed = self.class.where(id:, consumed_at: nil).where("expires_at > ?", Time.current)
          .update_all(consumed_at: Time.current)
        # rubocop:enable Rails/SkipsModelValidations
        raise VerificationError, "challenge already consumed" unless consumed == 1

        reload
      end

      private
        def context_matches_purpose
          valid_user = %w[signup login].include?(purpose) ? user_id.nil? : user_id.present?
          valid_target = if purpose == "destroy"
            action.present? && target_type.present? && target_id.present?
          else
            action.nil? && target_type.nil? && target_id.nil?
          end
          errors.add(:user, :invalid) unless valid_user
          errors.add(:target, :invalid) unless valid_target
        end
    end
  RUBY

  install_credential_destruction
  install_passkey_controllers
  install_passkey_javascript
  install_passkey_views
  install_passkey_tests
end

def install_credential_destruction
  create_file "app/services/credential_destruction.rb", <<~'RUBY', force: true
    class CredentialDestruction
      extend T::Sig

      Error = Class.new(StandardError)
      ACTIONS = %w[delete_passkey delete_siwe delete_account].freeze

      def self.target_for!(user:, action:, target_id:)
        case action
        when "delete_passkey"
          user.passkey_credentials.find(target_id)
        when "delete_siwe"
          raise ActiveRecord::RecordNotFound unless defined?(SiweIdentity)

          user.siwe_identities.find(target_id)
        when "delete_account"
          raise ActiveRecord::RecordNotFound unless user.id == target_id

          user
        else
          raise Error, "unsupported action"
        end
      end

      def self.passkeys_for(user:, action:, target:)
        scope = user.passkey_credentials
        action == "delete_passkey" ? scope.where.not(id: target.id) : scope
      end

      def self.siwe_identities_for(user:, action:, target:)
        return PasskeyCredential.none unless defined?(SiweIdentity)

        scope = user.siwe_identities
        action == "delete_siwe" ? scope.where.not(id: target.id) : scope
      end

      def self.ensure_alternative!(user:, action:, target:)
        return if action == "delete_account"
        return if passkeys_for(user:, action:, target:).exists?
        return if siwe_identities_for(user:, action:, target:).exists?

        raise Error, "last authentication credential"
      end

      def self.execute!(user:, action:, target:, authenticator:)
        User.transaction do
          user.lock!
          raise Error, "last administrator" if action == "delete_account" && user.last_admin?
          locked_target = target_for!(user:, action:, target_id: target.id)
          ensure_alternative!(user:, action:, target: locked_target)
          eligible =
            case authenticator
            when PasskeyCredential
              passkeys_for(user:, action:, target: locked_target).lock.exists?(id: authenticator.id)
            when ->(candidate) { candidate.class.name == "SiweIdentity" }
              siwe_identities_for(user:, action:, target: locked_target).lock.exists?(id: authenticator.id)
            else
              false
            end
          raise Error, "authentication credential is not eligible" unless eligible

          locked_target.destroy!
        end
      end
    end
  RUBY

  create_file "app/controllers/concerns/webauthn_request.rb", <<~'RUBY', force: true
    module WebauthnRequest
      extend ActiveSupport::Concern

      included do
        T.bind(self, T.class_of(ActionController::Base))
        after_action :prevent_webauthn_caching
      end

      private
        def webauthn_session_binding
          T.bind(self, ActionController::Base)
          session[:webauthn_binding] ||= SecureRandom.hex(32)
        end

        def prevent_webauthn_caching
          T.bind(self, ActionController::Base)
          response.set_header("Cache-Control", "no-store")
        end

        def render_webauthn_error(status: :unprocessable_content)
          T.bind(self, ActionController::Base)
          head status
        end
    end
  RUBY
end

def install_passkey_controllers
  create_file "app/controllers/users/passkey_registrations_controller.rb", <<~'RUBY', force: true
    module Users
      class PasskeyRegistrationsController < DeviseController
        include WebauthnRequest

        layout "authentication"
        rate_limit to: 10, within: 1.minute, only: %i[options create],
          by: -> {
            T.bind(self, Users::PasskeyRegistrationsController)
            "#{request.remote_ip}:#{webauthn_session_binding}"
          },
          with: -> {
            T.bind(self, Users::PasskeyRegistrationsController)
            head :too_many_requests
          }

        def new
          redirect_to account_path if user_signed_in?
        end

        def options
          user_handle = WebAuthn.generate_user_id
          public_key = WebAuthn::Credential.options_for_create(
            user: {
              id: user_handle,
              name: user_handle,
              display_name: Rails.configuration.x.application_identity.app_name
            },
            authenticator_selection: { resident_key: "required", user_verification: "required" },
            attestation: "none"
          )
          _record, raw_token = WebauthnChallenge.issue!(
            purpose: "signup",
            challenge: public_key.challenge,
            webauthn_user_id: user_handle,
            session_binding: webauthn_session_binding
          )
          render json: { challenge_token: raw_token, public_key: public_key.as_json }
        rescue ActiveRecord::RecordInvalid
          render_webauthn_error
        end

        def create
          challenge = WebauthnChallenge.for_token!(params.require(:challenge_token))
          challenge.verify_context!(purpose: "signup", session_binding: webauthn_session_binding)
          credential = WebAuthn::Credential.from_create(params.require(:credential).to_unsafe_h)
          credential.verify(challenge.challenge, user_verification: true)
          if credential.backed_up? && !credential.backup_eligible?
            raise WebauthnChallenge::VerificationError, "invalid backup flags"
          end

          user = T.let(nil, T.nilable(User))
          WebauthnChallenge.transaction do
            challenge.consume!
            user = User.create!(webauthn_id: challenge.webauthn_user_id)
            T.must(user).passkey_credentials.create!(passkey_attributes(credential, name: "Passkey #1"))
          end
          request.env["devise.skip_timeout"] = true
          sign_in(:user, T.must(user), event: :authentication)
          flash[:credential_risk] = true if T.must(user).credential_loss_risk?
          render json: { redirect_url: after_sign_in_path_for(T.must(user)) }, status: :created
        rescue ActionController::ParameterMissing, ActiveRecord::RecordNotFound, ActiveRecord::RecordInvalid,
          ActiveRecord::RecordNotUnique, WebAuthn::Error, WebauthnChallenge::VerificationError
          render_webauthn_error
        end

        private
          def passkey_attributes(credential, name:)
            {
              name:,
              webauthn_id: credential.id,
              public_key: credential.public_key,
              sign_count: credential.sign_count,
              transports: credential.response.transports || [],
              backup_eligible: credential.backup_eligible?,
              backup_state: credential.backed_up?
            }
          end
      end
    end
  RUBY

  create_file "app/controllers/users/passkey_sessions_controller.rb", <<~'RUBY', force: true
    module Users
      class PasskeySessionsController < DeviseController
        include WebauthnRequest

        layout "authentication"
        rate_limit to: 10, within: 1.minute, only: %i[options create],
          by: -> {
            T.bind(self, Users::PasskeySessionsController)
            "#{request.remote_ip}:#{webauthn_session_binding}"
          },
          with: -> {
            T.bind(self, Users::PasskeySessionsController)
            head :too_many_requests
          }

        def new
          redirect_to account_path if user_signed_in?
        end

        def options
          public_key = WebAuthn::Credential.options_for_get(user_verification: "required")
          _record, raw_token = WebauthnChallenge.issue!(
            purpose: "login", challenge: public_key.challenge, session_binding: webauthn_session_binding
          )
          render json: { challenge_token: raw_token, public_key: public_key.as_json }
        rescue ActiveRecord::RecordInvalid
          render_webauthn_error
        end

        def create
          challenge = WebauthnChallenge.for_token!(params.require(:challenge_token))
          challenge.verify_context!(purpose: "login", session_binding: webauthn_session_binding)
          assertion = WebAuthn::Credential.from_get(params.require(:credential).to_unsafe_h)
          stored = PasskeyCredential.includes(:user).find_by!(webauthn_id: assertion.id)
          user = T.must(stored.user)
          unless assertion.user_handle == user.webauthn_id
            raise WebauthnChallenge::VerificationError, "user handle mismatch"
          end

          WebauthnChallenge.transaction do
            stored.verify_and_update!(assertion, challenge: challenge.challenge)
            challenge.consume!
          end
          return head :unauthorized unless user.active_for_authentication?

          request.env["devise.skip_timeout"] = true
          sign_in(:user, user, event: :authentication)
          remember_me(user) if ActiveModel::Type::Boolean.new.cast(params[:remember_me])
          flash[:credential_risk] = true if user.credential_loss_risk?
          render json: { redirect_url: after_sign_in_path_for(user) }
        rescue ActionController::ParameterMissing, ActiveRecord::RecordNotFound, ActiveRecord::RecordInvalid,
          WebAuthn::Error, PasskeyCredential::VerificationError, WebauthnChallenge::VerificationError
          render_webauthn_error(status: :unauthorized)
        end

        def destroy
          sign_out(:user)
          redirect_to root_path, status: :see_other
        end
      end
    end
  RUBY

  create_file "app/controllers/account/passkeys_controller.rb", <<~'RUBY', force: true
    module Account
      class PasskeysController < ApplicationController
        include WebauthnRequest

        layout "account_settings"
        before_action :authenticate_user!
        before_action :set_passkey, only: %i[show edit update]

        def index
          @passkeys = account_user.passkey_credentials.order(:created_at)
        end

        def show
          CredentialDestruction.ensure_alternative!(user: account_user, action: "delete_passkey", target: @passkey)
        rescue CredentialDestruction::Error
          redirect_to account_passkeys_path, alert: t("passkeys.errors.last_credential")
        end

        def new; end
        def edit; end

        def options
          public_key = WebAuthn::Credential.options_for_create(
            user: {
              id: account_user.webauthn_id,
              name: account_user.webauthn_id,
              display_name: Rails.configuration.x.application_identity.app_name
            },
            exclude: account_user.passkey_credentials.map(&:webauthn_id),
            authenticator_selection: { resident_key: "required", user_verification: "required" },
            attestation: "none"
          )
          _record, raw_token = WebauthnChallenge.issue!(
            purpose: "link", challenge: public_key.challenge, user: account_user,
            session_binding: webauthn_session_binding
          )
          render json: { challenge_token: raw_token, public_key: public_key.as_json }
        rescue ActiveRecord::RecordInvalid
          render_webauthn_error
        end

        def create
          challenge = WebauthnChallenge.for_token!(params.require(:challenge_token))
          challenge.verify_context!(purpose: "link", user: account_user, session_binding: webauthn_session_binding)
          credential = WebAuthn::Credential.from_create(params.require(:credential).to_unsafe_h)
          credential.verify(challenge.challenge, user_verification: true)
          if credential.backed_up? && !credential.backup_eligible?
            raise WebauthnChallenge::VerificationError, "invalid backup flags"
          end

          passkey = T.let(nil, T.nilable(PasskeyCredential))
          WebauthnChallenge.transaction do
            challenge.consume!
            passkey = account_user.passkey_credentials.create!(
              name: "Passkey ##{account_user.passkey_credentials.count + 1}",
              webauthn_id: credential.id,
              public_key: credential.public_key,
              sign_count: credential.sign_count,
              transports: credential.response.transports || [],
              backup_eligible: credential.backup_eligible?,
              backup_state: credential.backed_up?
            )
          end
          render json: { redirect_url: account_passkeys_path, id: T.must(passkey).id }, status: :created
        rescue ActionController::ParameterMissing, ActiveRecord::RecordNotFound, ActiveRecord::RecordInvalid,
          ActiveRecord::RecordNotUnique, WebAuthn::Error, WebauthnChallenge::VerificationError
          render_webauthn_error
        end

        def update
          if @passkey.update(params.expect(passkey_credential: [:name]))
            redirect_to account_passkeys_path, notice: t("passkeys.updated")
          else
            render :edit, status: :unprocessable_content
          end
        end

        private
          def account_user
            T.must(current_user)
          end

          def set_passkey
            @passkey = account_user.passkey_credentials.find(params.expect(:id))
          end
      end
    end
  RUBY

  create_file "app/controllers/account/credential_destructions_controller.rb", <<~'RUBY', force: true
    module Account
      class CredentialDestructionsController < ApplicationController
        include WebauthnRequest

        before_action :authenticate_user!

        def passkey_options
          action, target = destruction_context
          passkeys = CredentialDestruction.passkeys_for(user: account_user, action:, target:)
          raise CredentialDestruction::Error, "no eligible passkey" unless passkeys.exists?

          public_key = WebAuthn::Credential.options_for_get(
            allow: passkeys.map { |passkey| { id: passkey.webauthn_id, transports: passkey.transports } },
            user_verification: "required"
          )
          _record, raw_token = WebauthnChallenge.issue!(
            purpose: "destroy", challenge: public_key.challenge, user: account_user,
            session_binding: webauthn_session_binding, action:, target:
          )
          render json: { challenge_token: raw_token, public_key: public_key.as_json }
        rescue ActiveRecord::RecordNotFound, ActiveRecord::RecordInvalid, CredentialDestruction::Error
          render_webauthn_error
        end

        def destroy_with_passkey
          action, target = destruction_context
          challenge = WebauthnChallenge.for_token!(params.require(:challenge_token))
          challenge.verify_context!(
            purpose: "destroy", user: account_user, action:, target:,
            session_binding: webauthn_session_binding
          )
          assertion = WebAuthn::Credential.from_get(params.require(:credential).to_unsafe_h)
          authenticator = CredentialDestruction.passkeys_for(user: account_user, action:, target:)
            .find_by!(webauthn_id: assertion.id)
          unless assertion.user_handle == account_user.webauthn_id
            raise WebauthnChallenge::VerificationError, "user handle mismatch"
          end

          WebauthnChallenge.transaction do
            authenticator.verify_and_update!(assertion, challenge: challenge.challenge)
            challenge.consume!
            CredentialDestruction.execute!(user: account_user, action:, target:, authenticator:)
          end
          finish_destruction(action)
        rescue ActionController::ParameterMissing, ActiveRecord::RecordNotFound, ActiveRecord::RecordInvalid,
          CredentialDestruction::Error, WebAuthn::Error, PasskeyCredential::VerificationError,
          WebauthnChallenge::VerificationError
          render_webauthn_error
        end

        private
          def account_user
            T.must(current_user)
          end

          def destruction_context
            action = params.require(:destruction_action)
            target = CredentialDestruction.target_for!(
              user: account_user,
              action:,
              target_id: Integer(params.require(:target_id), exception: true)
            )
            CredentialDestruction.ensure_alternative!(user: account_user, action:, target:)
            [action, target]
          end

          def finish_destruction(action)
            if action == "delete_account"
              sign_out(:user)
              flash[:notice] = t("accounts.destroy.notice")
              render json: { redirect_url: root_path }
            else
              path = action == "delete_passkey" ? account_passkeys_path : T.unsafe(self).account_siwe_identities_path
              render json: { redirect_url: path }
            end
          end
      end
    end
  RUBY
end

def install_passkey_javascript
  create_file "app/javascript/controllers/passkey_controller.js", <<~'JAVASCRIPT', force: true
    import { Controller } from "@hotwired/stimulus"

    export default class extends Controller {
      static targets = ["error", "rememberMe"]
      static values = {
        ceremony: String,
        optionsUrl: String,
        verifyUrl: String,
        targetId: Number,
        destructionAction: String,
        unsupported: String,
        failed: String
      }

      async authenticate() {
        this.hideError()

        try {
          if (!window.PublicKeyCredential ||
              typeof PublicKeyCredential.parseCreationOptionsFromJSON !== "function" ||
              typeof PublicKeyCredential.parseRequestOptionsFromJSON !== "function" ||
              typeof PublicKeyCredential.prototype.toJSON !== "function") {
            throw new Error(this.unsupportedValue)
          }

          const context = {}
          if (this.hasTargetIdValue) context.target_id = this.targetIdValue
          if (this.hasDestructionActionValue) context.destruction_action = this.destructionActionValue
          if (this.hasRememberMeTarget) context.remember_me = this.rememberMeTarget.checked

          const optionsResponse = await this.post(this.optionsUrlValue, context)
          if (!optionsResponse.ok) throw new Error(this.failedValue)
          const options = await optionsResponse.json()
          const credential = this.ceremonyValue === "create"
            ? await navigator.credentials.create({
                publicKey: PublicKeyCredential.parseCreationOptionsFromJSON(options.public_key)
              })
            : await navigator.credentials.get({
                publicKey: PublicKeyCredential.parseRequestOptionsFromJSON(options.public_key)
              })
          if (!credential) throw new Error(this.failedValue)

          const verificationResponse = await this.post(this.verifyUrlValue, {
            ...context,
            challenge_token: options.challenge_token,
            credential: credential.toJSON()
          })
          if (!verificationResponse.ok) throw new Error(this.failedValue)
          window.location.assign((await verificationResponse.json()).redirect_url)
        } catch (error) {
          this.showError(error.message)
        }
      }

      post(url, body) {
        const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content
        return fetch(url, {
          method: "POST",
          headers: { "Content-Type": "application/json", "X-CSRF-Token": csrfToken, Accept: "application/json" },
          body: JSON.stringify(body)
        })
      }

      hideError() {
        this.errorTarget.classList.add("hidden")
        this.errorTarget.textContent = ""
      }

      showError(message) {
        this.errorTarget.textContent = message
        this.errorTarget.classList.remove("hidden")
      }
    }
  JAVASCRIPT
end

def install_passkey_views
  siwe_destruction = if VALUES.fetch("additional_login_methods").include?("siwe")
    <<~'ERB'
      <div data-controller="siwe-sign-in"
           data-siwe-sign-in-mode-value="destroy"
           data-siwe-sign-in-challenge-url-value="<%= account_siwe_credential_destruction_challenge_path %>"
           data-siwe-sign-in-verify-url-value="<%= account_siwe_credential_destruction_path %>"
           data-siwe-sign-in-target-id-value="<%= @passkey.id %>"
           data-siwe-sign-in-destruction-action-value="delete_passkey"
           data-siwe-sign-in-wallet-missing-value="<%= t('siwe.errors.wallet_missing') %>"
           data-siwe-sign-in-challenge-error-value="<%= t('siwe.errors.challenge') %>"
           data-siwe-sign-in-verification-error-value="<%= t('siwe.errors.verification') %>">
        <button type="button" class="btn btn-error btn-rapid" data-action="siwe-sign-in#authenticate"><%= t("passkeys.delete_with_wallet") %></button>
        <div class="alert alert-error mt-4 hidden" role="alert" data-siwe-sign-in-target="error"></div>
      </div>
    ERB
  else
    ""
  end

  create_file "app/views/account/passkeys/index.html.erb", <<~'ERB', force: true
    <% content_for :page_title, t("passkeys.title") %>

    <section class="space-y-5">
      <div class="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
        <p class="text-base-content/70"><%= t("passkeys.description") %></p>
        <%= link_to t("passkeys.add"), new_account_passkey_path, class: "btn btn-primary btn-rapid" %>
      </div>

      <ul class="list gap-3">
        <% @passkeys.each do |passkey| %>
          <li class="list-row border-base-300 border">
            <div class="list-col-grow">
              <p class="font-semibold"><%= passkey.name %></p>
              <span class="badge badge-outline"><%= t(passkey.backup_state? ? "passkeys.backed_up" : "passkeys.not_backed_up") %></span>
            </div>
            <div class="flex flex-wrap justify-end gap-2">
              <%= link_to t("common.edit"), edit_account_passkey_path(passkey), class: "btn btn-rapid" %>
              <%= link_to t("passkeys.delete"), account_passkey_path(passkey), class: "btn btn-error btn-rapid" %>
            </div>
          </li>
        <% end %>
      </ul>
    </section>
  ERB

  create_file "app/views/account/passkeys/new.html.erb", <<~'ERB', force: true
    <% content_for :page_title, t("passkeys.new_title") %>

    <section class="space-y-5"
             data-controller="passkey"
             data-passkey-ceremony-value="create"
             data-passkey-options-url-value="<%= options_account_passkeys_path %>"
             data-passkey-verify-url-value="<%= account_passkeys_path %>"
             data-passkey-unsupported-value="<%= t('passkeys.errors.unsupported') %>"
             data-passkey-failed-value="<%= t('passkeys.errors.verification') %>">
      <p class="text-base-content/70"><%= t("passkeys.new_description") %></p>
      <div class="alert alert-error hidden" role="alert" data-passkey-target="error"></div>
      <div class="flex justify-end gap-2">
        <%= link_to t("common.back"), account_passkeys_path, class: "btn btn-rapid" %>
        <button type="button" class="btn btn-primary btn-rapid" data-action="passkey#authenticate"><%= t("passkeys.register") %></button>
      </div>
    </section>
  ERB

  create_file "app/views/account/passkeys/edit.html.erb", <<~'ERB', force: true
    <% content_for :page_title, t("passkeys.edit_title") %>

    <%= form_with model: @passkey, url: account_passkey_path(@passkey), class: "space-y-5" do |form| %>
      <% if @passkey.errors.any? %>
        <div class="alert alert-error" role="alert"><span><%= @passkey.errors.full_messages.to_sentence %></span></div>
      <% end %>
      <fieldset class="fieldset">
        <legend class="fieldset-legend"><%= form.label :name, t("passkeys.name") %></legend>
        <%= form.text_field :name, required: true, maxlength: 50, class: "input input-rapid w-full" %>
      </fieldset>
      <div class="flex justify-end gap-2">
        <%= link_to t("common.back"), account_passkeys_path, class: "btn btn-rapid" %>
        <%= form.submit t("common.update"), class: "btn btn-primary btn-rapid" %>
      </div>
    <% end %>
  ERB

  create_file "app/views/account/passkeys/show.html.erb", <<~ERB, force: true
    <% content_for :page_title, t("passkeys.delete_title") %>

    <section class="space-y-5">
      <p class="font-semibold"><%= @passkey.name %></p>
      <p class="text-base-content/70"><%= t("passkeys.delete_description") %></p>
      <div class="flex flex-wrap justify-end gap-2">
        <%= link_to t("common.back"), account_passkeys_path, class: "btn btn-rapid" %>
        <% if CredentialDestruction.passkeys_for(user: current_user, action: "delete_passkey", target: @passkey).exists? %>
          <div data-controller="passkey"
               data-passkey-ceremony-value="get"
               data-passkey-options-url-value="<%= account_passkey_credential_destruction_options_path %>"
               data-passkey-verify-url-value="<%= account_passkey_credential_destruction_path %>"
               data-passkey-target-id-value="<%= @passkey.id %>"
               data-passkey-destruction-action-value="delete_passkey"
               data-passkey-unsupported-value="<%= t('passkeys.errors.unsupported') %>"
               data-passkey-failed-value="<%= t('passkeys.errors.verification') %>">
            <button type="button" class="btn btn-error btn-rapid" data-action="passkey#authenticate"><%= t("passkeys.delete_with_passkey") %></button>
            <div class="alert alert-error mt-4 hidden" role="alert" data-passkey-target="error"></div>
          </div>
        <% end %>
    #{siwe_destruction.lines.map { |line| "    #{line}" }.join}  </div>
    </section>
  ERB

  create_locale_pair(
    "passkeys",
    ja: {
      "passkeys" => {
        "title" => "Passkeys", "description" => "ログインに使用できるPasskeyを管理します。", "add" => "Passkeyを追加",
        "new_title" => "Passkeyを登録", "new_description" => "この端末またはセキュリティキーへPasskeyを登録します。", "register" => "Passkeyを登録",
        "edit_title" => "Passkeyを編集", "name" => "Passkey名", "updated" => "Passkey名を更新しました。",
        "backed_up" => "同期済み", "not_backed_up" => "未バックアップ", "delete" => "解除", "delete_title" => "Passkeyを解除",
        "delete_description" => "削除対象とは別のログイン方法で再認証してください。", "delete_with_passkey" => "別のPasskeyで解除",
        "delete_with_wallet" => "ウォレットで解除",
        "errors" => { "unsupported" => "このブラウザは必要なWebAuthn APIに対応していません。", "verification" => "Passkeyを検証できませんでした。", "last_credential" => "最後のログイン方法は解除できません。" }
      }
    },
    en: {
      "passkeys" => {
        "title" => "Passkeys", "description" => "Manage the passkeys that can sign in to your account.", "add" => "Add passkey",
        "new_title" => "Register passkey", "new_description" => "Register a passkey on this device or a security key.", "register" => "Register passkey",
        "edit_title" => "Edit passkey", "name" => "Passkey name", "updated" => "Passkey name updated.",
        "backed_up" => "Synced", "not_backed_up" => "Not backed up", "delete" => "Remove", "delete_title" => "Remove passkey",
        "delete_description" => "Reauthenticate with a different sign-in method before removing this passkey.", "delete_with_passkey" => "Remove with another passkey",
        "delete_with_wallet" => "Remove with wallet",
        "errors" => { "unsupported" => "This browser does not support the required WebAuthn APIs.", "verification" => "The passkey could not be verified.", "last_credential" => "You cannot remove your last sign-in method." }
      }
    }
  )
end

def install_passkey_tests
  create_file "test/models/webauthn_challenge_test.rb", <<~'RUBY', force: true
    require "test_helper"

    class WebauthnChallengeTest < ActiveSupport::TestCase
      test "binds purpose user target browser and one-time consumption" do
        user = users(:one)
        target = passkey_credentials(:one)
        challenge, token = WebauthnChallenge.issue!(
          purpose: "destroy",
          challenge: "challenge",
          session_binding: "browser",
          user:,
          action: "delete_passkey",
          target:
        )

        assert_equal challenge, WebauthnChallenge.for_token!(token)
        challenge.verify_context!(
          purpose: "destroy", session_binding: "browser", user:,
          action: "delete_passkey", target:
        )
        assert_raises(WebauthnChallenge::VerificationError) do
          challenge.verify_context!(
            purpose: "destroy", session_binding: "other", user:,
            action: "delete_passkey", target:
          )
        end
        challenge.consume!
        assert_raises(WebauthnChallenge::VerificationError) { challenge.consume! }
      end

      test "rejects expired challenges" do
        challenge, = WebauthnChallenge.issue!(
          purpose: "login", challenge: "challenge", session_binding: "browser"
        )

        travel_to challenge.expires_at + 1.second do
          assert_raises(WebauthnChallenge::VerificationError) do
            challenge.verify_context!(purpose: "login", session_binding: "browser")
          end
        end
      end
    end
  RUBY

  create_file "test/controllers/users/passkey_authentication_controller_test.rb", <<~'RUBY', force: true
    require "test_helper"
    require "webauthn/fake_client"

    class Users::PasskeyAuthenticationControllerTest < ActionDispatch::IntegrationTest
      include Devise::Test::IntegrationHelpers

      test "signs up and signs in with a discoverable synced passkey" do
        client = WebAuthn::FakeClient.new(Rails.configuration.x.application_identity.canonical_origin)

        post user_passkey_registration_options_url, as: :json
        registration = response.parsed_body
        credential = client.create(
          challenge: registration.dig("public_key", "challenge"),
          user_verified: true,
          backup_eligibility: true,
          backup_state: true
        )
        assert_difference ["User.count", "PasskeyCredential.count"], 1 do
          post user_passkey_registration_url,
            params: { challenge_token: registration.fetch("challenge_token"), credential: }, as: :json
        end
        assert_response :created
        user = T.must(User.order(:id).last)
        assert_equal registration.dig("public_key", "user", "id"), user.webauthn_id
        stored = user.passkey_credentials.sole
        assert_predicate stored, :backup_eligible?
        assert_predicate stored, :backup_state?

        delete destroy_user_session_url
        post user_passkey_session_options_url, as: :json
        authentication = response.parsed_body
        assertion = client.get(
          challenge: authentication.dig("public_key", "challenge"),
          user_verified: true,
          backup_eligibility: true,
          backup_state: true,
          user_handle: WebAuthn.configuration.encoder.decode(user.webauthn_id),
          allow_credentials: [stored.webauthn_id]
        )
        post user_passkey_session_url,
          params: { challenge_token: authentication.fetch("challenge_token"), credential: assertion }, as: :json
        assert_response :success
        assert_predicate stored.reload.last_used_at, :present?
        assert_nil flash[:credential_risk]
      end

      test "warns for a sole passkey with BS zero and rejects invalid backup flags" do
        client = WebAuthn::FakeClient.new(Rails.configuration.x.application_identity.canonical_origin)
        post user_passkey_registration_options_url, as: :json
        registration = response.parsed_body
        credential = client.create(
          challenge: registration.dig("public_key", "challenge"),
          user_verified: true,
          backup_eligibility: false,
          backup_state: false
        )
        post user_passkey_registration_url,
          params: { challenge_token: registration.fetch("challenge_token"), credential: }, as: :json
        assert_response :created
        assert_equal true, flash[:credential_risk]

        delete destroy_user_session_url
        invalid_client = WebAuthn::FakeClient.new(Rails.configuration.x.application_identity.canonical_origin)
        post user_passkey_registration_options_url, as: :json
        invalid_registration = response.parsed_body
        invalid = invalid_client.create(
          challenge: invalid_registration.dig("public_key", "challenge"),
          user_verified: true,
          backup_eligibility: false,
          backup_state: true
        )
        assert_no_difference ["User.count", "PasskeyCredential.count"] do
          post user_passkey_registration_url,
            params: { challenge_token: invalid_registration.fetch("challenge_token"), credential: invalid }, as: :json
        end
        assert_response :unprocessable_content
      end

      test "rejects a changed backup eligibility during authentication" do
        client = WebAuthn::FakeClient.new(Rails.configuration.x.application_identity.canonical_origin)
        post user_passkey_registration_options_url, as: :json
        registration = response.parsed_body
        credential = client.create(
          challenge: registration.dig("public_key", "challenge"),
          user_verified: true,
          backup_eligibility: false,
          backup_state: false
        )
        post user_passkey_registration_url,
          params: { challenge_token: registration.fetch("challenge_token"), credential: }, as: :json
        user = T.must(User.order(:id).last)
        stored = user.passkey_credentials.sole
        delete destroy_user_session_url

        post user_passkey_session_options_url, as: :json
        authentication = response.parsed_body
        assertion = client.get(
          challenge: authentication.dig("public_key", "challenge"),
          user_verified: true,
          backup_eligibility: true,
          backup_state: false,
          user_handle: WebAuthn.configuration.encoder.decode(user.webauthn_id),
          allow_credentials: [stored.webauthn_id]
        )
        post user_passkey_session_url,
          params: { challenge_token: authentication.fetch("challenge_token"), credential: assertion }, as: :json

        assert_response :unauthorized
        assert_nil stored.reload.last_used_at
      end

      test "removes a passkey only after authenticating with a different passkey" do
        user = users(:one)
        target = passkey_credentials(:one)
        client = WebAuthn::FakeClient.new(Rails.configuration.x.application_identity.canonical_origin)
        sign_in user

        post options_account_passkeys_url, as: :json
        registration = response.parsed_body
        credential = client.create(
          challenge: registration.dig("public_key", "challenge"),
          user_verified: true,
          backup_eligibility: true,
          backup_state: true
        )
        post account_passkeys_url,
          params: { challenge_token: registration.fetch("challenge_token"), credential: }, as: :json
        assert_response :created
        authenticator = T.must(user.passkey_credentials.order(:id).last)

        post account_passkey_credential_destruction_options_url,
          params: { destruction_action: "delete_passkey", target_id: target.id }, as: :json
        destruction = response.parsed_body
        assertion = client.get(
          challenge: destruction.dig("public_key", "challenge"),
          user_verified: true,
          backup_eligibility: true,
          backup_state: true,
          user_handle: WebAuthn.configuration.encoder.decode(user.webauthn_id),
          allow_credentials: [authenticator.webauthn_id]
        )
        post account_passkey_credential_destruction_url,
          params: {
            destruction_action: "delete_passkey",
            target_id: target.id,
            challenge_token: destruction.fetch("challenge_token"),
            credential: assertion
          }, as: :json

        assert_response :success
        assert_not PasskeyCredential.exists?(target.id)
        assert PasskeyCredential.exists?(authenticator.id)

        post account_passkey_credential_destruction_options_url,
          params: { destruction_action: "delete_passkey", target_id: authenticator.id }, as: :json
        assert_response :unprocessable_content
      end

      test "deletes the account only after a fresh passkey assertion" do
        user = users(:one)
        client = WebAuthn::FakeClient.new(Rails.configuration.x.application_identity.canonical_origin)
        sign_in user

        post options_account_passkeys_url, as: :json
        registration = response.parsed_body
        credential = client.create(
          challenge: registration.dig("public_key", "challenge"),
          user_verified: true,
          backup_eligibility: true,
          backup_state: true
        )
        post account_passkeys_url,
          params: { challenge_token: registration.fetch("challenge_token"), credential: }, as: :json
        authenticator = T.must(user.passkey_credentials.order(:id).last)

        post account_passkey_credential_destruction_options_url,
          params: { destruction_action: "delete_account", target_id: user.id }, as: :json
        destruction = response.parsed_body
        assertion = client.get(
          challenge: destruction.dig("public_key", "challenge"),
          user_verified: true,
          backup_eligibility: true,
          backup_state: true,
          user_handle: WebAuthn.configuration.encoder.decode(user.webauthn_id),
          allow_credentials: [authenticator.webauthn_id]
        )

        assert_difference "User.count", -1 do
          post account_passkey_credential_destruction_url,
            params: {
              destruction_action: "delete_account",
              target_id: user.id,
              challenge_token: destruction.fetch("challenge_token"),
              credential: assertion
            }, as: :json
        end
        assert_response :success
        assert_not User.exists?(user.id)
      end
    end
  RUBY

  create_file "test/system/passkey_authentication_test.rb", <<~'RUBY', force: true
    require "application_system_test_case"
    require "uri"

    class PasskeyAuthenticationTest < ApplicationSystemTestCase
      test "registers and signs in with a device-bound passkey and shows the risk warning" do
        install_virtual_authenticator(backup_eligible: false, backup_state: false)
        visit new_user_registration_path
        configure_webauthn_for_current_page

        click_button I18n.t("authentication.sign_up_with_passkey")

        assert_current_path root_path
        assert_selector ".alert-warning", text: I18n.t("credential_risk.warning")
        assert_link I18n.t("credential_risk.add_login_method"), href: account_passkeys_path
        assert_no_selector ".alert-warning .btn"
        assert_equal [false, false], PasskeyCredential.order(:id).last.then { |passkey| [passkey.backup_eligible?, passkey.backup_state?] }

        open_account_menu_and_sign_out
        visit new_user_session_path
        click_button I18n.t("authentication.sign_in_with_passkey")
        assert_current_path root_path
        assert_selector ".alert-warning", text: I18n.t("credential_risk.warning")
      end

      test "updates backup state after authentication and stops warning for a synced passkey" do
        cdp = install_virtual_authenticator(backup_eligible: true, backup_state: false)
        visit new_user_registration_path
        configure_webauthn_for_current_page
        click_button I18n.t("authentication.sign_up_with_passkey")
        assert_selector ".alert-warning", text: I18n.t("credential_risk.warning")

        credential_id = cdp.send_message("WebAuthn.getCredentials", params: { authenticatorId: @authenticator_id })
          .fetch("credentials").sole.fetch("credentialId")
        cdp.send_message(
          "WebAuthn.setCredentialProperties",
          params: { authenticatorId: @authenticator_id, credentialId: credential_id, backupState: true }
        )
        open_account_menu_and_sign_out
        visit new_user_session_path
        click_button I18n.t("authentication.sign_in_with_passkey")

        assert_current_path root_path
        assert_no_selector ".alert-warning", text: I18n.t("credential_risk.warning")
        assert_predicate T.must(PasskeyCredential.order(:id).last).reload, :backup_state?
      end

      private
        def open_account_menu_and_sign_out
          find("header details.dropdown > summary", visible: :visible).click
          click_link I18n.t("navigation.sign_out")
          assert_current_path root_path
          assert_selector %(header a[href="#{new_user_session_path}"]), visible: :visible
        end

        def install_virtual_authenticator(backup_eligible:, backup_state:)
          page.driver.with_playwright_page do |playwright_page|
            cdp = playwright_page.context.new_cdp_session(playwright_page)
            cdp.send_message("WebAuthn.enable")
            result = cdp.send_message(
              "WebAuthn.addVirtualAuthenticator",
              params: {
                options: {
                  protocol: "ctap2",
                  transport: "internal",
                  hasResidentKey: true,
                  hasUserVerification: true,
                  isUserVerified: true,
                  automaticPresenceSimulation: true,
                  defaultBackupEligibility: backup_eligible,
                  defaultBackupState: backup_state
                }
              }
            )
            @authenticator_id = result.fetch("authenticatorId")
            cdp
          end
        end

        def configure_webauthn_for_current_page
          origin = URI(page.current_url)
          canonical_origin = "#{origin.scheme}://#{origin.host}:#{origin.port}"
          WebAuthn.configure do |config|
            config.allowed_origins = [canonical_origin]
            config.rp_id = origin.host
          end
        end
    end
  RUBY
end

def install_siwe
  generate "migration", "CreateSiweIdentities"
  generate "migration", "CreateSiweChallenges"

  identity_migrations = Dir.glob("db/migrate/*_create_siwe_identities.rb")
  challenge_migrations = Dir.glob("db/migrate/*_create_siwe_challenges.rb")
  raise "CreateSiweIdentities migrationが一意ではありません" unless identity_migrations.one?
  raise "CreateSiweChallenges migrationが一意ではありません" unless challenge_migrations.one?

  create_file identity_migrations.first, <<~'RUBY', force: true
    class CreateSiweIdentities < ActiveRecord::Migration[8.1]
      def change
        create_table :siwe_identities do |t|
          t.references :user, null: false, foreign_key: { on_delete: :cascade }
          t.string :name, null: false
          t.string :address, null: false
          t.timestamps null: false
        end

        add_index :siwe_identities, :address, unique: true
      end
    end
  RUBY
  create_file challenge_migrations.first, <<~'RUBY', force: true
    class CreateSiweChallenges < ActiveRecord::Migration[8.1]
      def change
        create_table :siwe_challenges do |t|
          t.references :user, null: true, foreign_key: { on_delete: :cascade }
          t.string :purpose, null: false
          t.string :token_digest, null: false
          t.string :session_digest, null: false
          t.string :address, null: false
          t.integer :chain_id, null: false
          t.text :message, null: false
          t.string :nonce, null: false
          t.string :action
          t.string :target_type
          t.bigint :target_id
          t.datetime :expires_at, null: false
          t.datetime :consumed_at
          t.timestamps null: false
        end

        add_index :siwe_challenges, :token_digest, unique: true
        add_index :siwe_challenges, :expires_at
        add_index :siwe_challenges, :consumed_at
        add_check_constraint :siwe_challenges, "purpose IN ('signup', 'login', 'link', 'destroy')", name: "siwe_challenges_purpose"
        add_check_constraint :siwe_challenges, "chain_id > 0", name: "siwe_challenges_positive_chain_id"
        add_check_constraint :siwe_challenges,
          "(purpose IN ('signup', 'login') AND user_id IS NULL) OR (purpose IN ('link', 'destroy') AND user_id IS NOT NULL)",
          name: "siwe_challenges_user_matches_purpose"
        add_check_constraint :siwe_challenges,
          "purpose = 'destroy' OR (action IS NULL AND target_type IS NULL AND target_id IS NULL)",
          name: "siwe_challenges_target_matches_purpose"
      end
    end
  RUBY

  create_file "lib/devise/models/siweable.rb", <<~'RUBY', force: true
    module Devise
      module Models
        module Siweable
          extend ActiveSupport::Concern

          included do
            T.bind(self, T.class_of(User))
            has_many :siwe_identities, dependent: :destroy
            has_many :siwe_challenges, dependent: :destroy
          end
        end
      end
    end
  RUBY
  create_file "lib/devise/siweable.rb", <<~'RUBY', force: true
    require "devise"
    require_relative "models/siweable"

    module Devise
      module Siweable; end
    end

    Devise.add_module(:siweable, model: "devise/models/siweable")
  RUBY
  create_file "config/initializers/devise_siweable.rb", <<~'RUBY', force: true
    require Rails.root.join("lib/devise/siweable")

    Rails.application.config.filter_parameters += %i[challenge_token signature]
  RUBY

  route <<~'RUBY'
    namespace :account do
      post "credential_destructions/siwe/challenge",
        to: "credential_destructions#siwe_challenge",
        as: :siwe_credential_destruction_challenge
      post "credential_destructions/siwe",
        to: "credential_destructions#destroy_with_siwe",
        as: :siwe_credential_destruction
    end
  RUBY

  create_file "app/models/siwe_identity.rb", <<~'RUBY', force: true
    class SiweIdentity < ApplicationRecord
      belongs_to :user

      normalizes :name, with: ->(name) { name.to_s.strip }
      normalizes :address, with: ->(address) { address.to_s.downcase }

      validates :name, presence: true, length: { maximum: 50 }
      validates :address,
        presence: true,
        format: { with: /\A0x[0-9a-f]{40}\z/ },
        uniqueness: { case_sensitive: true }
      validate :address_does_not_change, on: :update

      private
        def address_does_not_change
          errors.add(:address, :readonly) if will_save_change_to_address?
        end
    end
  RUBY

  create_file "app/models/siwe_challenge.rb", <<~'RUBY', force: true
    require "digest"
    require "securerandom"
    require "uri"

    class SiweChallenge < ApplicationRecord
      extend T::Sig

      VerificationError = Class.new(StandardError)
      TTL = 5.minutes
      PURPOSES = %w[signup login link destroy].freeze
      ACTIONS = %w[delete_passkey delete_siwe delete_account].freeze
      EOA_VERIFICATION = Siwe::Config.new.freeze

      belongs_to :user, optional: true

      validates :purpose, inclusion: { in: PURPOSES }
      validates :token_digest, :session_digest, :address, :message, :nonce, :expires_at, presence: true
      validates :token_digest, uniqueness: true
      validates :address, format: { with: /\A0x[0-9a-f]{40}\z/ }
      validates :chain_id, numericality: { only_integer: true, greater_than: 0 }
      validates :action, inclusion: { in: ACTIONS }, allow_nil: true
      validate :context_matches_purpose

      sig do
        params(
          purpose: String,
          address: String,
          chain_id: T.any(String, Integer),
          session_binding: String,
          user: T.nilable(User),
          action: T.nilable(String),
          target: T.nilable(ActiveRecord::Base)
        ).returns([SiweChallenge, String])
      end
      def self.issue!(purpose:, address:, chain_id:, session_binding:, user: nil, action: nil, target: nil)
        now = Time.current
        where("expires_at <= ? OR consumed_at IS NOT NULL", now).delete_all
        numeric_chain_id = T.let(Integer(chain_id, exception: false), T.nilable(Integer))
        raise VerificationError, "invalid chain id" unless numeric_chain_id&.positive?

        identity = Rails.configuration.x.application_identity
        origin = URI.parse(identity.canonical_origin)
        nonce = Siwe.generate_nonce
        expires_at = now + TTL
        siwe_message = Siwe::Message.new(
          domain: domain_for(origin),
          address:,
          uri: identity.canonical_url(path_for(purpose)),
          chain_id: numeric_chain_id,
          nonce:,
          issued_at: now.utc.iso8601,
          expiration_time: expires_at.utc.iso8601,
          statement: identity.siwe_statement
        )
        raw_token = SecureRandom.urlsafe_base64(32)
        challenge = create!(
          user:,
          purpose:,
          token_digest: digest(raw_token),
          session_digest: digest(session_binding),
          address: siwe_message.address.downcase,
          chain_id: numeric_chain_id,
          message: siwe_message.prepare_message,
          nonce:,
          action:,
          target_type: target&.class&.name,
          target_id: target&.id,
          expires_at:,
          created_at: now,
          updated_at: now
        )
        [challenge, raw_token]
      rescue Siwe::Error, ArgumentError => error
        raise VerificationError, error.message
      end

      sig { params(raw_token: String).returns(SiweChallenge) }
      def self.for_token!(raw_token)
        find_by!(token_digest: digest(raw_token.to_s))
      end

      sig { params(value: String).returns(String) }
      def self.digest(value)
        Digest::SHA256.hexdigest(value.to_s)
      end

      sig { params(origin: URI::Generic).returns(String) }
      def self.domain_for(origin)
        default_port = origin.scheme == "https" ? 443 : 80
        host = origin.host
        raise VerificationError, "origin host is required" if host.nil?

        origin.port == default_port ? host : "#{host}:#{origin.port}"
      end

      sig { params(purpose: String).returns(String) }
      def self.path_for(purpose)
        case purpose
        when "signup" then "/users/sign_up/siwe"
        when "login" then "/users/sign_in/siwe"
        when "link" then "/account/siwe_identities"
        when "destroy" then "/account/credential_destructions/siwe"
        else raise VerificationError, "invalid purpose"
        end
      end

      sig do
        params(
          signature: String,
          purpose: String,
          session_binding: String,
          user: T.nilable(User),
          action: T.nilable(String),
          target: T.nilable(ActiveRecord::Base)
        )
          .returns(Siwe::Message)
      end
      def verify!(signature:, purpose:, session_binding:, user: nil, action: nil, target: nil)
        raise VerificationError, "challenge purpose mismatch" unless self.purpose == purpose
        raise VerificationError, "challenge user mismatch" unless user_id == user&.id
        raise VerificationError, "challenge action mismatch" unless self.action == action
        unless target_type == target&.class&.name && target_id == target&.id
          raise VerificationError, "challenge target mismatch"
        end
        raise VerificationError, "challenge expired" unless consumed_at.nil? && expires_at.future?
        actual_session_digest = self.class.digest(session_binding)
        unless ActiveSupport::SecurityUtils.secure_compare(session_digest, actual_session_digest)
          raise VerificationError, "challenge session mismatch"
        end

        identity = Rails.configuration.x.application_identity
        origin = URI.parse(identity.canonical_origin)
        parsed = Siwe::Message.parse(message)
        parsed.verify!(
          signature:,
          domain: self.class.domain_for(origin),
          nonce:,
          uri: identity.canonical_url(self.class.path_for(purpose)),
          chain_id:,
          config: EOA_VERIFICATION,
          strict: true
        )
        verify_server_fields!(parsed, identity)

        parsed
      rescue Siwe::Error, ArgumentError => error
        raise VerificationError, error.message
      end

      sig { returns(SiweChallenge) }
      def consume!
        # This conditional update is the compare-and-set that makes challenge consumption atomic.
        # rubocop:disable Rails/SkipsModelValidations
        consumed = self.class.where(id:, consumed_at: nil).where("expires_at > ?", Time.current)
          .update_all(consumed_at: Time.current)
        # rubocop:enable Rails/SkipsModelValidations
        raise VerificationError, "challenge already consumed" unless consumed == 1

        reload
      end

      private
        def verify_server_fields!(parsed, identity)
          expected = {
            scheme: nil,
            statement: identity.siwe_statement,
            version: "1",
            issued_at: created_at.utc.iso8601,
            expiration_time: expires_at.utc.iso8601,
            not_before: nil,
            request_id: nil,
            resources: nil
          }
          expected.each do |field, value|
            raise VerificationError, "challenge #{field} mismatch" unless parsed.public_send(field) == value
          end
          raise VerificationError, "challenge address mismatch" unless parsed.address.downcase == address
        end

        def context_matches_purpose
          valid_user = %w[signup login].include?(purpose) ? user_id.nil? : user_id.present?
          valid_target = if purpose == "destroy"
            action.present? && target_type.present? && target_id.present?
          else
            action.nil? && target_type.nil? && target_id.nil?
          end
          errors.add(:user, :invalid) unless valid_user
          errors.add(:target, :invalid) unless valid_target
        end
    end
  RUBY

  create_file "app/controllers/users/siwe_sessions_controller.rb", <<~'RUBY', force: true
    module Users
      class SiweSessionsController < DeviseController
        extend T::Sig

        after_action :prevent_challenge_caching
        rate_limit(
          to: 10,
          within: 1.minute,
          only: %i[challenge create],
          by: -> {
            T.bind(self, Users::SiweSessionsController)
            "#{request.remote_ip}:#{session_binding}"
          },
          with: -> {
            T.bind(self, Users::SiweSessionsController)
            head :too_many_requests
          }
        )

        sig { void }
        def challenge
          record, raw_token = SiweChallenge.issue!(
            purpose: "login",
            address: params.require(:address),
            chain_id: params.require(:chain_id),
            session_binding:
          )
          render json: { challenge_token: raw_token, message: record.message }
        rescue ActionController::ParameterMissing, ActiveRecord::RecordInvalid, SiweChallenge::VerificationError
          head :unprocessable_content
        end

        sig { void }
        def create
          challenge = SiweChallenge.for_token!(params.require(:challenge_token))
          message = challenge.verify!(
            signature: params.require(:signature),
            purpose: "login",
            session_binding:
          )
          challenge.consume!
          user = SiweIdentity.includes(:user).find_by(address: message.address.downcase)&.user
          return head :unauthorized unless user&.active_for_authentication?

          request.env["devise.skip_timeout"] = true
          sign_in(:user, user, event: :authentication)
          remember_me(user) if ActiveModel::Type::Boolean.new.cast(params[:remember_me])
          flash[:credential_risk] = true if user.credential_loss_risk?
          render json: { redirect_url: after_sign_in_path_for(user) }
        rescue ActionController::ParameterMissing, ActiveRecord::RecordNotFound, SiweChallenge::VerificationError
          head :unauthorized
        end

        private
          def session_binding
            session[:siwe_binding] ||= SecureRandom.hex(32)
          end

          def prevent_challenge_caching
            response.set_header("Cache-Control", "no-store")
          end
      end
    end
  RUBY

  create_file "app/controllers/users/siwe_registrations_controller.rb", <<~'RUBY', force: true
    module Users
      class SiweRegistrationsController < DeviseController
        extend T::Sig

        after_action :prevent_challenge_caching
        rate_limit to: 10, within: 1.minute, only: %i[challenge create],
          by: -> {
            T.bind(self, Users::SiweRegistrationsController)
            "#{request.remote_ip}:#{session_binding}"
          },
          with: -> {
            T.bind(self, Users::SiweRegistrationsController)
            head :too_many_requests
          }

        def challenge
          record, raw_token = SiweChallenge.issue!(
            purpose: "signup",
            address: params.require(:address),
            chain_id: params.require(:chain_id),
            session_binding:
          )
          render json: { challenge_token: raw_token, message: record.message }
        rescue ActionController::ParameterMissing, ActiveRecord::RecordInvalid, SiweChallenge::VerificationError
          head :unprocessable_content
        end

        def create
          challenge = SiweChallenge.for_token!(params.require(:challenge_token))
          message = challenge.verify!(
            signature: params.require(:signature),
            purpose: "signup",
            session_binding:
          )
          user = T.let(nil, T.nilable(User))
          SiweChallenge.transaction do
            raise ActiveRecord::RecordNotUnique if SiweIdentity.exists?(address: message.address.downcase)

            challenge.consume!
            user = User.create!
            T.must(user).siwe_identities.create!(name: "Wallet #1", address: message.address)
          end
          request.env["devise.skip_timeout"] = true
          sign_in(:user, T.must(user), event: :authentication)
          render json: { redirect_url: after_sign_in_path_for(T.must(user)) }, status: :created
        rescue ActionController::ParameterMissing, ActiveRecord::RecordNotFound, ActiveRecord::RecordInvalid,
          ActiveRecord::RecordNotUnique, SiweChallenge::VerificationError
          head :unprocessable_content
        end

        private
          def session_binding
            session[:siwe_binding] ||= SecureRandom.hex(32)
          end

          def prevent_challenge_caching
            response.set_header("Cache-Control", "no-store")
          end
      end
    end
  RUBY

  inject_into_class "app/controllers/account/credential_destructions_controller.rb", "CredentialDestructionsController", <<~'RUBY'
      after_action :prevent_siwe_challenge_caching, only: %i[siwe_challenge destroy_with_siwe]
      rate_limit to: 10, within: 1.minute, only: %i[siwe_challenge destroy_with_siwe],
        by: -> {
          T.bind(self, Account::CredentialDestructionsController)
          "#{request.remote_ip}:#{siwe_session_binding}"
        },
        with: -> {
          T.bind(self, Account::CredentialDestructionsController)
          head :too_many_requests
        }

      def siwe_challenge
        action, target = destruction_context
        identities = CredentialDestruction.siwe_identities_for(user: account_user, action:, target:)
        address = params.require(:address).downcase
        raise CredentialDestruction::Error, "ineligible wallet" unless identities.exists?(address:)

        record, raw_token = SiweChallenge.issue!(
          purpose: "destroy",
          user: account_user,
          address:,
          chain_id: params.require(:chain_id),
          session_binding: siwe_session_binding,
          action:,
          target:
        )
        render json: { challenge_token: raw_token, message: record.message }
      rescue ActionController::ParameterMissing, ActiveRecord::RecordNotFound, ActiveRecord::RecordInvalid,
        CredentialDestruction::Error, SiweChallenge::VerificationError
        head :unprocessable_content
      end

      def destroy_with_siwe
        action, target = destruction_context
        challenge = SiweChallenge.for_token!(params.require(:challenge_token))
        message = challenge.verify!(
          signature: params.require(:signature),
          purpose: "destroy",
          user: account_user,
          session_binding: siwe_session_binding,
          action:,
          target:
        )
        authenticator = CredentialDestruction.siwe_identities_for(user: account_user, action:, target:)
          .find_by!(address: message.address.downcase)
        SiweChallenge.transaction do
          challenge.consume!
          CredentialDestruction.execute!(user: account_user, action:, target:, authenticator:)
        end
        finish_destruction(action)
      rescue ActionController::ParameterMissing, ActiveRecord::RecordNotFound, ActiveRecord::RecordInvalid,
        CredentialDestruction::Error, SiweChallenge::VerificationError
        head :unprocessable_content
      end

      def siwe_session_binding
        session[:siwe_binding] ||= SecureRandom.hex(32)
      end

      def prevent_siwe_challenge_caching
        response.set_header("Cache-Control", "no-store")
      end
      private :siwe_session_binding, :prevent_siwe_challenge_caching

  RUBY

  create_file "app/controllers/account/siwe_identities_controller.rb", <<~'RUBY', force: true
    module Account
      class SiweIdentitiesController < ApplicationController
        extend T::Sig

        layout "account_settings"
        before_action :authenticate_user!
        before_action :set_siwe_identity, only: %i[show edit update]
        after_action :prevent_challenge_caching, only: %i[challenge create]
        rate_limit(
          to: 10,
          within: 1.minute,
          only: %i[challenge create],
          by: -> {
            T.bind(self, Account::SiweIdentitiesController)
            "#{request.remote_ip}:#{session_binding}"
          },
          with: -> {
            T.bind(self, Account::SiweIdentitiesController)
            head :too_many_requests
          }
        )

        sig { void }
        def index
          @siwe_identities = account_user.siwe_identities.order(:created_at)
        end

        sig { void }
        def show
          CredentialDestruction.ensure_alternative!(user: account_user, action: "delete_siwe", target: @siwe_identity)
        rescue CredentialDestruction::Error
          redirect_to account_siwe_identities_path, alert: t("siwe.identities.last_credential")
        end

        sig { void }
        def new; end

        sig { void }
        def edit; end

        sig { void }
        def challenge
          record, raw_token = SiweChallenge.issue!(
            purpose: "link",
            user: account_user,
            address: params.require(:address),
            chain_id: params.require(:chain_id),
            session_binding:
          )
          render json: { challenge_token: raw_token, message: record.message }
        rescue ActionController::ParameterMissing, ActiveRecord::RecordInvalid, SiweChallenge::VerificationError
          head :unprocessable_content
        end

        sig { void }
        def create
          challenge = SiweChallenge.for_token!(params.require(:challenge_token))
          identity = T.let(nil, T.nilable(SiweIdentity))
          SiweChallenge.transaction do
            message = challenge.verify!(
              signature: params.require(:signature),
              purpose: "link",
              user: account_user,
              session_binding:
            )
            challenge.consume!
            identity = account_user.siwe_identities.create!(
              name: "Wallet ##{account_user.siwe_identities.count + 1}",
              address: message.address
            )
          end
          render json: { redirect_url: account_siwe_identities_path, id: T.must(identity).id }, status: :created
        rescue ActionController::ParameterMissing, ActiveRecord::RecordNotFound, ActiveRecord::RecordInvalid,
          ActiveRecord::RecordNotUnique, SiweChallenge::VerificationError
          head :unprocessable_content
        end

        sig { void }
        def update
          if @siwe_identity.update(params.expect(siwe_identity: [:name]))
            redirect_to account_siwe_identities_path, notice: t("siwe.identities.updated")
          else
            render :edit, status: :unprocessable_content
          end
        end

        private
          sig { returns(User) }
          def account_user
            T.must(current_user)
          end

          def set_siwe_identity
            @siwe_identity = account_user.siwe_identities.find(params.expect(:id))
          end

          def session_binding
            session[:siwe_binding] ||= SecureRandom.hex(32)
          end

          def prevent_challenge_caching
            response.set_header("Cache-Control", "no-store")
          end
      end
    end
  RUBY

  create_file "app/javascript/controllers/siwe_sign_in_controller.js", <<~'JAVASCRIPT', force: true
    import { Controller } from "@hotwired/stimulus"

    export default class extends Controller {
      static targets = ["error", "rememberMe"]
      static values = {
        mode: String,
        challengeUrl: String,
        verifyUrl: String,
        targetId: Number,
        destructionAction: String,
        walletMissing: String,
        challengeError: String,
        verificationError: String
      }

      async authenticate() {
        this.hideError()

        try {
          if (!window.ethereum) throw new Error(this.walletMissingValue)
          const [address] = await window.ethereum.request({ method: "eth_requestAccounts" })
          const chainIdHex = await window.ethereum.request({ method: "eth_chainId" })
          const context = {}
          if (this.hasTargetIdValue) context.target_id = this.targetIdValue
          if (this.hasDestructionActionValue) context.destruction_action = this.destructionActionValue
          if (this.hasRememberMeTarget) context.remember_me = this.rememberMeTarget.checked
          const challengePayload = { address, chain_id: Number.parseInt(chainIdHex, 16), ...context }

          const challengeResponse = await this.post(this.challengeUrlValue, challengePayload)
          if (!challengeResponse.ok) throw new Error(this.challengeErrorValue)
          const challenge = await challengeResponse.json()
          const signature = await window.ethereum.request({
            method: "personal_sign",
            params: [challenge.message, address]
          })
          const verifyPayload = { challenge_token: challenge.challenge_token, signature, ...context }

          const verificationResponse = await this.post(this.verifyUrlValue, verifyPayload)
          if (!verificationResponse.ok) throw new Error(this.verificationErrorValue)
          window.location.assign((await verificationResponse.json()).redirect_url)
        } catch (error) {
          this.showError(error.message)
        }
      }

      post(url, body) {
        const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content
        return fetch(url, {
          method: "POST",
          headers: { "Content-Type": "application/json", "X-CSRF-Token": csrfToken, Accept: "application/json" },
          body: JSON.stringify(body)
        })
      }

      hideError() {
        this.errorTarget.classList.add("hidden")
        this.errorTarget.textContent = ""
      }

      showError(message) {
        this.errorTarget.textContent = message
        this.errorTarget.classList.remove("hidden")
      }
    }
  JAVASCRIPT

  create_file "app/views/account/siwe_identities/index.html.erb", <<~'ERB', force: true
    <% content_for :page_title, t("siwe.identities.title") %>

    <section class="space-y-5">
        <div class="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
          <p class="text-base-content/70"><%= t("siwe.identities.description") %></p>
          <%= link_to t("siwe.identities.add"), new_account_siwe_identity_path, class: "btn btn-primary btn-rapid" %>
        </div>

        <% if @siwe_identities.any? %>
          <ul class="list gap-3">
            <% @siwe_identities.each do |identity| %>
              <li class="list-row border-base-300 border">
                <div class="list-col-grow">
                  <p class="font-semibold"><%= identity.name %></p>
                  <p class="break-all font-mono text-sm text-base-content/70"><%= identity.address %></p>
                </div>
                <div class="flex flex-wrap justify-end gap-2">
                  <%= link_to t("common.edit"), edit_account_siwe_identity_path(identity), class: "btn btn-rapid" %>
                  <%= link_to t("siwe.identities.delete"), account_siwe_identity_path(identity), class: "btn btn-error btn-rapid" %>
                </div>
              </li>
            <% end %>
          </ul>
        <% else %>
          <div class="alert" role="status"><span><%= t("siwe.identities.empty") %></span></div>
        <% end %>
    </section>
  ERB

  create_file "app/views/account/siwe_identities/new.html.erb", <<~'ERB', force: true
    <% content_for :page_title, t("siwe.identities.new_title") %>

    <section class="space-y-5"
             data-controller="siwe-sign-in"
             data-siwe-sign-in-mode-value="link"
             data-siwe-sign-in-challenge-url-value="<%= challenge_account_siwe_identities_path %>"
             data-siwe-sign-in-verify-url-value="<%= account_siwe_identities_path %>"
             data-siwe-sign-in-wallet-missing-value="<%= t('siwe.errors.wallet_missing') %>"
             data-siwe-sign-in-challenge-error-value="<%= t('siwe.errors.challenge') %>"
             data-siwe-sign-in-verification-error-value="<%= t('siwe.errors.verification') %>">
      <p class="text-base-content/70"><%= t("siwe.identities.new_description") %></p>
      <div class="alert alert-error hidden" role="alert" data-siwe-sign-in-target="error"></div>
      <div class="flex justify-end gap-2">
        <%= link_to t("common.back"), account_siwe_identities_path, class: "btn btn-rapid" %>
        <button type="button" class="btn btn-primary btn-rapid" data-action="siwe-sign-in#authenticate"><%= t("siwe.identities.connect") %></button>
      </div>
    </section>
  ERB

  create_file "app/views/account/siwe_identities/edit.html.erb", <<~'ERB', force: true
    <% content_for :page_title, t("siwe.identities.edit_title") %>

    <section class="space-y-5">
      <p class="break-all font-mono text-sm text-base-content/70"><%= @siwe_identity.address %></p>
      <%= form_with model: [:account, @siwe_identity], class: "space-y-5" do |form| %>
        <% if @siwe_identity.errors.any? %>
          <div class="alert alert-error" role="alert"><span><%= @siwe_identity.errors.full_messages.to_sentence %></span></div>
        <% end %>
        <fieldset class="fieldset">
          <legend class="fieldset-legend"><%= form.label :name, t("siwe.identities.name") %></legend>
          <%= form.text_field :name, required: true, maxlength: 50, class: "input input-rapid w-full" %>
        </fieldset>
        <div class="flex justify-end gap-2">
          <%= link_to t("common.back"), account_siwe_identities_path, class: "btn btn-rapid" %>
          <%= form.submit t("common.update"), class: "btn btn-primary btn-rapid" %>
        </div>
      <% end %>
    </section>
  ERB

  create_file "app/views/account/siwe_identities/show.html.erb", <<~'ERB', force: true
    <% content_for :page_title, t("siwe.identities.delete_title") %>

    <section class="space-y-5">
      <p class="font-semibold"><%= @siwe_identity.name %></p>
      <p class="break-all font-mono text-sm text-base-content/70"><%= @siwe_identity.address %></p>
      <p class="text-base-content/70"><%= t("siwe.identities.delete_description") %></p>
      <div class="flex flex-wrap justify-end gap-2">
        <%= link_to t("common.back"), account_siwe_identities_path, class: "btn btn-rapid" %>
        <% if current_user.passkey_credentials.exists? %>
          <div data-controller="passkey"
               data-passkey-ceremony-value="get"
               data-passkey-options-url-value="<%= account_passkey_credential_destruction_options_path %>"
               data-passkey-verify-url-value="<%= account_passkey_credential_destruction_path %>"
               data-passkey-target-id-value="<%= @siwe_identity.id %>"
               data-passkey-destruction-action-value="delete_siwe"
               data-passkey-unsupported-value="<%= t('passkeys.errors.unsupported') %>"
               data-passkey-failed-value="<%= t('passkeys.errors.verification') %>">
            <button type="button" class="btn btn-error btn-rapid" data-action="passkey#authenticate"><%= t("siwe.identities.delete_with_passkey") %></button>
            <div class="alert alert-error mt-4 hidden" role="alert" data-passkey-target="error"></div>
          </div>
        <% end %>
        <% if current_user.siwe_identities.where.not(id: @siwe_identity.id).exists? %>
          <div data-controller="siwe-sign-in"
               data-siwe-sign-in-mode-value="destroy"
               data-siwe-sign-in-challenge-url-value="<%= account_siwe_credential_destruction_challenge_path %>"
               data-siwe-sign-in-verify-url-value="<%= account_siwe_credential_destruction_path %>"
               data-siwe-sign-in-target-id-value="<%= @siwe_identity.id %>"
               data-siwe-sign-in-destruction-action-value="delete_siwe"
               data-siwe-sign-in-wallet-missing-value="<%= t('siwe.errors.wallet_missing') %>"
               data-siwe-sign-in-challenge-error-value="<%= t('siwe.errors.challenge') %>"
               data-siwe-sign-in-verification-error-value="<%= t('siwe.errors.verification') %>">
            <button type="button" class="btn btn-error btn-rapid" data-action="siwe-sign-in#authenticate"><%= t("siwe.identities.delete_with_wallet") %></button>
            <div class="alert alert-error mt-4 hidden" role="alert" data-siwe-sign-in-target="error"></div>
          </div>
        <% end %>
      </div>
    </section>
  ERB

  create_locale_pair(
    "siwe",
    ja: {
      "siwe" => {
        "sign_in" => { "title" => "Ethereumでログイン", "description" => "登録済みのEOAウォレットで署名してログインします。", "connect" => "ウォレットでログイン" },
        "account_settings" => { "basic" => "基本設定" },
        "identities" => { "title" => "EVMウォレットログイン", "description" => "ログインに使用できるEOAウォレットを管理します。", "empty" => "登録済みのウォレットはありません。", "add" => "ウォレットを追加", "new_title" => "EVMウォレットを登録", "new_description" => "接続するEOAウォレットで署名します。ウォレット名は登録後に自動設定されます。", "edit_title" => "EVMウォレットログインを編集", "name" => "ウォレット名", "connect" => "ウォレットを接続", "delete_title" => "EVMウォレットログインを解除", "delete_description" => "削除対象とは別のログイン方法で再認証してください。", "delete" => "解除", "delete_with_passkey" => "Passkeyで解除", "delete_with_wallet" => "別のウォレットで解除", "last_credential" => "最後のログイン方法は解除できません。", "updated" => "ウォレット名を更新しました。", "deleted" => "ウォレットを解除しました。" },
        "errors" => { "wallet_missing" => "EOAウォレットが見つかりません。", "challenge" => "認証要求を作成できませんでした。", "verification" => "署名を検証できませんでした。" }
      }
    },
    en: {
      "siwe" => {
        "sign_in" => { "title" => "Sign in with Ethereum", "description" => "Sign in with an EOA wallet already linked to your account.", "connect" => "Sign in with wallet" },
        "account_settings" => { "basic" => "Basic settings" },
        "identities" => { "title" => "EVM wallet login", "description" => "Manage the EOA wallets that can sign in to your account.", "empty" => "No wallets are linked.", "add" => "Add wallet", "new_title" => "Add EVM wallet", "new_description" => "Sign with the EOA wallet you want to connect. Its name will be assigned automatically after registration.", "edit_title" => "Edit EVM wallet login", "name" => "Wallet name", "connect" => "Connect wallet", "delete_title" => "Unlink EVM wallet login", "delete_description" => "Reauthenticate with a different sign-in method before unlinking this wallet.", "delete" => "Unlink", "delete_with_passkey" => "Unlink with passkey", "delete_with_wallet" => "Unlink with another wallet", "last_credential" => "You cannot remove your last sign-in method.", "updated" => "Wallet name updated.", "deleted" => "Wallet unlinked." },
        "errors" => { "wallet_missing" => "No EOA wallet was found.", "challenge" => "Could not create an authentication request.", "verification" => "Could not verify the signature." }
      }
    }
  )

  route <<~'RUBY'
    namespace :account do
      resources :siwe_identities, only: %i[index show new create edit update] do
        post :challenge, on: :collection
      end
    end
  RUBY

  create_file "test/models/siwe_identity_test.rb", <<~'RUBY', force: true
    require "test_helper"

    class SiweIdentityTest < ActiveSupport::TestCase
      test "normalizes names and addresses and allows duplicate names" do
        first = users(:one).siwe_identities.create!(
          name: "  Main Wallet  ",
          address: "0xABCDEF0123456789ABCDEF0123456789ABCDEF01"
        )

        assert_equal "Main Wallet", first.name
        assert_equal "0xabcdef0123456789abcdef0123456789abcdef01", first.address
        duplicate_name = users(:one).siwe_identities.new(
          name: "Main Wallet",
          address: "0x1111111111111111111111111111111111111111"
        )
        assert_predicate duplicate_name, :valid?
      end

      test "enforces globally unique addresses after normalization" do
        users(:one).siwe_identities.create!(
          name: "Main",
          address: "0xABCDEF0123456789ABCDEF0123456789ABCDEF01"
        )
        duplicate = users(:two).siwe_identities.new(
          name: "Other",
          address: "0xabcdef0123456789abcdef0123456789abcdef01"
        )

        assert_not duplicate.valid?
        assert_predicate duplicate.errors[:address], :any?
      end

      test "requires a valid wallet name and address" do
        identity = users(:one).siwe_identities.new(name: " ", address: "not-an-address")

        assert_not identity.valid?
        assert identity.errors.added?(:name, :blank)
        assert identity.errors.added?(:address, :invalid, value: "not-an-address")
        identity.name = "a" * 51
        assert_not identity.valid?
        assert identity.errors.added?(:name, :too_long, count: 50)
      end

      test "does not allow an address to change" do
        identity = users(:one).siwe_identities.create!(
          name: "Main",
          address: "0xabcdef0123456789abcdef0123456789abcdef01"
        )

        assert_not identity.update(address: "0x1111111111111111111111111111111111111111")
      end
    end
  RUBY

  create_file "test/models/siwe_challenge_test.rb", <<~'RUBY', force: true
    require "test_helper"
    require "eth"

    class SiweChallengeTest < ActiveSupport::TestCase
      self.use_transactional_tests = false

      setup { SiweChallenge.delete_all }
      teardown { SiweChallenge.delete_all }

      test "verifies and consumes a challenge exactly once" do
        key = Eth::Key.new
        challenge, = SiweChallenge.issue!(
          purpose: "login",
          address: key.address.to_s,
          chain_id: 1,
          session_binding: "browser"
        )

        message = challenge.verify!(
          signature: key.personal_sign(challenge.message),
          purpose: "login",
          session_binding: "browser"
        )
        assert_equal key.address.to_s.downcase, message.address.downcase
        challenge.consume!
        assert_raises(SiweChallenge::VerificationError) { challenge.consume! }
      end

      test "stores only a token digest and keeps parallel tab challenges independent" do
        key = Eth::Key.new
        first, first_token = issue(key, session_binding: "browser")
        second, second_token = issue(key, session_binding: "browser")

        assert_not_equal first_token, second_token
        assert_not_equal first_token, first.token_digest
        assert_equal first, SiweChallenge.for_token!(first_token)
        assert_equal second, SiweChallenge.for_token!(second_token)
        [first, second].each do |challenge|
          challenge.verify!(signature: key.personal_sign(challenge.message), purpose: "login", session_binding: "browser")
          challenge.consume!
        end
      end

      test "allows only one concurrent consumer" do
        challenge, = issue(Eth::Key.new, session_binding: "browser")
        ready = Queue.new
        start = Queue.new
        results = Queue.new
        threads = 2.times.map do
          Thread.new do
            ActiveRecord::Base.connection_pool.with_connection do
              contender = SiweChallenge.find(challenge.id)
              ready << true
              start.pop
              contender.consume!
              results << :consumed
            rescue SiweChallenge::VerificationError
              results << :rejected
            end
          end
        end
        2.times { ready.pop }
        2.times { start << true }
        threads.each(&:join)

        assert_equal %i[consumed rejected], 2.times.map { results.pop }.sort
      end

      test "rejects expired, wrong purpose, user, browser, and signature" do
        key = Eth::Key.new
        challenge, = issue(key, session_binding: "browser")
        signature = key.personal_sign(challenge.message)

        assert_verification_error { challenge.verify!(signature:, purpose: "link", session_binding: "browser") }
        assert_verification_error do
          challenge.verify!(signature:, purpose: "login", user: users(:one), session_binding: "browser")
        end
        assert_verification_error { challenge.verify!(signature:, purpose: "login", session_binding: "other") }
        assert_verification_error do
          challenge.verify!(signature: Eth::Key.new.personal_sign(challenge.message), purpose: "login", session_binding: "browser")
        end
        travel_to(challenge.expires_at) do
          assert_verification_error { challenge.verify!(signature:, purpose: "login", session_binding: "browser") }
        end
      end

      test "rejects changes to every server-authored message field" do
        mutations = {
          scheme: "https",
          domain: "evil.example",
          statement: "Different statement",
          uri: "https://evil.example/users/sign_in/siwe",
          chain_id: 11_155_111,
          issued_at: 1.minute.ago.utc.iso8601,
          expiration_time: 1.day.from_now.utc.iso8601,
          not_before: 1.minute.ago.utc.iso8601,
          request_id: "attacker-controlled",
          resources: ["https://evil.example/resource"]
        }

        mutations.each do |field, value|
          key = Eth::Key.new
          challenge, = issue(key, session_binding: "browser")
          parsed = Siwe::Message.parse(challenge.message)
          altered = Siwe::Message.new(**parsed.to_h.merge(field => value)).prepare_message
          challenge.update!(message: altered)

          assert_verification_error(field) do
            challenge.verify!(
              signature: key.personal_sign(altered),
              purpose: "login",
              session_binding: "browser"
            )
          end
        end

        challenge, = issue(Eth::Key.new, session_binding: "browser")
        other_key = Eth::Key.new
        parsed = Siwe::Message.parse(challenge.message)
        altered = Siwe::Message.new(**parsed.to_h.merge(address: other_key.address.to_s)).prepare_message
        challenge.update!(message: altered)
        assert_verification_error(:address) do
          challenge.verify!(signature: other_key.personal_sign(altered), purpose: "login", session_binding: "browser")
        end
      end

      test "accepts arbitrary positive EIP-155 chain ids and rejects invalid values" do
        key = Eth::Key.new
        challenge, = issue(key, chain_id: 11_155_111, session_binding: "browser")

        assert_equal 11_155_111, challenge.chain_id
        assert_verification_error { issue(key, chain_id: 0, session_binding: "browser") }
        assert_verification_error { issue(key, chain_id: "invalid", session_binding: "browser") }
      end

      test "removes expired and consumed challenges when issuing a new challenge" do
        key = Eth::Key.new
        expired, = issue(key, session_binding: "expired")
        consumed, = issue(key, session_binding: "consumed")
        expired.update!(expires_at: 1.minute.ago)
        consumed.consume!

        issue(key, session_binding: "current")

        assert_not SiweChallenge.exists?(expired.id)
        assert_not SiweChallenge.exists?(consumed.id)
      end

      private
        def issue(key, chain_id: 1, session_binding:)
          SiweChallenge.issue!(
            purpose: "login",
            address: key.address.to_s,
            chain_id:,
            session_binding:
          )
        end

        def assert_verification_error(label = nil, &block)
          return assert_raises(SiweChallenge::VerificationError, label.to_s, &block) if label

          assert_raises(SiweChallenge::VerificationError, &block)
        end
    end
  RUBY

  create_file "test/controllers/account/siwe_identities_controller_test.rb", <<~'RUBY', force: true
    require "test_helper"
    require "eth"

    class Account::SiweIdentitiesControllerTest < ActionDispatch::IntegrationTest
      include Devise::Test::IntegrationHelpers

      test "links wallets without a password or name and assigns count-based names" do
        sign_in users(:one)
        keys = [Eth::Key.new, Eth::Key.new, Eth::Key.new]

        keys.first(2).each do |key|
          post challenge_account_siwe_identities_url,
            params: { address: key.address.to_s, chain_id: 1 }, as: :json
          assert_response :success
          challenge = response.parsed_body

          post account_siwe_identities_url,
            params: { challenge_token: challenge.fetch("challenge_token"), signature: key.personal_sign(challenge.fetch("message")) }, as: :json
          assert_response :created
        end
        assert_equal ["Wallet #1", "Wallet #2"], users(:one).siwe_identities.order(:created_at).pluck(:name)

        key = keys.last
        post challenge_account_siwe_identities_url, params: { address: key.address.to_s, chain_id: 1 }, as: :json
        challenge = response.parsed_body
        post account_siwe_identities_url,
          params: { challenge_token: challenge.fetch("challenge_token"), signature: key.personal_sign(challenge.fetch("message")) }, as: :json
        assert_response :created
        assert_equal ["Wallet #1", "Wallet #2", "Wallet #3"], users(:one).siwe_identities.order(:created_at).pluck(:name)
      end

      test "renders target-excluding reauthentication instead of a password field" do
        sign_in users(:one)
        key = Eth::Key.new
        identity = users(:one).siwe_identities.create!(name: "Main", address: key.address.to_s)

        get account_siwe_identity_url(identity)

        assert_response :success
        assert_select 'input[type="password"]', count: 0
        assert_select '[data-passkey-destruction-action-value="delete_siwe"]', count: 1
      end

      test "renders separate index, new, edit, and unlink pages" do
        sign_in users(:one)

        get account_passkeys_url
        assert_response :success
        assert_select '.tab-active[aria-current="page"][href=?]', account_passkeys_path, count: 1
        assert_select '.tab[href=?]', account_siwe_identities_path, count: 1
        assert_select '.tabs.tabs-lift > .tab-active + .tab-content[role="tabpanel"]', count: 1

        get account_siwe_identities_url
        assert_response :success
        assert_select "a[href=?]", new_account_siwe_identity_path, count: 1
        assert_select "ul.list.gap-3 > li.list-row", count: 0
        assert_select "form", count: 0
        assert_select '.tab-active[aria-current="page"][href=?]', account_siwe_identities_path, count: 1
        assert_select '.tabs.tabs-lift > .tab-active + .tab-content[role="tabpanel"]', count: 1
        assert_select '.tabs.tabs-lift > .tab-content', count: 1
        assert_select '.tab-content > .card-border.border-base-300', count: 0
        assert_select 'nav[aria-label=?] a.menu-active[href=?]', I18n.t("navigation.account_menu"),
          account_passkeys_path, count: 1

        get new_account_siwe_identity_url
        assert_response :success
        assert_select '[data-controller="siwe-sign-in"][data-siwe-sign-in-mode-value="link"]', count: 1
        assert_select 'input[name="current_password"], input[name="name"]', count: 0
        assert_select '.tab-active[href=?]', account_siwe_identities_path, count: 1

        identity = users(:one).siwe_identities.create!(
          name: "Main",
          address: "0xabcdef0123456789abcdef0123456789abcdef01"
        )
        get account_siwe_identities_url
        assert_select "ul.list.gap-3 > li.list-row", count: 1
        assert_select "a[href=?]", account_siwe_identity_path(identity), text: I18n.t("siwe.identities.delete"), count: 1

        get edit_account_siwe_identity_url(identity)
        assert_response :success
        assert_select 'form input[name="siwe_identity[name]"]', count: 1
        assert_select 'form input[name="current_password"]', count: 0
        assert_select '.tab-active[href=?]', account_siwe_identities_path, count: 1

        get account_siwe_identity_url(identity)
        assert_response :success
        assert_select 'form input[type="password"]', count: 0
        assert_select '[data-passkey-destruction-action-value="delete_siwe"]', count: 1
        assert_select 'form input[name="siwe_identity[name]"]', count: 0
        assert_select '.tab-active[href=?]', account_siwe_identities_path, count: 1
      end

      test "renames only an identity owned by the current user" do
        sign_in users(:one)
        identity = users(:one).siwe_identities.create!(
          name: "Main",
          address: "0xabcdef0123456789abcdef0123456789abcdef01"
        )
        other = users(:two).siwe_identities.create!(
          name: "Other",
          address: "0x1111111111111111111111111111111111111111"
        )

        patch account_siwe_identity_url(identity), params: {
          siwe_identity: { name: "Renamed", address: "0x2222222222222222222222222222222222222222" }
        }
        assert_redirected_to account_siwe_identities_url
        assert_equal "Renamed", identity.reload.name
        assert_equal "0xabcdef0123456789abcdef0123456789abcdef01", identity.address
        patch account_siwe_identity_url(other), params: { siwe_identity: { name: "Stolen" } }
        assert_response :not_found
        assert_equal "Other", other.reload.name
        get account_siwe_identity_url(other)
        assert_response :not_found
      end

      test "rejects an address already linked to another user" do
        sign_in users(:one)
        key = Eth::Key.new
        users(:two).siwe_identities.create!(name: "Other", address: key.address.to_s)

        post challenge_account_siwe_identities_url,
          params: { address: key.address.to_s, chain_id: 1 }, as: :json
        challenge = response.parsed_body
        post account_siwe_identities_url,
          params: {
            challenge_token: challenge.fetch("challenge_token"),
            signature: key.personal_sign(challenge.fetch("message"))
          }, as: :json

        assert_response :unprocessable_content
        assert_equal users(:two), SiweIdentity.find_by!(address: key.address.to_s.downcase).user
      end

      test "unlinks a wallet only with another wallet and rejects replay and self authentication" do
        user = users(:one)
        target_key = Eth::Key.new
        authenticator_key = Eth::Key.new
        target = user.siwe_identities.create!(name: "Target", address: target_key.address.to_s)
        authenticator = user.siwe_identities.create!(name: "Authenticator", address: authenticator_key.address.to_s)
        sign_in user

        post account_siwe_credential_destruction_challenge_url,
          params: {
            address: target_key.address.to_s,
            chain_id: 1,
            destruction_action: "delete_siwe",
            target_id: target.id
          }, as: :json
        assert_response :unprocessable_content

        post account_siwe_credential_destruction_challenge_url,
          params: {
            address: authenticator_key.address.to_s,
            chain_id: 1,
            destruction_action: "delete_siwe",
            target_id: target.id
          }, as: :json
        challenge = response.parsed_body
        payload = {
          challenge_token: challenge.fetch("challenge_token"),
          signature: authenticator_key.personal_sign(challenge.fetch("message")),
          destruction_action: "delete_siwe",
          target_id: target.id
        }
        post account_siwe_credential_destruction_url, params: payload, as: :json
        assert_response :success
        assert_not SiweIdentity.exists?(target.id)
        assert SiweIdentity.exists?(authenticator.id)

        post account_siwe_credential_destruction_url, params: payload, as: :json
        assert_response :unprocessable_content
        assert SiweIdentity.exists?(authenticator.id)
      end

      test "rejects unlinking the last wallet and deletes an account with fresh wallet authentication" do
        user = User.create!
        key = Eth::Key.new
        identity = user.siwe_identities.create!(name: "Only wallet", address: key.address.to_s)
        sign_in user

        post account_siwe_credential_destruction_challenge_url,
          params: {
            address: key.address.to_s,
            chain_id: 1,
            destruction_action: "delete_siwe",
            target_id: identity.id
          }, as: :json
        assert_response :unprocessable_content

        post account_siwe_credential_destruction_challenge_url,
          params: {
            address: key.address.to_s,
            chain_id: 1,
            destruction_action: "delete_account",
            target_id: user.id
          }, as: :json
        challenge = response.parsed_body
        assert_difference "User.count", -1 do
          post account_siwe_credential_destruction_url,
            params: {
              challenge_token: challenge.fetch("challenge_token"),
              signature: key.personal_sign(challenge.fetch("message")),
              destruction_action: "delete_account",
              target_id: user.id
            }, as: :json
        end
        assert_response :success
        assert_not User.exists?(user.id)
      end
    end
  RUBY

  create_file "test/controllers/users/siwe_sessions_controller_test.rb", <<~'RUBY', force: true
    require "test_helper"
    require "eth"

    class Users::SiweSessionsControllerTest < ActionDispatch::IntegrationTest
      test "creates an account only through the SIWE signup ceremony" do
        key = Eth::Key.new
        post user_siwe_registration_challenge_url,
          params: { address: key.address.to_s, chain_id: 1 }, as: :json
        challenge = response.parsed_body

        assert_difference ["User.count", "SiweIdentity.count"], 1 do
          post user_siwe_registration_url,
            params: {
              challenge_token: challenge.fetch("challenge_token"),
              signature: key.personal_sign(challenge.fetch("message"))
            }, as: :json
        end
        assert_response :created
        assert_equal key.address.to_s.downcase, T.must(User.order(:id).last).siwe_identities.sole.address
      end

      test "signs in the existing user without creating another user" do
        key = Eth::Key.new
        users(:one).siwe_identities.create!(name: "Main", address: key.address.to_s)

        post user_siwe_challenge_url, params: { address: key.address.to_s, chain_id: 1 }, as: :json
        assert_response :success
        challenge = response.parsed_body

        assert_no_difference "User.count" do
          post user_siwe_url,
            params: { challenge_token: challenge.fetch("challenge_token"), signature: key.personal_sign(challenge.fetch("message")) }, as: :json
        end
        assert_response :success
        get account_url
        assert_response :success
      end

      test "does not create a user for an unlinked wallet" do
        key = Eth::Key.new
        post user_siwe_challenge_url, params: { address: key.address.to_s, chain_id: 1 }, as: :json
        challenge = response.parsed_body

        assert_no_difference "User.count" do
          post user_siwe_url,
            params: { challenge_token: challenge.fetch("challenge_token"), signature: key.personal_sign(challenge.fetch("message")) }, as: :json
        end
        assert_response :unauthorized
      end

      test "binds a challenge to its browser session and ignores the Host header" do
        key = Eth::Key.new
        users(:one).siwe_identities.create!(name: "Main", address: key.address.to_s)
        issuer = open_session
        attacker = open_session

        issuer.post user_siwe_challenge_url,
          params: { address: key.address.to_s, chain_id: 1 },
          headers: { "Host" => "evil.example" },
          as: :json
        assert_equal "no-store", issuer.response.headers["Cache-Control"]
        challenge = issuer.response.parsed_body
        assert_includes challenge.fetch("message"), Rails.configuration.x.application_identity.canonical_origin
        assert_not_includes challenge.fetch("message"), "evil.example"

        attacker.post user_siwe_url,
          params: {
            challenge_token: challenge.fetch("challenge_token"),
            signature: key.personal_sign(challenge.fetch("message"))
          }, as: :json
        assert_equal 401, attacker.response.status
      end

      test "rejects an inactive linked user" do
        key = Eth::Key.new
        users(:one).siwe_identities.create!(name: "Main", address: key.address.to_s)
        post user_siwe_challenge_url, params: { address: key.address.to_s, chain_id: 1 }, as: :json
        challenge = response.parsed_body
        original = User.instance_method(:active_for_authentication?)
        User.class_eval { define_method(:active_for_authentication?) { false } }

        assert_no_difference "User.count" do
          post user_siwe_url,
            params: {
              challenge_token: challenge.fetch("challenge_token"),
              signature: key.personal_sign(challenge.fetch("message"))
            }, as: :json
        end
        assert_response :unauthorized
      ensure
        User.class_eval { define_method(:active_for_authentication?, original) } if original
      end
    end
  RUBY
end
def configure_roles
  profile_name_attribute = if VALUES.fetch("profile_features").include?("screen_name")
    "screen_name"
  elsif VALUES.fetch("profile_features").include?("display_name")
    "display_name"
  end
  user_scope = profile_name_attribute ? "User.includes(:user_roles, :profile)" : "User.includes(:user_roles)"
  profile_header = profile_name_attribute ? '<th scope="col"><%= t("admin.users.profile_name") %></th>' : ""
  profile_cell = if profile_name_attribute
    "<td><%= user.profile&.#{profile_name_attribute}.presence || t(\"common.not_set\") %></td>"
  else
    ""
  end

  generate "action_policy:install"
  inject_into_class "app/policies/application_policy.rb", "ApplicationPolicy", <<~RUBY
      extend T::Sig

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
      extend T::Sig

      has_many :user_roles, dependent: :destroy

      sig { params(role: T.any(String, Symbol)).returns(T::Boolean) }
      def has_role?(role)
        normalized_role = UserRole.roles[role.to_s]
        return false if normalized_role.nil?

        if user_roles.loaded?
          user_roles.any? { |assignment| assignment.role == normalized_role }
        else
          user_roles.exists?(role: normalized_role)
        end
      end

      sig { params(role: T.any(String, Symbol)).returns(UserRole) }
      def grant_role!(role)
        normalized_role = UserRole.roles.fetch(role.to_s)
        user_roles.find_or_create_by!(role: normalized_role)
      end

      sig { params(role: T.any(String, Symbol)).returns(T.nilable(UserRole)) }
      def revoke_role!(role)
        normalized_role = UserRole.roles.fetch(role.to_s)
        assignment = user_roles.find_by(role: normalized_role)
        return if assignment.nil?

        assignment.destroy!
      end

      sig { returns(T::Boolean) }
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
        sig { returns(T.nilable(User)) }
        def authorization_user
          current_user
        end

        sig { params(_error: ActionPolicy::Unauthorized).void }
        def render_forbidden(_error)
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
      T::Sig::WithoutRuntime.sig { returns(T::Boolean) }
      def index?
        admin?
      end

      T::Sig::WithoutRuntime.sig { returns(T::Boolean) }
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
        before_action :authenticate_user!
      end
    end
  RUBY

  create_file "app/controllers/admin/users_controller.rb", <<~RUBY, force: true
    module Admin
      class UsersController < BaseController
        extend T::Sig

        sig { void }
        def index
          authorize! User, to: :index?
          users = authorized_scope(#{user_scope}).order(:id)
          @pagy, @users = pagy(:offset, users, limit: 25)
        end
      end
    end
  RUBY

  create_file "app/controllers/admin/user_roles_controller.rb", <<~RUBY, force: true
    module Admin
      class UserRolesController < BaseController
        extend T::Sig

        before_action :set_user

        sig { void }
        def create
          authorize! @user, to: :manage_roles?
          @user.grant_role!(role_param)
          redirect_to admin_users_path, notice: I18n.t("admin.user_roles.create.notice"), status: :see_other
        rescue KeyError, ActiveRecord::RecordInvalid
          head :unprocessable_content
        end

        sig { void }
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
    <% content_for :page_title, t("admin.users.title") %>
    <div class="space-y-6">
      <header>
        <p class="text-sm text-neutral"><%= t("admin.users.description") %></p>
      </header>

      <section class="card card-border border-base-300 bg-base-100 shadow-none">
        <div class="card-body">
          <div class="overflow-x-auto">
            <table class="table table-sm table-pin-rows">
              <thead>
                <tr>
                  <th scope="col">ID</th>
                  #{profile_header}
                  <th scope="col"><%= t("admin.users.role") %></th>
                  <th scope="col"><span class="sr-only"><%= t("common.actions") %></span></th>
                </tr>
              </thead>
              <tbody>
                <% @users.each do |user| %>
                  <tr>
                    <td><%= user.id %></td>
                    #{profile_cell}
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

  create_file "app/services/admin_role_grant.rb", <<~RUBY, force: true
    class AdminRoleGrant
      extend T::Sig

      sig { params(user_id: T.nilable(T.any(String, Integer)), output: IO).returns(User) }
      def self.call(user_id, output: $stdout)
        identifier = case user_id
                     when Integer
                       user_id
                     when String
                       Integer(user_id, 10) if user_id.match?(/\A[1-9]\d*\z/)
                     end
        raise ArgumentError, "user_idを指定してください" unless identifier&.positive?

        user = User.find(identifier)
        user.grant_role!(:admin)
        output.puts "admin role granted to user_id=\#{user.id}"
        user
      end
    end
  RUBY

  create_file "lib/tasks/roles.rake", <<~RAKE, force: true
    namespace :roles do
      desc "Grant the admin role to an existing User identified by users.id"
      task :grant_admin, [:user_id] => :environment do |_task, arguments|
        AdminRoleGrant.call(arguments[:user_id])
      end
    end
  RAKE

  append_to_file "db/seeds.rb", <<~RUBY

    local_seeds = Rails.root.join("db/seeds.local.rb")
    load local_seeds.to_s if local_seeds.file?
  RUBY
  create_file "db/seeds.local.rb.example", <<~RUBY, force: true
    AdminRoleGrant.call(ENV.fetch("ADMIN_USER_ID"))
  RUBY
  append_to_file ".gitignore", "\n/db/seeds.local.rb\n" unless File.read(".gitignore").lines.map(&:strip).include?("/db/seeds.local.rb")

  create_locale_pair("roles",
    ja: {
      "roles" => { "errors" => { "last_admin" => "最後の管理者roleは解除できません" } },
      "admin" => {
        "users" => { "title" => "ユーザー管理", "description" => "内部ユーザーIDを基準に固定roleを付与または解除します。", "profile_name" => "表示名", "role" => "Role", "admin" => "管理者", "self_forbidden" => "自分自身は解除不可", "revoke" => "管理者を解除", "revoke_confirm" => "管理者roleを解除しますか？", "grant" => "管理者にする", "pagination" => "ユーザー一覧のページング" },
        "user_roles" => { "create" => { "notice" => "管理者roleを付与しました" }, "destroy" => { "notice" => "管理者roleを解除しました", "self_forbidden" => "自分自身の管理者roleは解除できません" } }
      },
      "accounts" => { "destroy" => { "last_admin" => "最後の管理者はアカウントを削除できません" } }
    },
    en: {
      "roles" => { "errors" => { "last_admin" => "The final administrator role cannot be revoked" } },
      "admin" => {
        "users" => { "title" => "User management", "description" => "Grant or revoke fixed roles by internal user ID.", "profile_name" => "Display name", "role" => "Role", "admin" => "Administrator", "self_forbidden" => "You cannot revoke your own role", "revoke" => "Revoke administrator", "revoke_confirm" => "Revoke the administrator role?", "grant" => "Make administrator", "pagination" => "User list pagination" },
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

  controller_test_support = <<~RUBY
      include Devise::Test::IntegrationHelpers

      setup do
        @admin = User.create!
        @regular = User.create!
        @admin.grant_role!(:admin)
      end

      private
        def sign_in_as(user, _key = nil)
          sign_in user
        end

        def create_additional_users(count)
          count.times do
            User.create!
          end
        end
  RUBY

  account_deletion_test = <<~RUBY
    test "refuses deletion of the last admin account" do
      sign_in_as(@admin)

      get delete_account_url

      assert_redirected_to account_url
      assert User.exists?(@admin.id)
      assert @admin.reload.has_role?(:admin)
    end
  RUBY

  create_file "test/controllers/admin/users_controller_test.rb", <<~RUBY, force: true
    require "test_helper"

    class Admin::UsersControllerTest < ActionDispatch::IntegrationTest
    #{controller_test_support}
      test "requires authentication" do
        get admin_users_url

        assert_redirected_to new_user_session_url
      end

      test "denies regular users" do
        sign_in_as(@regular)
        get admin_users_url

        assert_response :forbidden
      end

      test "authorizes scopes and renders the admin list" do
        sign_in_as(@admin)

        assert_have_authorized_scope(type: :active_record_relation, with: UserPolicy) do
          get admin_users_url
        end
        assert_response :success
        assert_select '[data-layout="with-menu"] nav[aria-label=?]', I18n.t("navigation.admin_menu"), count: 1
        assert_select '[data-layout="with-menu"] nav[aria-label=?] li.menu-title', I18n.t("navigation.admin_menu"), text: I18n.t("navigation.admin"), count: 1
        assert_select '[data-layout="with-menu"] nav[aria-label=?]', I18n.t("navigation.account_menu"), count: 0
        assert_select '[data-layout="with-menu"] a.menu-active[href=?]', admin_users_path, text: I18n.t("navigation.users"), count: 1
        assert_select 'header li.menu-title', text: I18n.t("navigation.admin"), count: 1
        assert_select 'header a[href=?]', account_path, count: 0
        assert_select "table.table.table-sm.table-pin-rows"
        assert_select ".badge", text: I18n.t("admin.users.admin"), minimum: 1
        assert_select ".join", count: 0
      end


      test "paginates the admin list" do
        create_additional_users(25)
        sign_in_as(@admin)

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
        sign_in_as(@admin)

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
        sign_in_as(@regular)

        assert_no_difference("UserRole.count") do
          post admin_user_roles_url(@regular), params: { role: "admin" }
        end
        assert_response :forbidden
      end

      test "refuses self revocation" do
        sign_in_as(@admin)

        assert_no_difference("UserRole.count") do
          delete admin_user_role_url(@admin, "admin")
        end
        assert_redirected_to admin_users_url
        assert @admin.reload.has_role?(:admin)
      end

      test "rejects unknown roles" do
        sign_in_as(@admin)

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

        assert_difference("UserRole.count", 1) { invoke(user.id) }
        assert_no_difference("UserRole.count") { invoke(user.id) }
        assert user.reload.has_role?(:admin)
      end

      test "does not create an unknown user" do
        assert_no_difference("User.count") do
          assert_raises(ActiveRecord::RecordNotFound) { invoke(999_999) }
        end
      end

      test "loads local seeds only when the ignored file exists" do
        local_seeds = Rails.root.join("db/seeds.local.rb")
        FileUtils.rm_f(local_seeds)

        load Rails.root.join("db/seeds.rb").to_s
        assert_nil ENV["ROLE_LOCAL_SEED_LOADED"]

        File.write(local_seeds, 'ENV["ROLE_LOCAL_SEED_LOADED"] = "yes"\n')
        load Rails.root.join("db/seeds.rb").to_s
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

end

def configure_content_management
  page_title_keys = {
    "about" => "content_management.pages.about",
    "corp" => "content_management.pages.corp",
    "manual" => "content_management.pages.manual",
    "terms" => "content_management.pages.terms",
    "privacy" => "content_management.pages.privacy",
    "transaction-law" => "content_management.pages.transaction_law"
  }.freeze
  page_title_entries = page_title_keys.map { |slug, key| "    #{slug.inspect} => #{key.inspect}" }.join(",\n")
  public_page_access = ""
  public_faq_access = ""

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
      extend T::Sig

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

      sig { returns(String) }
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
      extend T::Sig

      DEFAULT_KEY = "default"
      URL_ATTRIBUTES = %i[x_url github_url].freeze

      normalizes :x_url, :github_url, with: ->(value) { value&.strip.presence }

      validates :key, inclusion: { in: [DEFAULT_KEY] }, uniqueness: true
      validate :external_urls_are_https

      sig { returns(FooterSetting) }
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
      T::Sig::WithoutRuntime.sig { returns(T::Boolean) }
      def index?
        admin?
      end

      T::Sig::WithoutRuntime.sig { returns(T::Boolean) }
      def update?
        admin?
      end
    end
  RUBY

  create_file "app/policies/faq_policy.rb", <<~RUBY, force: true
    class FaqPolicy < ApplicationPolicy
      T::Sig::WithoutRuntime.sig { returns(T::Boolean) }
      def index?
        admin?
      end

      T::Sig::WithoutRuntime.sig { returns(T::Boolean) }
      def create?
        admin?
      end

      T::Sig::WithoutRuntime.sig { returns(T::Boolean) }
      def update?
        admin?
      end

      T::Sig::WithoutRuntime.sig { returns(T::Boolean) }
      def destroy?
        admin?
      end
    end
  RUBY

  create_file "app/policies/footer_setting_policy.rb", <<~RUBY, force: true
    class FooterSettingPolicy < ApplicationPolicy
      T::Sig::WithoutRuntime.sig { returns(T::Boolean) }
      def edit?
        admin?
      end

      T::Sig::WithoutRuntime.sig { returns(T::Boolean) }
      def update?
        admin?
      end
    end
  RUBY

  inject_into_class "app/controllers/application_controller.rb", "ApplicationController", <<~RUBY
      helper_method :footer_setting

      private
        sig { returns(FooterSetting) }
        def footer_setting
          @footer_setting ||= FooterSetting.default_record
        end

  RUBY

  create_file "app/controllers/pages_controller.rb", <<~RUBY, force: true
    class PagesController < ApplicationController
      extend T::Sig

      TEMPLATES = {
        "about" => "pages/about",
        "corp" => "pages/corp",
        "manual" => "pages/manual",
        "terms" => "pages/terms",
        "privacy" => "pages/privacy",
        "transaction-law" => "pages/transaction-law"
      }.freeze

    #{public_page_access}  sig { void }
      def show
        @page = Page.find_by!(slug: params.expect(:slug))
        render template: TEMPLATES.fetch(@page.slug)
      end
    end
  RUBY

  create_file "app/controllers/faqs_controller.rb", <<~RUBY, force: true
    class FaqsController < ApplicationController
      extend T::Sig

    #{public_faq_access}  sig { void }
      def index
        @faqs = Faq.published_in_display_order
      end
    end
  RUBY

  create_file "app/controllers/admin/pages_controller.rb", <<~RUBY, force: true
    module Admin
      class PagesController < BaseController
        extend T::Sig

        before_action :set_page, only: %i[edit update]

        sig { void }
        def index
          authorize! Page, to: :index?
          @pages = Page.order(:id)
        end

        sig { void }
        def edit
          authorize! @page, to: :update?
        end

        sig { void }
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
        extend T::Sig

        before_action :set_faq, only: %i[edit update destroy]

        sig { void }
        def index
          authorize! Faq, to: :index?
          @faqs = Faq.order(:position, :id).with_rich_text_answer
        end

        sig { void }
        def new
          @faq = Faq.new
          authorize! @faq, to: :create?
        end

        sig { void }
        def edit
          authorize! @faq, to: :update?
        end

        sig { void }
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

        sig { void }
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

        sig { void }
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
        extend T::Sig

        before_action :set_footer_setting

        sig { void }
        def edit
          authorize! @footer_setting, to: :edit?
        end

        sig { void }
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
        "faqs" => { "title" => "よくある質問", "empty" => "現在、公開中のよくある質問はありません。" },
        "admin" => {
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
        "faqs" => { "title" => "Frequently asked questions", "empty" => "There are no published frequently asked questions." },
        "admin" => {
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
    <% content_for :page_title, @page.title %>
    <div class="mx-auto w-full max-w-[820px] space-y-6 px-5 py-10 md:py-14">
      <header>
        <h1 class="text-2xl font-bold leading-[1.5]"><%= content_for(:page_title) %></h1>
      </header>
      <section class="card card-border border-base-300 bg-base-100 shadow-none">
        <div class="card-body"><%= @page.content %></div>
      </section>
    </div>
  ERB
  create_file "app/views/pages/about.html.erb", "<%= render \"pages/page\" %>\n", force: true
  create_file "app/views/pages/corp.html.erb", "<%= render \"pages/page\" %>\n", force: true
  create_file "app/views/pages/manual.html.erb", "<%= render \"pages/page\" %>\n", force: true
  create_file "app/views/pages/terms.html.erb", "<%= render \"pages/page\" %>\n", force: true
  create_file "app/views/pages/privacy.html.erb", "<%= render \"pages/page\" %>\n", force: true
  create_file "app/views/pages/transaction-law.html.erb", "<%= render \"pages/page\" %>\n", force: true

  create_file "app/views/faqs/index.html.erb", <<~ERB, force: true
    <% content_for :page_title, t("content_management.faqs.title") %>
    <div class="mx-auto w-full max-w-[820px] space-y-6 px-5 py-10 md:py-14">
      <header>
        <h1 class="text-2xl font-bold leading-[1.5]"><%= content_for(:page_title) %></h1>
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
    <% content_for :page_title, t("content_management.admin.pages.title") %>
    <div class="space-y-6">
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
    <% content_for :page_title, @page.title %>
    <div class="max-w-[820px] space-y-6">
      <header>
        <p class="text-sm text-neutral"><%= t("content_management.admin.pages.edit_description") %></p>
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
    <% content_for :page_title, t("content_management.admin.faqs.title") %>
    <div class="space-y-6">
      <header class="flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
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
    <% content_for :page_title, t("content_management.admin.faqs.add") %>
    <div class="max-w-[820px] space-y-6">
      <section class="card card-border border-base-300 bg-base-100 shadow-none"><div class="card-body"><%= render "form", faq: @faq %></div></section>
    </div>
  ERB

  create_file "app/views/admin/faqs/edit.html.erb", <<~ERB, force: true
    <% content_for :page_title, t("content_management.admin.faqs.edit") %>
    <div class="max-w-[820px] space-y-6">
      <section class="card card-border border-base-300 bg-base-100 shadow-none"><div class="card-body"><%= render "form", faq: @faq %></div></section>
    </div>
  ERB

  create_file "app/views/admin/footer_settings/edit.html.erb", <<~ERB, force: true
    <% content_for :page_title, t("content_management.admin.footer_settings.title") %>
    <div class="max-w-[820px] space-y-6">
      <header>
        <p class="text-sm text-neutral"><%= t("content_management.admin.footer_settings.description") %></p>
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

  content_authentication_support = <<~RUBY
    module ContentManagementAuthenticationTestSupport
      extend ActiveSupport::Concern

      included do
        include Devise::Test::IntegrationHelpers
      end

      private
        def setup_content_management_users
          @admin = User.create!
          @regular = User.create!
          @admin.grant_role!(:admin)
        end

        def sign_in_content_user(user, _key = nil)
          sign_in user
        end
    end
  RUBY
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
        load Rails.root.join("db/seeds.rb").to_s

        assert_equal Page::TITLES, Page.order(:id).to_h { |page| [page.slug, page.title] }
        assert_equal FooterSetting::DEFAULT_KEY, FooterSetting.default_record.key
        assert_no_difference(["Page.count", "FooterSetting.count"]) { load Rails.root.join("db/seeds.rb").to_s }
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
          document_title = "\#{title} | \#{Rails.configuration.x.application_identity.app_name}"
          assert_select "title", text: document_title, count: 1
          assert_select 'meta[property="og:title"][content=?]', document_title, count: 1
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
        assert_includes source, "/rails/active_storage/representations/proxy/"
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
        assert_redirected_to new_user_session_url

        sign_in_content_user(@regular)
        get admin_pages_url
        assert_response :forbidden
      end

      test "allows an admin to edit only page content with Lexxy" do
        sign_in_content_user(@admin)
        page = pages(:about)

        get edit_admin_page_url(page)
        assert_response :success
        assert_select '[data-layout="with-menu"] nav[aria-label=?]', I18n.t("navigation.admin_menu"), count: 1
        assert_select '[data-layout="with-menu"] a.menu-active[href=?]', admin_pages_path, text: I18n.t("navigation.pages"), count: 1
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
        sign_in_content_user(@admin)

        get new_admin_faq_url
        assert_response :success
        assert_select '[data-layout="with-menu"] nav[aria-label=?]', I18n.t("navigation.admin_menu"), count: 1
        assert_select '[data-layout="with-menu"] a.menu-active[href=?]', admin_faqs_path, text: I18n.t("navigation.faqs"), count: 1
        assert_select "lexxy-editor", count: 1

        assert_difference("Faq.count", 1) do
          post admin_faqs_url, params: {
            faq: { question: "質問", answer: "回答", position: 5, published: "1" }
          }
        end
        faq = T.must(Faq.order(:id).last)
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
        sign_in_content_user(@regular)

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
        sign_in_content_user(@admin)

        get edit_admin_footer_setting_url
        assert_response :success
        assert_select '[data-layout="with-menu"] nav[aria-label=?]', I18n.t("navigation.admin_menu"), count: 1
        assert_select '[data-layout="with-menu"] a.menu-active[href=?]', edit_admin_footer_setting_path, text: I18n.t("content_management.admin.footer_settings.title"), count: 1

        patch admin_footer_setting_url, params: {
          footer_setting: { x_url: " https://social.example/x ", github_url: "" }
        }

        assert_redirected_to edit_admin_footer_setting_url
        assert_equal "https://social.example/x", footer_settings(:default).reload.x_url
        assert_nil footer_settings(:default).github_url
      end

      test "renders validation errors for unsafe links" do
        sign_in_content_user(@admin)

        patch admin_footer_setting_url, params: {
          footer_setting: { x_url: "http://social.example/x", github_url: "https://code.example/repository" }
        }

        assert_response :unprocessable_content
        assert_select ".alert.alert-error", count: 1
        assert_nil footer_settings(:default).reload.github_url
      end

      test "denies regular users" do
        sign_in_content_user(@regular)

        get edit_admin_footer_setting_url

        assert_response :forbidden
      end
    end
  RUBY
end

def install_image_cropper
  run_checked "bin/importmap pin cropperjs@2.1.1"

  expected_packages = %w[
    cropperjs
    @cropper/element
    @cropper/element-canvas
    @cropper/element-crosshair
    @cropper/element-grid
    @cropper/element-handle
    @cropper/element-image
    @cropper/element-selection
    @cropper/element-shade
    @cropper/element-viewer
    @cropper/elements
    @cropper/utils
  ]
  importmap = File.binread("config/importmap.rb")
  expected_packages.each do |package|
    raise "Cropper.js dependencyがImportmapへ登録されていません: #{package}" unless importmap.match?(/^pin "#{Regexp.escape(package)}"/)

    path = "vendor/javascript/#{package.sub('/', '--')}.js"
    raise "Cropper.js dependencyが保存されていません: #{path}" unless File.file?(path)
  end

  create_file "app/javascript/controllers/image_crop_controller.js", <<~'JAVASCRIPT', force: true
    import { Controller } from "@hotwired/stimulus"
    import Cropper from "cropperjs"

    export default class extends Controller {
      static targets = [
        "input",
        "dialog",
        "cropper",
        "currentPreview",
        "pendingPreviewContainer",
        "pendingPreview",
        "error",
        "apply"
      ]

      static values = {
        aspectRatio: Number,
        initialCoverage: Number,
        outputWidth: Number,
        outputHeight: Number,
        allowedTypes: Array,
        maxBytes: Number,
        maxDimension: Number,
        lossyQuality: Number,
        invalidTypeMessage: String,
        tooLargeMessage: String,
        tooWideOrTallMessage: String,
        undecodableMessage: String,
        cropFailedMessage: String
      }

      connect() {
        this.validateConfiguration()
        this.committedFile = this.inputTarget.files.item(0)
        this.cropper = null
        this.sourceFile = null
        this.sourceObjectUrl = null
        this.previewObjectUrl = null
        this.beforeCache = this.prepareForCache.bind(this)
        document.addEventListener("turbo:before-cache", this.beforeCache)
      }

      disconnect() {
        document.removeEventListener("turbo:before-cache", this.beforeCache)
        this.destroyCropper()
        this.revokeSourceObjectUrl()
        this.revokePreviewObjectUrl()
      }

      async select() {
        const selectedFile = this.inputTarget.files.item(0)
        if (!selectedFile) return

        this.writeInput(this.committedFile)
        this.clearError()

        try {
          this.validateConfiguration()
          const image = await this.loadSourceImage(selectedFile)
          this.sourceFile = selectedFile
          this.cropperTarget.replaceChildren(image)
          this.dialogTarget.showModal()
          this.cropper = new Cropper(image, {
            container: this.cropperTarget,
            template: `
              <cropper-canvas class="block h-full w-full" background>
                <cropper-image initial-center-size="cover" scalable translatable></cropper-image>
                <cropper-shade hidden></cropper-shade>
                <cropper-handle action="move" plain></cropper-handle>
                <cropper-selection ${this.selectionAspectRatioAttributes()} initial-coverage="${this.initialCoverageValue}" movable precise resizable>
                  <cropper-grid role="grid" bordered covered></cropper-grid>
                  <cropper-crosshair centered></cropper-crosshair>
                  <cropper-handle action="move" theme-color="rgba(255, 255, 255, 0.35)"></cropper-handle>
                  <cropper-handle action="n-resize"></cropper-handle>
                  <cropper-handle action="e-resize"></cropper-handle>
                  <cropper-handle action="s-resize"></cropper-handle>
                  <cropper-handle action="w-resize"></cropper-handle>
                  <cropper-handle action="ne-resize"></cropper-handle>
                  <cropper-handle action="nw-resize"></cropper-handle>
                  <cropper-handle action="se-resize"></cropper-handle>
                  <cropper-handle action="sw-resize"></cropper-handle>
                </cropper-selection>
              </cropper-canvas>
            `
          })

          const selection = this.cropper.getCropperSelection()
          const cropperImage = this.cropper.getCropperImage()
          if (!selection || !cropperImage) throw new Error("Cropper elements were not created")

          selection.aspectRatio = this.configuredAspectRatio()
          this.applyTarget.focus()
        } catch (error) {
          this.destroyCropper()
          this.revokeSourceObjectUrl()
          const message = error instanceof Error && error.message ? error.message : this.undecodableMessageValue
          this.showError(message)
        }
      }

      zoomIn() {
        this.cropperImage().$zoom(0.1)
      }

      zoomOut() {
        this.cropperImage().$zoom(-0.1)
      }

      reset() {
        const selection = this.cropperSelection()
        this.cropperImage().$resetTransform()
        selection.$reset()
        selection.aspectRatio = this.configuredAspectRatio()
      }

      cancel() {
        this.dialogTarget.close()
      }

      close() {
        this.destroyCropper()
        this.revokeSourceObjectUrl()
        this.sourceFile = null
      }

      async apply() {
        if (!this.sourceFile) return

        this.applyTarget.disabled = true
        this.clearError()
        try {
          this.validateConfiguration()
          const canvas = await this.cropperSelection().$toCanvas(this.canvasOptions())
          const blob = await this.canvasToBlob(canvas, this.sourceFile.type)
          if (!blob || blob.type !== this.sourceFile.type || blob.size === 0 || blob.size > this.maxBytesValue) {
            throw new Error("Cropped image does not satisfy the upload contract")
          }

          const croppedFile = new File([blob], this.sourceFile.name, {
            type: this.sourceFile.type,
            lastModified: this.sourceFile.lastModified
          })
          this.committedFile = croppedFile
          this.writeInput(croppedFile)
          this.updatePreview(croppedFile)
          this.dialogTarget.close()
        } catch (_error) {
          this.showError(this.cropFailedMessageValue)
        } finally {
          this.applyTarget.disabled = false
        }
      }

      prepareForCache() {
        this.committedFile = null
        this.writeInput(null)
        if (this.dialogTarget.open) this.dialogTarget.close()
        this.destroyCropper()
        this.revokeSourceObjectUrl()
        this.revokePreviewObjectUrl()
        this.pendingPreviewTarget.removeAttribute("src")
        this.pendingPreviewContainerTarget.hidden = true
        this.currentPreviewTarget.hidden = false
      }

      async loadSourceImage(file) {
        try {
          if (!this.allowedTypesValue.includes(file.type)) throw new Error(this.invalidTypeMessageValue)
          if (file.size === 0 || file.size > this.maxBytesValue) throw new Error(this.tooLargeMessageValue)

          this.revokeSourceObjectUrl()
          this.sourceObjectUrl = URL.createObjectURL(file)
          const image = new Image()
          image.alt = ""
          image.decoding = "async"
          image.src = this.sourceObjectUrl
          await image.decode()
          if (image.naturalWidth <= 0 || image.naturalHeight <= 0) throw new Error(this.undecodableMessageValue)
          if (image.naturalWidth > this.maxDimensionValue || image.naturalHeight > this.maxDimensionValue) {
            throw new Error(this.tooWideOrTallMessageValue)
          }
          return image
        } catch (error) {
          this.revokeSourceObjectUrl()
          const message = error instanceof Error && error.message ? error.message : this.undecodableMessageValue
          throw new Error(message)
        }
      }

      canvasToBlob(canvas, type) {
        const quality = type === "image/png" ? undefined : this.lossyQualityValue
        return new Promise((resolve) => canvas.toBlob(resolve, type, quality))
      }

      validateConfiguration() {
        if (this.allowedTypesValue.length === 0 || !this.allowedTypesValue.every((type) => typeof type === "string" && type.length > 0)) {
          throw new Error("image-crop allowed types must contain at least one MIME type")
        }
        if (!Number.isInteger(this.maxBytesValue) || this.maxBytesValue <= 0) {
          throw new Error("image-crop max bytes must be a positive integer")
        }
        if (!Number.isInteger(this.maxDimensionValue) || this.maxDimensionValue <= 0) {
          throw new Error("image-crop max dimension must be a positive integer")
        }
        if (!Number.isFinite(this.initialCoverageValue) || this.initialCoverageValue <= 0 || this.initialCoverageValue > 1) {
          throw new Error("image-crop initial coverage must be greater than 0 and at most 1")
        }
        if (!Number.isFinite(this.lossyQualityValue) || this.lossyQualityValue <= 0 || this.lossyQualityValue > 1) {
          throw new Error("image-crop lossy quality must be greater than 0 and at most 1")
        }
        if (this.hasAspectRatioValue && (!Number.isFinite(this.aspectRatioValue) || this.aspectRatioValue <= 0)) {
          throw new Error("image-crop aspect ratio must be a positive number when specified")
        }
        this.validateOptionalDimension("width", this.hasOutputWidthValue, this.outputWidthValue)
        this.validateOptionalDimension("height", this.hasOutputHeightValue, this.outputHeightValue)
      }

      validateOptionalDimension(name, present, value) {
        if (present && (!Number.isInteger(value) || value <= 0)) {
          throw new Error(`image-crop output ${name} must be a positive integer when specified`)
        }
      }

      configuredAspectRatio() {
        return this.hasAspectRatioValue ? this.aspectRatioValue : Number.NaN
      }

      selectionAspectRatioAttributes() {
        if (!this.hasAspectRatioValue) return ""

        const ratio = this.aspectRatioValue
        return `initial-aspect-ratio="${ratio}" aspect-ratio="${ratio}"`
      }

      canvasOptions() {
        const options = {}
        if (this.hasOutputWidthValue) options.width = this.outputWidthValue
        if (this.hasOutputHeightValue) options.height = this.outputHeightValue
        return options
      }

      cropperImage() {
        const image = this.cropper?.getCropperImage()
        if (!image) throw new Error("Cropper image is unavailable")
        return image
      }

      cropperSelection() {
        const selection = this.cropper?.getCropperSelection()
        if (!selection) throw new Error("Cropper selection is unavailable")
        return selection
      }

      writeInput(file) {
        const transfer = new DataTransfer()
        if (file) transfer.items.add(file)
        this.inputTarget.files = transfer.files
      }

      updatePreview(file) {
        this.revokePreviewObjectUrl()
        this.previewObjectUrl = URL.createObjectURL(file)
        this.pendingPreviewTarget.src = this.previewObjectUrl
        this.pendingPreviewContainerTarget.hidden = false
        this.currentPreviewTarget.hidden = true
      }

      showError(message) {
        this.errorTargets.forEach((target) => {
          target.textContent = message
          target.hidden = false
        })
      }

      clearError() {
        this.errorTargets.forEach((target) => {
          target.textContent = ""
          target.hidden = true
        })
      }

      destroyCropper() {
        this.cropper?.destroy()
        this.cropper = null
        this.cropperTarget.replaceChildren()
      }

      revokeSourceObjectUrl() {
        if (this.sourceObjectUrl) URL.revokeObjectURL(this.sourceObjectUrl)
        this.sourceObjectUrl = null
      }

      revokePreviewObjectUrl() {
        if (this.previewObjectUrl) URL.revokeObjectURL(this.previewObjectUrl)
        this.previewObjectUrl = null
      }
    }
  JAVASCRIPT
end

def configure_profile
  features = VALUES.fetch("profile_features")
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
      before_save :assign_avatar_upload, if: :avatar_upload_present?
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
        def avatar_upload_present?
          avatar_upload.present?
        end

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
    create_file "app/services/avatar_upload.rb", <<~'RUBY', force: true
      require "tempfile"

      class AvatarUpload < T::Struct
        extend T::Sig

        Error = Class.new(StandardError)

        const :tempfile, Tempfile
        const :size, Integer
        const :content_type, String

        sig { params(value: Object).returns(AvatarUpload) }
        def self.coerce(value)
          unless value.respond_to?(:tempfile) && value.respond_to?(:size) && value.respond_to?(:content_type)
            raise Error, "upload must expose tempfile, size, and content_type"
          end

          dynamic_value = T.unsafe(value)
          tempfile = dynamic_value.tempfile
          size = dynamic_value.size
          content_type = dynamic_value.content_type
          raise Error, "upload tempfile must be a Tempfile" unless tempfile.is_a?(Tempfile)
          raise Error, "upload size must be an Integer" unless size.is_a?(Integer)
          raise Error, "upload content_type must be a String" unless content_type.is_a?(String)

          new(tempfile:, size:, content_type:)
        end
      end
    RUBY

    create_file "app/services/avatar_image_policy.rb", <<~'RUBY', force: true
      require "marcel"
      require "pathname"
      require "vips"

      class AvatarImagePolicy
        extend T::Sig

        MAX_BYTES = T.let(5 * 1024 * 1024, Integer)
        MAX_SIZE_LABEL = T.let("5 MiB", String)
        MAX_DIMENSION = T.let(4096, Integer)
        CONTENT_TYPES = T.let(%w[image/jpeg image/png image/webp].freeze, T::Array[String])

        class ValidationError < StandardError
          extend T::Sig

          sig { returns(Symbol) }
          attr_reader :code

          sig { params(code: Symbol).void }
          def initialize(code)
            @code = code
            super(code.to_s)
          end
        end

        sig { params(upload: AvatarUpload).returns(T::Boolean) }
        def self.validate!(upload)
          new(upload).validate!
        end

        sig { params(upload: AvatarUpload).void }
        def initialize(upload)
          @upload = upload
        end

        sig { returns(T::Boolean) }
        def validate!
          raise_error(:empty) if upload.size.to_i.zero?
          raise_error(:too_large) if upload.size.to_i > MAX_BYTES

          path = T.must(upload.tempfile.path)
          actual_type = Marcel::MimeType.for(Pathname(path), name: nil, declared_type: nil)
          declared_type = upload.content_type.to_s.downcase
          raise_error(:unsupported_type) unless CONTENT_TYPES.include?(actual_type)
          raise_error(:content_type_mismatch) unless declared_type == actual_type

          bytes = File.binread(path)
          raise_error(:animated) if animated_png?(bytes) || animated_webp?(bytes)

          image = Vips::Image.new_from_file(path, access: :sequential, fail_on: :truncated)
          raise_error(:too_wide_or_tall) if image.width > MAX_DIMENSION || image.height > MAX_DIMENSION
          raise_error(:not_square) unless image.width == image.height
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
          sig { returns(AvatarUpload) }
          attr_reader :upload

          sig { params(code: Symbol).returns(T.noreturn) }
          def raise_error(code)
            raise ValidationError, code
          end

          sig { params(bytes: String).returns(T::Boolean) }
          def animated_png?(bytes)
            return false unless bytes.start_with?("\x89PNG\r\n\x1A\n".b)

            each_chunk(bytes, offset: 8, length_bytes: 4, byte_order: "N") do |type, _data|
              return true if type == "acTL"
              break if type == "IEND"
            end
            false
          end

          sig { params(bytes: String).returns(T::Boolean) }
          def animated_webp?(bytes)
            return false unless bytes.byteslice(0, 4) == "RIFF" && bytes.byteslice(8, 4) == "WEBP"

            offset = 12
            while offset + 8 <= bytes.bytesize
              type = bytes.byteslice(offset, 4)
              length = T.must(bytes.byteslice(offset + 4, 4)).unpack1("V")
              data_start = offset + 8
              break if data_start + length > bytes.bytesize

              data = T.must(bytes.byteslice(data_start, length))
              return true if %w[ANIM ANMF].include?(type)
              return true if type == "VP8X" && (data.getbyte(0).to_i & 0b0000_0010).positive?

              offset += 8 + length + (length.odd? ? 1 : 0)
            end
            false
          end

          sig do
            params(
              bytes: String,
              offset: Integer,
              length_bytes: Integer,
              byte_order: String,
              block: T.proc.params(type: String, data: String).void
            ).void
          end
          def each_chunk(bytes, offset:, length_bytes:, byte_order:, &block)
            while offset + length_bytes + 4 <= bytes.bytesize
              length = T.must(bytes.byteslice(offset, length_bytes)).unpack1(byte_order)
              type = T.must(bytes.byteslice(offset + length_bytes, 4))
              data_start = offset + length_bytes + 4
              break if data_start + length > bytes.bytesize

              block.call(type, T.must(bytes.byteslice(data_start, length)))
              chunk_size = length_bytes + 4 + length
              chunk_size += 4
              offset += chunk_size
            end
          end
      end
    RUBY

    create_file "app/validators/avatar_upload_validator.rb", <<~'RUBY', force: true
      class AvatarUploadValidator < ActiveModel::EachValidator
        extend T::Sig

        sig do
          params(
            record: Profile,
            attribute: Symbol,
            upload: Object
          ).void
        end
        def validate_each(record, attribute, upload)
          return if upload.blank?

          AvatarImagePolicy.validate!(AvatarUpload.coerce(upload))
        rescue AvatarUpload::Error
          record.errors.add(attribute, :undecodable)
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

  profile_owner = "current_user"
  authentication = "  before_action :authenticate_user!\n"
  permitted_features = features.map { |feature| feature == "avatar" ? ":avatar_upload" : ":#{feature}" }.join(", ")
  destroy_avatar_action = if avatar_enabled
    <<~RUBY

        sig { void }
        def destroy_avatar
          profile = T.must(account_user.profile)
          profile.avatar.purge if profile.avatar.attached?
          redirect_to profile_path, notice: I18n.t("profiles.avatar.destroy.notice"), status: :see_other
        end
    RUBY
  else
    ""
  end
  create_file "app/controllers/profiles_controller.rb", <<~RUBY, force: true
    class ProfilesController < ApplicationController
      extend T::Sig

      layout "account"
    #{authentication}
      sig { void }
      def show
        @profile = T.must(account_user.profile)
      end

      sig { void }
      def edit
        @profile = T.must(account_user.profile)
      end

      sig { void }
      def update
        @profile = T.must(account_user.profile)
        if @profile.update(profile_params)
          redirect_to profile_path, notice: I18n.t("profiles.update.notice"), status: :see_other
        else
          render :edit, status: :unprocessable_content
        end
      end
    #{destroy_avatar_action}

      private
        sig { returns(User) }
        def account_user
          T.must(#{profile_owner})
        end

        def profile_params
          params.expect(profile: [#{permitted_features}])
        end
    end
  RUBY
  route "resource :profile, only: %i[show edit update]"
  route 'delete "profile/avatar", to: "profiles#destroy_avatar", as: :profile_avatar' if avatar_enabled

  profile_locale_ja = {
    "profiles" => {
      "title" => "プロフィール", "edit_title" => "プロフィール編集", "edit" => "プロフィールを編集",
      "screen_name_hint" => "小文字の英数字とアンダースコアが使えます。", "current_avatar" => "現在のアバター", "avatar_label" => "アバター", "avatar_hint" => "静止画JPEG、PNG、WebP（5 MiB以下、幅・高さ4096px以下）を選択し、正方形に切り抜いてください。",
      "avatar_crop" => {
        "title" => "アバター画像の切り抜き", "description" => "正方形の範囲を移動・拡大縮小して構図を調整してください。", "preview" => "切り抜き後のアバターpreview",
        "zoom_out" => "縮小", "zoom_in" => "拡大", "reset" => "リセット", "apply" => "切り抜きを適用", "cancel" => "キャンセル", "close" => "閉じる",
        "invalid_type" => "静止画JPEG、PNG、WebPを選択してください。", "too_large" => "画像は5 MiB以下にしてください。", "too_wide_or_tall" => "画像の幅と高さは4096px以下にしてください。",
        "undecodable" => "画像を読み込めませんでした。", "crop_failed" => "正方形画像を生成できませんでした。別の画像を選択してください。"
      },
      "avatar_delete_title" => "アバター画像の削除", "avatar_delete_description" => "設定済みの画像を削除し、IDから生成したアバターへ戻します。", "avatar_delete" => "設定済み画像を削除", "avatar_delete_confirm" => "設定済みのアバター画像を削除しますか？",
      "update" => { "notice" => "プロフィールを更新しました" }, "avatar" => { "destroy" => { "notice" => "アバター画像を削除しました" } }
    },
    "activerecord" => {
      "attributes" => { "profile" => { "screen_name" => "スクリーンネーム", "display_name" => "表示名", "avatar" => "アバター画像", "avatar_upload" => "アバター画像" } },
      "errors" => { "models" => { "profile" => { "attributes" => { "avatar_upload" => {
        "empty" => "が空です", "too_large" => "は%{max_size}以下にしてください", "unsupported_type" => "は静止画JPEG、PNG、WebPを選択してください",
        "content_type_mismatch" => "のファイル形式と申告形式が一致しません", "too_wide_or_tall" => "の幅と高さは%{max_dimension}px以下にしてください", "not_square" => "は正方形にしてください",
        "animated" => "にanimationを含めることはできません", "undecodable" => "を画像として解析できません"
      } } } } }
    }
  }
  profile_locale_en = {
    "profiles" => {
      "title" => "Profile", "edit_title" => "Edit profile", "edit" => "Edit profile",
      "screen_name_hint" => "Use lowercase letters, numbers, and underscores.", "current_avatar" => "Current avatar", "avatar_label" => "Avatar", "avatar_hint" => "Choose a static JPEG, PNG, or WebP up to 5 MiB and 4096px on either side, then crop it to a square.",
      "avatar_crop" => {
        "title" => "Crop avatar image", "description" => "Move and resize the square selection to compose your avatar.", "preview" => "Cropped avatar preview",
        "zoom_out" => "Zoom out", "zoom_in" => "Zoom in", "reset" => "Reset", "apply" => "Apply crop", "cancel" => "Cancel", "close" => "Close",
        "invalid_type" => "Choose a static JPEG, PNG, or WebP image.", "too_large" => "The image must be no larger than 5 MiB.", "too_wide_or_tall" => "The image must be no wider or taller than 4096px.",
        "undecodable" => "The image could not be loaded.", "crop_failed" => "A square image could not be generated. Choose another image."
      },
      "avatar_delete_title" => "Delete avatar image", "avatar_delete_description" => "Delete the uploaded image and return to the avatar generated from your ID.", "avatar_delete" => "Delete uploaded image", "avatar_delete_confirm" => "Delete the uploaded avatar image?",
      "update" => { "notice" => "Your profile was updated." }, "avatar" => { "destroy" => { "notice" => "Your avatar image was deleted." } }
    },
    "activerecord" => {
      "attributes" => { "profile" => { "screen_name" => "Screen name", "display_name" => "Display name", "avatar" => "Avatar image", "avatar_upload" => "Avatar image" } },
      "errors" => { "models" => { "profile" => { "attributes" => { "avatar_upload" => {
        "empty" => "is empty", "too_large" => "must be no larger than %{max_size}", "unsupported_type" => "must be a static JPEG, PNG, or WebP",
        "content_type_mismatch" => "does not match its declared file type", "too_wide_or_tall" => "must be no wider or taller than %{max_dimension}px", "not_square" => "must be square",
        "animated" => "must not contain animation", "undecodable" => "could not be decoded as an image"
      } } } } }
    }
  }
  create_locale_pair("profiles", ja: profile_locale_ja, en: profile_locale_en)

  if avatar_enabled
    create_file "app/helpers/avatar_helper.rb", <<~RUBY, force: true
      module AvatarHelper
        extend T::Sig

        BORING_AVATAR_COLORS = %w[#ffffff #3ea8ff #f1f5f9 #0f83fd #d6e3ed].freeze
        AVATAR_VARIANTS = { 40 => :header_avatar, 64 => :profile_avatar }.freeze

        sig { params(profile: Profile, size: Integer, alt: String).returns(String) }
        def profile_avatar(profile, size:, alt:)
          variant = AVATAR_VARIANTS.fetch(size)
          if profile.avatar.attached?
            image_tag profile.avatar.variant(variant), alt: alt, class: "object-cover", width: size, height: size
          else
            accessibility = alt.present? ? { label: alt } : { hidden: true }
            boring_avatar(
              profile.user_id.to_s,
              variant: :beam,
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

        def upload(format: :png, width: 96, height: 96, content_type: nil)
          tempfile = image_file(format:, width:, height:)
          uploaded_file(tempfile, "avatar.#{format}", content_type || "image/#{format == :jpg ? 'jpeg' : format}")
        end

        def image_file(format: :png, width: 96, height: 96)
          tempfile = Tempfile.new(["avatar-", ".#{format}"])
          tempfile.binmode
          image = Vips::Image.black(width, height, bands: 3).new_from_image([32, 128, 224])
          image.write_to_file(tempfile.path)
          tempfile.rewind
          tempfile
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
          offset = after_ihdr ? 33 : T.must(bytes.index("IEND")) - 4
          tempfile.rewind
          tempfile.truncate(0)
          tempfile.write(T.must(bytes.byteslice(0, offset)) + chunk + T.must(bytes.byteslice(offset..)))
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
            assert AvatarImagePolicy.validate!(AvatarUpload.coerce(AvatarTestImage.upload(format:, content_type:)))
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

        test "rejects non-square images" do
          assert_policy_error :not_square, AvatarTestImage.upload(width: 96, height: 72)
        end

        test "rejects APNG and animated WebP" do
          assert_policy_error :animated, AvatarTestImage.apng_upload
          assert_policy_error :animated, AvatarTestImage.animated_webp_upload
        end

        private
          def assert_policy_error(code, upload)
            error = assert_raises(AvatarImagePolicy::ValidationError) do
              AvatarImagePolicy.validate!(AvatarUpload.coerce(upload))
            end
            assert_equal code, error.code
          end
      end
    RUBY

    create_file "test/helpers/avatar_helper_test.rb", <<~RUBY, force: true
      require "test_helper"

      class AvatarHelperTest < ActionView::TestCase
        include AvatarHelper

        test "generates the default avatar from the user id and Rapid Rails palette" do
          profile = profiles(:one)
          view = ApplicationController.helpers
          expected = boring_avatar(
            profile.user_id.to_s,
            variant: :beam,
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
          assert_includes rendered, "/rails/active_storage/representations/proxy/"
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
            stored_variant = ActiveStorageDB::File.find_by!(ref: variant.image.blob.key)
            assert_equal variant.image.blob.download, stored_variant.data
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
        profile[:screen_name] = nil

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
        profile[:display_name] = nil

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
        profile = T.must(user.profile)
        profile.avatar.attach(AvatarTestImage.upload(width: 120, height: 80))
        profile.avatar.variant(:profile_avatar).processed
        blob_ids = [profile.avatar.blob.id, *profile.avatar.blob.variant_records.map { |record| record.image.blob.id }]
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

  if avatar_enabled
    create_file "test/system/profile_avatar_crop_test.rb", <<~'RUBY', force: true
      require "application_system_test_case"

      class ProfileAvatarCropTest < ApplicationSystemTestCase
        test "crops a rectangular image to a 512 pixel square before upload" do
          user = users(:one)
          profile = T.must(user.profile)
          source = AvatarTestImage.image_file(width: 320, height: 180)
          sign_in(user)

          visit edit_profile_path
          attach_file Profile.human_attribute_name(:avatar_upload), source.path

          assert_selector "dialog#avatar-crop-modal[open]"
          assert_equal 0, page.evaluate_script('document.querySelector("input[name=\\"profile[avatar_upload]\\"]").files.length')
          assert_not profile.reload.avatar.attached?
          selection_geometry = page.evaluate_script(<<~JAVASCRIPT)
            (() => {
              const selection = document.querySelector("cropper-selection")
              return { width: selection.width, height: selection.height, aspectRatio: selection.aspectRatio }
            })()
          JAVASCRIPT
          assert_in_delta selection_geometry.fetch("width"), selection_geometry.fetch("height"), 0.5
          assert_equal 1, selection_geometry.fetch("aspectRatio")

          initial_transform = page.evaluate_script('document.querySelector("cropper-image").$getTransform()')
          click_button I18n.t("profiles.avatar_crop.zoom_in")
          zoomed_transform = page.evaluate_script('document.querySelector("cropper-image").$getTransform()')
          refute_equal initial_transform, zoomed_transform

          click_button I18n.t("profiles.avatar_crop.apply")
          assert_no_selector "dialog#avatar-crop-modal[open]"
          metadata = page.evaluate_async_script(<<~JAVASCRIPT)
            const done = arguments[0]
            const file = document.querySelector('input[name="profile[avatar_upload]"]').files[0]
            createImageBitmap(file).then((image) => {
              done({ name: file.name, type: file.type, width: image.width, height: image.height })
            }).catch((error) => done({ error: error.message }))
          JAVASCRIPT
          assert_equal File.basename(source.path), metadata.fetch("name")
          assert_equal "image/png", metadata.fetch("type")
          assert_equal [512, 512], metadata.values_at("width", "height")
          assert_selector '[data-image-crop-target="pendingPreviewContainer"]:not([hidden]) img[src^="blob:"]'
          assert_not profile.reload.avatar.attached?

          click_button I18n.t("common.save")
          assert_current_path profile_path
          assert_predicate profile.reload.avatar, :attached?
          stored = Vips::Image.new_from_buffer(profile.avatar.blob.download, "")
          assert_equal [512, 512], [stored.width, stored.height]
          assert_equal "image/png", profile.avatar.blob.content_type
        ensure
          source&.close!
        end

        test "supports configured and free aspect ratios" do
          user = users(:one)
          fixed_source = AvatarTestImage.image_file(width: 640, height: 360)
          free_source = AvatarTestImage.image_file(width: 400, height: 300)
          sign_in(user)
          visit edit_profile_path

          page.execute_script(<<~JAVASCRIPT)
            const element = document.querySelector('[data-controller="image-crop"]')
            element.setAttribute("data-image-crop-aspect-ratio-value", String(16 / 9))
            element.setAttribute("data-image-crop-output-width-value", "640")
            element.setAttribute("data-image-crop-output-height-value", "360")
          JAVASCRIPT
          page.driver.with_playwright_page do |playwright_page|
            playwright_page.wait_for_function(<<~JAVASCRIPT)
              () => {
                const element = document.querySelector('[data-controller="image-crop"]')
                const controller = window.Stimulus.getControllerForElementAndIdentifier(element, "image-crop")
                return controller?.aspectRatioValue === 16 / 9 &&
                  controller?.outputWidthValue === 640 && controller?.outputHeightValue === 360
              }
            JAVASCRIPT
          end
          attach_file Profile.human_attribute_name(:avatar_upload), fixed_source.path
          assert_selector "dialog#avatar-crop-modal[open]"
          page.driver.with_playwright_page do |playwright_page|
            playwright_page.wait_for_function(<<~JAVASCRIPT)
              () => {
                const selection = document.querySelector("cropper-selection")
                return selection && Math.abs(selection.width / selection.height - 16 / 9) < 0.01
              }
            JAVASCRIPT
          end
          fixed_geometry = page.evaluate_script(<<~JAVASCRIPT)
            (() => {
              const selection = document.querySelector("cropper-selection")
              return { width: selection.width, height: selection.height, aspectRatio: selection.aspectRatio }
            })()
          JAVASCRIPT
          assert_in_delta 16.0 / 9, fixed_geometry.fetch("width").to_f / fixed_geometry.fetch("height"), 0.01
          assert_in_delta 16.0 / 9, fixed_geometry.fetch("aspectRatio"), 0.01
          click_button I18n.t("profiles.avatar_crop.apply")
          assert_no_selector "dialog#avatar-crop-modal[open]"
          assert_equal [640, 360], selected_image_dimensions

          page.execute_script(<<~JAVASCRIPT)
            const element = document.querySelector('[data-controller="image-crop"]')
            element.removeAttribute("data-image-crop-aspect-ratio-value")
            element.removeAttribute("data-image-crop-output-width-value")
            element.removeAttribute("data-image-crop-output-height-value")
          JAVASCRIPT
          page.driver.with_playwright_page do |playwright_page|
            playwright_page.wait_for_function(<<~JAVASCRIPT)
              () => {
                const element = document.querySelector('[data-controller="image-crop"]')
                const controller = window.Stimulus.getControllerForElementAndIdentifier(element, "image-crop")
                return controller && !controller.hasAspectRatioValue &&
                  !controller.hasOutputWidthValue && !controller.hasOutputHeightValue
              }
            JAVASCRIPT
          end
          attach_file Profile.human_attribute_name(:avatar_upload), free_source.path
          assert_selector "dialog#avatar-crop-modal[open]"
          assert page.evaluate_script('Number.isNaN(document.querySelector("cropper-selection").aspectRatio)')
          page.execute_script('document.querySelector("cropper-selection").$change(20, 20, 240, 120)')
          click_button I18n.t("profiles.avatar_crop.apply")
          assert_no_selector "dialog#avatar-crop-modal[open]"
          assert_equal [240, 120], selected_image_dimensions
        ensure
          fixed_source&.close!
          free_source&.close!
        end

        test "keeps the last confirmed crop when replacements are dismissed" do
          user = users(:one)
          first = AvatarTestImage.image_file(width: 320, height: 180)
          second = AvatarTestImage.image_file(width: 180, height: 320)
          sign_in(user)
          visit edit_profile_path

          attach_file Profile.human_attribute_name(:avatar_upload), first.path
          click_button I18n.t("profiles.avatar_crop.apply")
          assert_no_selector "dialog#avatar-crop-modal[open]"
          committed = selected_file_metadata
          preview = find('[data-image-crop-target="pendingPreview"]')["src"]

          attach_file Profile.human_attribute_name(:avatar_upload), second.path
          assert_selector "dialog#avatar-crop-modal[open]"
          click_button I18n.t("profiles.avatar_crop.cancel")

          assert_no_selector "dialog#avatar-crop-modal[open]"
          assert_equal committed, selected_file_metadata
          assert_equal preview, find('[data-image-crop-target="pendingPreview"]')["src"]

          attach_file Profile.human_attribute_name(:avatar_upload), second.path
          assert_selector "dialog#avatar-crop-modal[open]"
          page.send_keys(:escape)

          assert_no_selector "dialog#avatar-crop-modal[open]"
          assert_equal committed, selected_file_metadata
          assert_equal preview, find('[data-image-crop-target="pendingPreview"]')["src"]

          attach_file Profile.human_attribute_name(:avatar_upload), second.path
          assert_selector "dialog#avatar-crop-modal[open]"
          page.driver.with_playwright_page { |playwright_page| playwright_page.mouse.click(5, 5) }

          assert_no_selector "dialog#avatar-crop-modal[open]"
          assert_equal committed, selected_file_metadata
          assert_equal preview, find('[data-image-crop-target="pendingPreview"]')["src"]
        ensure
          first&.close!
          second&.close!
        end

        test "keeps the last confirmed crop when image conversion fails" do
          user = users(:one)
          first = AvatarTestImage.image_file(width: 320, height: 180)
          second = AvatarTestImage.image_file(width: 180, height: 320)
          sign_in(user)
          visit edit_profile_path

          attach_file Profile.human_attribute_name(:avatar_upload), first.path
          click_button I18n.t("profiles.avatar_crop.apply")
          assert_no_selector "dialog#avatar-crop-modal[open]"
          committed = selected_file_metadata
          preview = find('[data-image-crop-target="pendingPreview"]')["src"]

          attach_file Profile.human_attribute_name(:avatar_upload), second.path
          assert_selector "dialog#avatar-crop-modal[open]"
          page.execute_script(<<~JAVASCRIPT)
            window.originalCanvasToBlob = HTMLCanvasElement.prototype.toBlob
            HTMLCanvasElement.prototype.toBlob = function(callback) { callback(null) }
          JAVASCRIPT
          click_button I18n.t("profiles.avatar_crop.apply")

          assert_selector "dialog#avatar-crop-modal[open]"
          assert_selector 'dialog#avatar-crop-modal [role="alert"]:not([hidden])', text: I18n.t("profiles.avatar_crop.crop_failed")
          assert_equal committed, selected_file_metadata
          assert_equal preview, find('[data-image-crop-target="pendingPreview"]')["src"]
        ensure
          page.execute_script("HTMLCanvasElement.prototype.toBlob = window.originalCanvasToBlob") if page
          first&.close!
          second&.close!
        end

        private
          def sign_in(user)
            login_as user, scope: :user
          end

          def selected_file_metadata
            page.evaluate_script(<<~JAVASCRIPT)
              (() => {
                const file = document.querySelector('input[name="profile[avatar_upload]"]').files[0]
                return { name: file.name, type: file.type, size: file.size }
              })()
            JAVASCRIPT
          end

          def selected_image_dimensions
            page.evaluate_async_script(<<~JAVASCRIPT)
              const done = arguments[0]
              const file = document.querySelector('input[name="profile[avatar_upload]"]').files[0]
              createImageBitmap(file).then((image) => done([image.width, image.height]))
                .catch((error) => done({ error: error.message }))
            JAVASCRIPT
          end
      end
    RUBY
  end

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
          <div class="w-16 rounded-full" data-image-crop-target="currentPreview">
            <%= profile_avatar(profile, size: 64, alt: t("profiles.current_avatar")) %>
          </div>
          <div class="w-16 rounded-full" data-image-crop-target="pendingPreviewContainer" hidden>
            <img class="object-cover" width="64" height="64" alt="<%= t("profiles.avatar_crop.preview") %>" data-image-crop-target="pendingPreview">
          </div>
        </div>
        <%= form.file_field :avatar_upload, class: "file-input min-w-0 w-full", accept: "image/jpeg,image/png,image/webp", data: { image_crop_target: "input", action: "change->image-crop#select" } %>
        <p class="label"><span class="min-w-0 whitespace-normal"><%= t("profiles.avatar_hint") %></span></p>
        <p class="alert alert-error" role="alert" data-image-crop-target="error" hidden></p>
      </fieldset>
    ERB
  end
  form_fields = form_fields.join("\n").lines.map { |line| "  #{line}" }.join
  form_wrapper_open = if avatar_enabled
    <<~ERB
      <div data-controller="image-crop"
           data-image-crop-aspect-ratio-value="1"
           data-image-crop-initial-coverage-value="0.8"
           data-image-crop-output-width-value="512"
           data-image-crop-output-height-value="512"
           data-image-crop-allowed-types-value="[&quot;image/jpeg&quot;,&quot;image/png&quot;,&quot;image/webp&quot;]"
           data-image-crop-max-bytes-value="5242880"
           data-image-crop-max-dimension-value="4096"
           data-image-crop-lossy-quality-value="0.9"
           data-image-crop-invalid-type-message-value="<%= t("profiles.avatar_crop.invalid_type") %>"
           data-image-crop-too-large-message-value="<%= t("profiles.avatar_crop.too_large") %>"
           data-image-crop-too-wide-or-tall-message-value="<%= t("profiles.avatar_crop.too_wide_or_tall") %>"
           data-image-crop-undecodable-message-value="<%= t("profiles.avatar_crop.undecodable") %>"
           data-image-crop-crop-failed-message-value="<%= t("profiles.avatar_crop.crop_failed") %>">
    ERB
  else
    ""
  end
  form_wrapper_close = avatar_enabled ? "</div>\n" : ""
  avatar_crop_modal = if avatar_enabled
    <<~ERB

        <% avatar_crop_actions = capture do %>
          <button type="button" class="btn btn-ghost btn-rapid" data-action="image-crop#cancel"><%= t("profiles.avatar_crop.cancel") %></button>
          <button type="button" class="btn btn-primary btn-rapid" data-image-crop-target="apply" data-action="image-crop#apply"><%= t("profiles.avatar_crop.apply") %></button>
        <% end %>
        <%= with_modal(
          id: "avatar-crop-modal",
          title: t("profiles.avatar_crop.title"),
          description: t("profiles.avatar_crop.description"),
          close_label: t("profiles.avatar_crop.close"),
          actions: avatar_crop_actions,
          dialog_data: { image_crop_target: "dialog", action: "close->image-crop#close" }
        ) do %>
          <div class="alert alert-error mt-4" role="alert" data-image-crop-target="error" hidden></div>
          <div class="mt-4 aspect-square w-full overflow-hidden rounded-box bg-base-200" data-image-crop-target="cropper"></div>
          <div class="mt-4 flex flex-wrap gap-2">
            <button type="button" class="btn btn-rapid" data-action="image-crop#zoomOut"><%= t("profiles.avatar_crop.zoom_out") %></button>
            <button type="button" class="btn btn-rapid" data-action="image-crop#zoomIn"><%= t("profiles.avatar_crop.zoom_in") %></button>
            <button type="button" class="btn btn-rapid" data-action="image-crop#reset"><%= t("profiles.avatar_crop.reset") %></button>
          </div>
        <% end %>
    ERB
  else
    ""
  end
  create_file "app/views/profiles/_form.html.erb", <<~ERB, force: true
    #{form_wrapper_open}  <%= form_with model: profile, url: profile_path, class: "space-y-5" do |form| %>
        <% if profile.errors.any? %>
          <div class="alert alert-error" role="alert">
            <ul class="list-disc pl-5">
              <% profile.errors.full_messages.each do |message| %>
                <li><%= message %></li>
              <% end %>
            </ul>
          </div>
        <% end %>

    #{form_fields.lines.map { |line| "  #{line}" }.join}    <div class="card-actions justify-end">
          <%= link_to t("common.cancel"), profile_path, class: "btn btn-ghost btn-rapid" %>
          <%= form.submit t("common.save"), class: "btn btn-primary btn-rapid" %>
        </div>
      <% end %>
    #{avatar_crop_modal}#{form_wrapper_close}
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
    <% content_for :page_title, t("profiles.title") %>
    <div class="space-y-6">
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
    <% content_for :page_title, t("profiles.edit_title") %>
    <div class="space-y-6">
      <section class="card card-border border-base-300 bg-base-100 shadow-none">
        <div class="card-body">
          <%= render "form", profile: @profile %>
        </div>
      </section>
    #{avatar_delete_section}</div>
  ERB
end

def configure_api
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
      extend T::Sig

      belongs_to :user

      sig { returns(T.nilable(String)) }
      attr_reader :api_secret

      validates :name, :api_key, :api_secret_digest, presence: true
      validates :api_key, uniqueness: true

      before_validation :assign_api_key, :assign_api_secret, on: :create

      sig { params(candidate: String).returns(T::Boolean) }
      def authenticate_api_secret(candidate)
        return false if candidate.blank?

        ActiveSupport::SecurityUtils.secure_compare(api_secret_digest, digest(candidate))
      end

      sig { returns(String) }
      def revoke_api_secret!
        secret = generate_api_secret
        update!(api_secret_digest: digest(secret))
        @api_secret = secret
      end

      private
        def assign_api_key
          current_api_key = T.let(self[:api_key], T.nilable(String))
          self.api_key = "rak_" + SecureRandom.urlsafe_base64(24, false) if current_api_key.nil?
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
        extend T::Sig

        include ActionController::HttpAuthentication::Token::ControllerMethods
        include LocalizedRequest

        before_action :authenticate_api_credential!

        rescue_from ActiveRecord::RecordNotFound, with: -> {
          T.bind(self, Api::ApiController)
          head :not_found
        }
        rescue_from ActionController::ParameterMissing do |error|
          render json: { errors: [error.message] }, status: :bad_request
        end

        private
          sig { returns(ApiCredential) }
          def current_api_credential
            T.must(@current_api_credential)
          end

          sig { returns(User) }
          def current_api_user
            T.must(@current_api_user)
          end

          def authenticate_api_credential!
            token = authenticate_with_http_token { |candidate, _options| candidate }
            api_key, api_secret = token.to_s.split(".", 2)
            return head :unauthorized if api_key.empty? || api_secret.nil?

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
        extend T::Sig

        before_action :set_api_credential, only: %i[show update destroy revoke]

        sig { void }
        def index
          render json: current_api_user.api_credentials.order(created_at: :desc).map { |credential| credential_payload(credential) }
        end

        sig { void }
        def show
          render json: credential_payload(@api_credential)
        end

        sig { void }
        def create
          credential = ApiCredential.new(api_credential_params)
          credential.user = current_api_user
          if credential.save
            render json: credential_payload(credential).merge(api_secret: credential.api_secret), status: :created
          else
            render json: { errors: credential.errors.full_messages }, status: :unprocessable_content
          end
        end

        sig { void }
        def update
          if @api_credential.update(api_credential_params)
            render json: credential_payload(@api_credential)
          else
            render json: { errors: @api_credential.errors.full_messages }, status: :unprocessable_content
          end
        end

        sig { void }
        def destroy
          @api_credential.destroy!
          head :no_content
        end

        sig { void }
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

  account_user = "current_user"
  devise_authentication = "  before_action :authenticate_user!\n"
  create_file "app/controllers/api_credentials_controller.rb", <<~RUBY, force: true
    class ApiCredentialsController < ApplicationController
      extend T::Sig

      layout "account"
    #{devise_authentication}  before_action :set_api_credential, only: %i[show edit update destroy revoke]

      sig { void }
      def index
        @api_credentials = account_user.api_credentials.order(created_at: :desc)
      end

      sig { void }
      def show; end

      sig { void }
      def new
        @api_credential = account_user.api_credentials.build
      end

      sig { void }
      def edit; end

      sig { void }
      def create
        @api_credential = ApiCredential.new(api_credential_params)
        @api_credential.user = account_user
        if @api_credential.save
          @api_secret = @api_credential.api_secret
          render :show, status: :created
        else
          render :new, status: :unprocessable_content
        end
      end

      sig { void }
      def update
        if @api_credential.update(api_credential_params)
          redirect_to @api_credential
        else
          render :edit, status: :unprocessable_content
        end
      end

      sig { void }
      def destroy
        @api_credential.destroy!
        redirect_to api_credentials_path, status: :see_other
      end

      sig { void }
      def revoke
        @api_secret = @api_credential.revoke_api_secret!
        render :show
      end

      private
        sig { returns(User) }
        def account_user
          T.must(#{account_user})
        end

        def set_api_credential
          @api_credential = account_user.api_credentials.find(params.expect(:id))
        end

        def api_credential_params
          params.expect(api_credential: [:name])
        end
    end
  RUBY

  create_locale_pair("api_credentials",
    ja: {
      "api_credentials" => {
        "title" => "APIキーの管理", "description" => "アプリケーションからAPIへ接続するためのcredentialを管理します。", "new" => "APIキーを作成", "edit" => "APIキーを編集", "name_hint" => "利用用途が分かる名前を入力してください。", "api_key" => "API key", "last_used" => "最終利用", "show" => "詳細", "empty" => "APIキーはまだありません。", "api_key_label" => "%{name}のAPI key", "secret_once" => "API Secretはこの画面で一度だけ表示されます。", "information" => "Credential情報", "revoke" => "API Secretを再発行", "revoke_confirm" => "現在のAPI Secretは無効になります。再発行しますか？", "delete_confirm" => "このAPIキーを削除しますか？", "back" => "APIキー一覧へ"
      },
      "activerecord" => { "attributes" => { "api_credential" => { "name" => "名前" } } }
    },
    en: {
      "api_credentials" => {
        "title" => "API credentials", "description" => "Manage credentials used by applications to connect to the API.", "new" => "Create API credential", "edit" => "Edit API credential", "name_hint" => "Enter a name that describes how this credential is used.", "api_key" => "API key", "last_used" => "Last used", "show" => "Details", "empty" => "There are no API credentials yet.", "api_key_label" => "%{name} API key", "secret_once" => "The API Secret is shown only once on this screen.", "information" => "Credential information", "revoke" => "Reissue API Secret", "revoke_confirm" => "The current API Secret will be invalidated. Reissue it?", "delete_confirm" => "Delete this API credential?", "back" => "Back to API credentials"
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
    <% content_for :page_title, t("api_credentials.title") %>
    <div class="space-y-6">
      <header class="flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
        <div>
          <p class="text-sm text-neutral"><%= t("api_credentials.description") %></p>
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
    <% content_for :page_title, @api_credential.name %>
    <div class="space-y-6">
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
    <% content_for :page_title, t("api_credentials.new") %>
    <div class="space-y-6">
      <section class="card card-border border-base-300 bg-base-100 shadow-none"><div class="card-body p-5 sm:p-6"><%= render "form", api_credential: @api_credential %></div></section>
    </div>
  ERB

  create_file "app/views/api_credentials/edit.html.erb", <<~ERB, force: true
    <% content_for :page_title, t("api_credentials.edit") %>
    <div class="space-y-6">
      <section class="card card-border border-base-300 bg-base-100 shadow-none"><div class="card-body p-5 sm:p-6"><%= render "form", api_credential: @api_credential %></div></section>
    </div>
  ERB

  create_file "test/models/api_credential_test.rb", <<~RUBY, force: true
    require "test_helper"

    class ApiCredentialTest < ActiveSupport::TestCase
      test "stores only the digest and invalidates the revoked secret" do
        credential = users(:one).api_credentials.create!(name: "CLI")
        original_secret = T.must(credential.api_secret)

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
          { "Authorization" => "Bearer " + [@credential.api_key, T.must(secret)].join(".") }
        end
    end
  RUBY

  web_test_authentication = <<~RUBY
        include Devise::Test::IntegrationHelpers

        setup do
          @user = users(:one)
          sign_in @user
        end
  RUBY
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
  siwe_login = if VALUES.fetch("additional_login_methods").include?("siwe")
    <<~'ERB'
      <div class="divider"><%= t("authentication.or") %></div>
      <div data-controller="siwe-sign-in"
           data-siwe-sign-in-mode-value="login"
           data-siwe-sign-in-challenge-url-value="<%= user_siwe_challenge_path %>"
           data-siwe-sign-in-verify-url-value="<%= user_siwe_path %>"
           data-siwe-sign-in-wallet-missing-value="<%= t('siwe.errors.wallet_missing') %>"
           data-siwe-sign-in-challenge-error-value="<%= t('siwe.errors.challenge') %>"
           data-siwe-sign-in-verification-error-value="<%= t('siwe.errors.verification') %>">
        <button type="button" class="btn btn-block btn-rapid" data-action="siwe-sign-in#authenticate"><%= t("authentication.sign_in_with_wallet") %></button>
        <div class="alert alert-error mt-4 hidden" role="alert" data-siwe-sign-in-target="error"></div>
      </div>
    ERB
  else
    ""
  end
  siwe_signup = if VALUES.fetch("additional_login_methods").include?("siwe")
    <<~'ERB'
      <div class="divider"><%= t("authentication.or") %></div>
      <div data-controller="siwe-sign-in"
           data-siwe-sign-in-mode-value="signup"
           data-siwe-sign-in-challenge-url-value="<%= user_siwe_registration_challenge_path %>"
           data-siwe-sign-in-verify-url-value="<%= user_siwe_registration_path %>"
           data-siwe-sign-in-wallet-missing-value="<%= t('siwe.errors.wallet_missing') %>"
           data-siwe-sign-in-challenge-error-value="<%= t('siwe.errors.challenge') %>"
           data-siwe-sign-in-verification-error-value="<%= t('siwe.errors.verification') %>">
        <button type="button" class="btn btn-block btn-rapid" data-action="siwe-sign-in#authenticate"><%= t("authentication.sign_up_with_wallet") %></button>
        <div class="alert alert-error mt-4 hidden" role="alert" data-siwe-sign-in-target="error"></div>
      </div>
    ERB
  else
    ""
  end

  create_file "app/views/users/passkey_sessions/new.html.erb", <<~ERB, force: true
    <% content_for :page_title, t("authentication.sign_in_title") %>
    <header class="mb-8">
      <h1 class="text-2xl font-bold leading-[1.5]"><%= content_for(:page_title) %></h1>
      <p class="mt-2 text-sm text-base-content/70"><%= t("authentication.sign_in_description") %></p>
    </header>

    <div data-controller="passkey"
         data-passkey-ceremony-value="get"
         data-passkey-options-url-value="<%= user_passkey_session_options_path %>"
         data-passkey-verify-url-value="<%= user_passkey_session_path %>"
         data-passkey-unsupported-value="<%= t('passkeys.errors.unsupported') %>"
         data-passkey-failed-value="<%= t('passkeys.errors.verification') %>">
      <label class="label mb-4 cursor-pointer justify-start gap-3 text-base-content">
        <input type="checkbox" class="checkbox checkbox-sm" data-passkey-target="rememberMe">
        <span><%= t("authentication.remember_me") %></span>
      </label>
      <button type="button" class="btn btn-primary btn-block btn-rapid" data-action="passkey#authenticate"><%= t("authentication.sign_in_with_passkey") %></button>
      <div class="alert alert-error mt-4 hidden" role="alert" data-passkey-target="error"></div>
    </div>

    #{siwe_login}
    <div class="divider"></div>
    <%= link_to t("authentication.create_account"), new_user_registration_path, class: "btn btn-block btn-rapid" %>
  ERB

  create_file "app/views/users/passkey_registrations/new.html.erb", <<~ERB, force: true
    <% content_for :page_title, t("authentication.sign_up_title") %>
    <header class="mb-8">
      <h1 class="text-2xl font-bold leading-[1.5]"><%= content_for(:page_title) %></h1>
      <p class="mt-2 text-sm text-base-content/70"><%= t("authentication.sign_up_description") %></p>
    </header>

    <div data-controller="passkey"
         data-passkey-ceremony-value="create"
         data-passkey-options-url-value="<%= user_passkey_registration_options_path %>"
         data-passkey-verify-url-value="<%= user_passkey_registration_path %>"
         data-passkey-unsupported-value="<%= t('passkeys.errors.unsupported') %>"
         data-passkey-failed-value="<%= t('passkeys.errors.verification') %>">
      <button type="button" class="btn btn-primary btn-block btn-rapid" data-action="passkey#authenticate"><%= t("authentication.sign_up_with_passkey") %></button>
      <div class="alert alert-error mt-4 hidden" role="alert" data-passkey-target="error"></div>
    </div>

    #{siwe_signup}
    <div class="divider"></div>
    <%= link_to t("authentication.back_to_sign_in"), new_user_session_path, class: "btn btn-block btn-rapid" %>
  ERB

  create_locale_pair(
    "authentication",
    ja: {
      "authentication" => {
        "sign_in_title" => "ログイン", "sign_in_description" => "Passkeyまたは登録済みウォレットでログインします。",
        "sign_up_title" => "アカウント作成", "sign_up_description" => "Passkeyまたはウォレットで、パスワードなしのアカウントを作成します。",
        "sign_in_with_passkey" => "Passkeyでログイン", "sign_up_with_passkey" => "Passkeyでアカウントを作成",
        "sign_in_with_wallet" => "ウォレットでログイン", "sign_up_with_wallet" => "ウォレットでアカウントを作成",
        "remember_me" => "ログイン状態を保持する", "or" => "または", "create_account" => "アカウントを作成",
        "back_to_sign_in" => "ログイン画面へ"
      }
    },
    en: {
      "authentication" => {
        "sign_in_title" => "Sign in", "sign_in_description" => "Sign in with a passkey or a linked wallet.",
        "sign_up_title" => "Create account", "sign_up_description" => "Create a passwordless account with a passkey or wallet.",
        "sign_in_with_passkey" => "Sign in with passkey", "sign_up_with_passkey" => "Create account with passkey",
        "sign_in_with_wallet" => "Sign in with wallet", "sign_up_with_wallet" => "Create account with wallet",
        "remember_me" => "Keep me signed in", "or" => "or", "create_account" => "Create account",
        "back_to_sign_in" => "Back to sign in"
      }
    }
  )
end

def configure_default_views
  siwe_enabled = VALUES.fetch("additional_login_methods").include?("siwe")
  pwa_enabled = VALUES.fetch("pwa") == "use"
  web_push_enabled = VALUES.fetch("web_push") == "use"
  job_operations_enabled = VALUES.fetch("job_operations") == "enable"
  solid_queue_enabled = VALUES.fetch("active_job") == "solid_queue"
  maintenance_tasks_enabled = VALUES.fetch("maintenance_tasks") == "enable"
  api_enabled = VALUES.fetch("api") == "enable"
  dokploy_enabled = VALUES.fetch("deployment") == "dokploy"
  profile_features = VALUES.fetch("profile_features")
  profile_enabled = profile_features.any?
  avatar_enabled = profile_features.include?("avatar")
  screen_name_enabled = profile_features.include?("screen_name")
  display_name_enabled = profile_features.include?("display_name")
  account_navigation_count = 2 + (profile_enabled ? 1 : 0) + (api_enabled ? 1 : 0) +
    (web_push_enabled ? 1 : 0)
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
  home_action = '<%= link_to t("home.start_devise"), new_user_registration_path, class: "btn btn-primary btn-rapid px-6 hover:border-secondary hover:bg-secondary" %>'
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
  account_settings_path = "application_routes.account_passkeys_path"
  account_navigation_items += <<~ERB
    <li>
      <% account_settings_active = controller_path.in?(["account/passkeys", "account/siwe_identities"]) || current_page?(application_routes.delete_account_path) %>
      <%= link_to #{account_settings_path}, class: ("menu-active" if account_settings_active), aria: { current: ("page" if account_settings_active) } do %>
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
  signed_in_condition = "user_signed_in?"
  admin_controller_conditions = ['controller_path.start_with?("admin/")']
  admin_controller_conditions << 'controller_path.start_with?("mission_control/jobs/")' if job_operations_enabled
  admin_controller_conditions << 'controller_path.start_with?("maintenance_tasks/")' if maintenance_tasks_enabled
  admin_controller_condition = admin_controller_conditions.join(" || ")
  profile_owner = "current_user.profile"
  logout_path = "application_routes.destroy_user_session_path"
  guest_desktop_navigation = <<~ERB
    <%= link_to t("navigation.sign_in"), application_routes.new_user_session_path, class: "btn btn-ghost btn-rapid" %>
    <%= link_to t("navigation.sign_up"), application_routes.new_user_registration_path, class: "btn btn-primary btn-outline btn-rapid" %>
  ERB
  guest_mobile_navigation = <<~ERB
    <li><%= link_to t("navigation.sign_in"), application_routes.new_user_session_path %></li>
    <li><%= link_to t("navigation.sign_up"), application_routes.new_user_registration_path %></li>
  ERB
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
  layout_method = %(devise_controller? ? "authentication" : "application")
  wallet_script = ""
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
      extend T::Sig

      layout :application_layout

      sig { returns(String) }
      def application_layout
        #{layout_method}
      end
      private :application_layout

  RUBY

  home_authentication = ""
  create_file "app/controllers/home_controller.rb", <<~RUBY, force: true
    class HomeController < ApplicationController
      extend T::Sig

    #{home_authentication}  sig { void }
      def index; end
    end
  RUBY

  accounts_controller = <<~RUBY
    class AccountsController < ApplicationController
      extend T::Sig

      layout :account_layout
      before_action :authenticate_user!

      sig { void }
      def show; end

      sig { void }
      def delete
        if T.must(current_user).last_admin?
          redirect_to account_path, alert: t("accounts.destroy.last_admin")
        end
      end

      private

        sig { returns(String) }
        def account_layout
          action_name == "delete" ? "account_settings" : "account"
        end
    end
  RUBY
  create_file "app/controllers/accounts_controller.rb", accounts_controller, force: true

  create_file "app/helpers/application_helper.rb", <<~'RUBY', force: true
    module ApplicationHelper
      extend T::Sig

      class Tab < T::Struct
        const :name, String
        const :path, String
        const :is_active, T.nilable(T.proc.returns(T::Boolean)), default: nil
      end

      module ApplicationRoutes
      end

      Rails.application.routes.url_helpers.extend(ApplicationRoutes)

      sig { returns(ApplicationRoutes) }
      def application_routes
        Rails.application.routes.url_helpers
      end

      sig { returns(ApplicationIdentity) }
      def application_identity
        Rails.configuration.x.application_identity
      end

      sig { returns(String) }
      def document_title
        page_title = content_for(:page_title).presence
        [page_title, application_identity.app_name].compact.join(" | ")
      end

      sig { returns(String) }
      def canonical_url
        application_identity.canonical_url(request.path)
      end

      sig { params(key: T.any(String, Symbol), options: Object).returns(String) }
      def application_translate(key, **options)
        translation = I18n.backend.translate(application_identity.default_locale, key, **options)
        return translation if translation.is_a?(String)

        Kernel.raise TypeError, "application translation must be a string: #{key}"
      end

      sig do
        params(
          id: String,
          title: String,
          close_label: String,
          description: T.nilable(String),
          actions: T.nilable(String),
          dialog_data: T::Hash[Symbol, Object],
          block: T.proc.returns(String)
        ).returns(ActiveSupport::SafeBuffer)
      end
      def with_modal(id:, title:, close_label:, description: nil, actions: nil, dialog_data: {}, &block)
        unless id.match?(/\A[a-z][a-z0-9_-]*\z/)
          Kernel.raise ArgumentError, "modal id must be a lowercase DOM id"
        end
        Kernel.raise ArgumentError, "modal title must not be empty" if title.strip.empty?
        Kernel.raise ArgumentError, "modal close label must not be empty" if close_label.strip.empty?

        title_id = "#{id}-title"
        description_id = "#{id}-description"
        modal_content = [tag.h2(title, id: title_id, class: "text-lg font-bold leading-[1.5]")]
        if description.present?
          modal_content << tag.p(description, id: description_id, class: "mt-2 text-base-content/70")
        end
        modal_content << capture(&block)
        modal_content << tag.div(actions, class: "modal-action") if actions.present?

        box = tag.div(safe_join(modal_content), class: "modal-box")
        backdrop = tag.form(method: "dialog", class: "modal-backdrop") do
          tag.button(close_label, type: "submit")
        end
        aria = { labelledby: title_id }
        aria[:describedby] = description_id if description.present?
        tag.dialog(safe_join([box, backdrop]), id:, class: "modal", data: dialog_data, aria:)
      end

      sig do
        params(
          tabs: T::Array[Tab],
          size: T.nilable(Symbol),
          block: T.proc.returns(String)
        ).returns(ActiveSupport::SafeBuffer)
      end
      def with_tab(tabs:, size: nil, &block)
        unless size.nil? || %i[xs sm md lg xl].include?(size)
          Kernel.raise ArgumentError, "tab size must be a daisyUI tab size"
        end

        matches = tabs.each_with_index.filter_map do |tab, index|
          path = tab.path
          Kernel.raise ArgumentError, "tab path must not be empty" if path.empty?

          predicate = tab.is_active
          active = if predicate.nil?
            request.path.start_with?(path)
          elsif predicate.lambda?
            predicate.call
          else
            Kernel.raise ArgumentError, "tab is_active must be a lambda"
          end
          { index:, path: } if active
        end

        Kernel.raise ArgumentError, "exactly one active tab is required" if matches.empty?

        longest_path_length = T.must(matches.map { |match| match.fetch(:path).length }.max)
        longest_matches = matches.select { |match| match.fetch(:path).length == longest_path_length }
        Kernel.raise ArgumentError, "active tabs must have one longest path" unless longest_matches.one?

        active_index = T.must(longest_matches.first).fetch(:index)
        tab_content = capture(&block)
        items = tabs.each_with_index.flat_map do |tab, index|
          active = index == active_index
          link = link_to tab.name, tab.path, role: "tab",
            class: class_names("tab", "tab-active": active, "z-10": active),
            aria: { selected: active, current: ("page" if active) }
          next [link] unless active

          [link, tag.div(tab_content, role: "tabpanel",
            class: "tab-content sticky left-0 max-w-[100cqw] [contain:inline-size] bg-base-100 border-base-300 p-3")]
        end

        tablist = tag.div(safe_join(items), role: "tablist",
          class: class_names("tabs tabs-lift min-w-max", "tabs-#{size}" => size.present?))
        tag.div(tablist, class: "overflow-x-auto")
      end
    end
  RUBY

  create_file "test/helpers/application_helper_test.rb", <<~'RUBY', force: true
    require "test_helper"

    class ApplicationHelperTest < ActionView::TestCase
      include ApplicationHelper

      test "renders one accessible native dialog from captured body and actions" do
        capture_count = 0
        actions = capture { tag.button("Apply", type: "button") }
        html = with_modal(
          id: "example-modal",
          title: "Example",
          description: "Description",
          close_label: "Close",
          actions:,
          dialog_data: { controller_target: "dialog", action: "close->controller#close" }
        ) do
          capture_count += 1
          tag.p("Body")
        end
        fragment = Nokogiri::HTML5.fragment(html)
        dialog = T.must(fragment.at_css("dialog#example-modal.modal"))

        assert_equal 1, capture_count
        assert_equal "example-modal-title", dialog["aria-labelledby"]
        assert_equal "example-modal-description", dialog["aria-describedby"]
        assert_equal "dialog", dialog["data-controller-target"]
        assert_equal "close->controller#close", dialog["data-action"]
        assert_equal "Example", dialog.at_css(".modal-box > h2#example-modal-title").text
        assert_equal "Description", dialog.at_css(".modal-box > p#example-modal-description").text
        assert_equal "Body", dialog.at_css(".modal-box > p:not([id])").text
        assert_equal "Apply", dialog.at_css(".modal-action > button").text
        assert_equal "dialog", dialog.at_css("form.modal-backdrop")["method"]
        assert_equal "Close", dialog.at_css("form.modal-backdrop > button[type=submit]").text
      end

      test "omits optional modal description and actions" do
        html = with_modal(id: "simple-modal", title: "Simple", close_label: "Close") { tag.p("Body") }
        dialog = T.must(Nokogiri::HTML5.fragment(html).at_css("dialog#simple-modal"))

        assert_nil dialog["aria-describedby"]
        assert_nil dialog.at_css("[id=simple-modal-description]")
        assert_nil dialog.at_css(".modal-action")
      end

      test "rejects invalid modal identifiers and empty labels" do
        assert_raises(ArgumentError) { with_modal(id: "Invalid Modal", title: "Title", close_label: "Close") { "body" } }
        assert_raises(ArgumentError) { with_modal(id: "valid-modal", title: " ", close_label: "Close") { "body" } }
        assert_raises(ArgumentError) { with_modal(id: "valid-modal", title: "Title", close_label: " ") { "body" } }
      end

      test "selects the longest matching path and captures content once" do
        request.path = "/account/siwe_identities/1/edit"
        capture_count = 0

        html = with_tab(tabs: [
          ApplicationHelper::Tab.new(name: "Account", path: "/account"),
          ApplicationHelper::Tab.new(name: "Wallets", path: "/account/siwe_identities")
        ]) do
          capture_count += 1
          tag.p("Tab content")
        end
        fragment = Nokogiri::HTML5.fragment(html)

        assert_equal 1, capture_count
        assert_equal 1, fragment.css(".overflow-x-auto > .tabs.tabs-lift.min-w-max").size
        assert_equal 1, fragment.css(".tabs.tabs-lift > .tab-content").size
        assert_includes fragment.at_css("[role=tabpanel]")["class"].split, "sticky"
        assert_includes fragment.at_css("[role=tabpanel]")["class"].split, "left-0"
        assert_includes fragment.at_css("[role=tabpanel]")["class"].split, "max-w-[100cqw]"
        assert_includes fragment.at_css("[role=tabpanel]")["class"].split, "[contain:inline-size]"
        assert_equal "Tab content", fragment.at_css(".tab-active + .tab-content p").text
        assert_equal "/account/siwe_identities", fragment.at_css(".tab-active")["href"]
        assert_includes fragment.at_css(".tab-active")["class"].split, "z-10"
        refute_includes fragment.at_css(".tab:not(.tab-active)")["class"].split, "z-10"
        assert_equal "true", fragment.at_css(".tab-active")["aria-selected"]
        assert_equal "page", fragment.at_css(".tab-active")["aria-current"]
        assert_equal ["false", "true"], fragment.css(".tab").pluck("aria-selected")
      end

      test "uses an explicit lambda instead of path matching" do
        request.path = "/account"
        html = with_tab(tabs: [
          ApplicationHelper::Tab.new(name: "Account", path: "/account", is_active: -> { false }),
          ApplicationHelper::Tab.new(name: "Dynamic", path: "/elsewhere", is_active: -> { true })
        ]) { tag.p("Tab content") }

        assert_equal "/elsewhere", Nokogiri::HTML5.fragment(html).at_css(".tab-active")["href"]
      end

      test "rejects no match and equally long active paths" do
        request.path = "/unmatched"
        assert_raises(ArgumentError) do
          with_tab(tabs: [ApplicationHelper::Tab.new(name: "Account", path: "/account")]) { "content" }
        end

        assert_raises(ArgumentError) do
          with_tab(tabs: [
            ApplicationHelper::Tab.new(name: "First", path: "/first", is_active: -> { true }),
            ApplicationHelper::Tab.new(name: "Other", path: "/other", is_active: -> { true })
          ]) { "content" }
        end
      end

      test "rejects empty paths and active predicates other than lambdas" do
        assert_raises(ArgumentError) do
          with_tab(tabs: [ApplicationHelper::Tab.new(name: "Empty", path: "")]) { "content" }
        end
        assert_raises(ArgumentError) do
          with_tab(tabs: [
            ApplicationHelper::Tab.new(name: "Proc", path: "/proc", is_active: proc { true })
          ]) { "content" }
        end
      end

      test "adds an optional daisyUI size modifier" do
        request.path = "/compact"
        tab = ApplicationHelper::Tab.new(name: "Compact", path: "/compact")
        html = with_tab(tabs: [tab], size: :sm) { "content" }

        assert_includes Nokogiri::HTML5.fragment(html).at_css("[role=tablist]")["class"].split, "tabs-sm"
        assert_raises(ArgumentError) do
          with_tab(tabs: [tab], size: :compact) { "content" }
        end
      end
    end
  RUBY

  route 'root "home#index"'
  route "resource :account, only: :show"

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

  create_file "app/views/layouts/_with_menu.html.erb", <<~ERB, force: true
    <% content_for :content, flush: true do %>
      <div class="mx-auto grid w-full max-w-6xl gap-6 px-5 py-8 min-[961px]:grid-cols-[220px_minmax(0,1fr)] min-[961px]:py-12" data-layout="with-menu">
        <aside class="h-fit"><%= yield :with_menu_navigation %></aside>
        <div class="min-w-0 [container-type:inline-size]">
          <h1 class="mb-6 text-2xl font-bold leading-[1.5]"><%= content_for(:page_title) %></h1>
          <%= yield %>
        </div>
      </div>
    <% end %>
    <%= render template: "layouts/application" %>
  ERB

  create_file "app/views/shared/_account_navigation.html.erb", account_navigation_items, force: true
  create_file "app/views/layouts/_account_shell.html.erb", <<~ERB, force: true
    <% content_for :with_menu_navigation, flush: true do %>
      <nav aria-label="<%= t('navigation.account_menu') %>">
        <ul class="menu w-full rounded-box bg-base-100">
          <li class="menu-title"><span><%= t("navigation.dashboard") %></span></li>
          <%= render "shared/account_navigation" %>
        </ul>
      </nav>
    <% end %>
    <%= render layout: "layouts/with_menu" do %>
      <%= yield %>
    <% end %>
  ERB
  create_file "app/views/layouts/account.html.erb", <<~ERB, force: true
    <%= render layout: "layouts/account_shell" do %>
      <%= yield %>
    <% end %>
  ERB

  account_settings_tabs = [
    'ApplicationHelper::Tab.new(name: t("passkeys.title"), path: account_passkeys_path)',
    ('ApplicationHelper::Tab.new(name: t("siwe.identities.title"), path: account_siwe_identities_path)' if siwe_enabled),
    'ApplicationHelper::Tab.new(name: t("accounts.delete.title"), path: delete_account_path)'
  ].compact.join(",\n          ")
  create_file "app/views/layouts/account_settings.html.erb", <<~ERB, force: true
      <% content_for :account_settings_content, flush: true do %>
        <nav aria-label="<%= t('navigation.account_settings') %>">
          <%= with_tab(tabs: [
          #{account_settings_tabs}
          ]) do %>
            <%= yield %>
          <% end %>
        </nav>
      <% end %>
      <%= render layout: "layouts/account_shell" do %>
        <%= yield :account_settings_content %>
      <% end %>
    ERB

  create_file "app/views/shared/_admin_navigation.html.erb", admin_navigation_items, force: true
  create_file "app/views/layouts/admin.html.erb", <<~ERB, force: true
    <% content_for :with_menu_navigation, flush: true do %>
      <nav aria-label="<%= application_translate('navigation.admin_menu') %>">
        <ul class="menu w-full rounded-box bg-base-100">
          <li class="menu-title"><span><%= application_translate("navigation.admin") %></span></li>
          <%= render "shared/admin_navigation" %>
        </ul>
      </nav>
    <% end %>
    <%= render layout: "layouts/with_menu" do %>
      <%= content_for?(:admin_content) ? yield(:admin_content) : yield %>
    <% end %>
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
                <%= render "shared/account_navigation" %>
              <% end %>
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
    <% if flash[:credential_risk] %>
      <div class="mx-auto w-full max-w-[820px] px-5 pt-5">
        <div class="alert alert-warning alert-soft" role="alert">
          <span>
            <%= t("credential_risk.warning") %>
            <%= link_to t("credential_risk.add_login_method"), application_routes.account_passkeys_path, class: "link whitespace-nowrap" %>
          </span>
        </div>
      </div>
    <% end %>
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
    <% content_for :page_title, t("accounts.show.title") %>
    <div class="space-y-6">
      <header>
        <p class="text-sm text-neutral">#{account_page_description}</p>
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

  account_delete_siwe = if siwe_enabled
    <<~'ERB'
      <% if current_user.siwe_identities.exists? %>
        <div data-controller="siwe-sign-in"
             data-siwe-sign-in-mode-value="destroy"
             data-siwe-sign-in-challenge-url-value="<%= account_siwe_credential_destruction_challenge_path %>"
             data-siwe-sign-in-verify-url-value="<%= account_siwe_credential_destruction_path %>"
             data-siwe-sign-in-target-id-value="<%= current_user.id %>"
             data-siwe-sign-in-destruction-action-value="delete_account"
             data-siwe-sign-in-wallet-missing-value="<%= t('siwe.errors.wallet_missing') %>"
             data-siwe-sign-in-challenge-error-value="<%= t('siwe.errors.challenge') %>"
             data-siwe-sign-in-verification-error-value="<%= t('siwe.errors.verification') %>">
          <button type="button" class="btn btn-error btn-rapid" data-action="siwe-sign-in#authenticate"><%= t("accounts.delete.with_wallet") %></button>
          <div class="alert alert-error mt-4 hidden" role="alert" data-siwe-sign-in-target="error"></div>
        </div>
      <% end %>
    ERB
  else
    ""
  end
  create_file "app/views/accounts/delete.html.erb", <<~ERB, force: true
    <% content_for :page_title, t("accounts.delete.title") %>

    <section class="card card-border border-error bg-base-100 shadow-none">
      <div class="card-body">
        <p class="text-base-content/70"><%= t("accounts.delete.description") %></p>
        <div class="card-actions flex-wrap justify-end">
          <%= link_to t("common.back"), account_path, class: "btn btn-rapid" %>
          <% if current_user.passkey_credentials.exists? %>
            <div data-controller="passkey"
                 data-passkey-ceremony-value="get"
                 data-passkey-options-url-value="<%= account_passkey_credential_destruction_options_path %>"
                 data-passkey-verify-url-value="<%= account_passkey_credential_destruction_path %>"
                 data-passkey-target-id-value="<%= current_user.id %>"
                 data-passkey-destruction-action-value="delete_account"
                 data-passkey-unsupported-value="<%= t('passkeys.errors.unsupported') %>"
                 data-passkey-failed-value="<%= t('passkeys.errors.verification') %>">
              <button type="button" class="btn btn-error btn-rapid" data-action="passkey#authenticate"><%= t("accounts.delete.with_passkey") %></button>
              <div class="alert alert-error mt-4 hidden" role="alert" data-passkey-target="error"></div>
            </div>
          <% end %>
    #{account_delete_siwe.lines.map { |line| "      #{line}" }.join}    </div>
      </div>
    </section>
  ERB

  configure_devise_views

  generated_profile_assertion = if display_name_enabled && screen_name_enabled
    <<~RUBY
      assert_predicate profile, :persisted?
      assert_match(/\\A[a-z0-9_]+\\z/, profile.screen_name)
      assert_equal profile.screen_name.camelize, profile.display_name
    RUBY
  elsif screen_name_enabled
    <<~RUBY
      assert_predicate profile, :persisted?
      assert_match(/\\A[a-z0-9_]+\\z/, profile.screen_name)
    RUBY
  elsif display_name_enabled
    <<~RUBY
      assert_predicate profile, :persisted?
      assert_predicate profile.display_name, :present?
    RUBY
  else
    ""
  end
  generated_profile_assertion = generated_profile_assertion.lines.map { |line| "      #{line}" }.join
  profile_binding = profile_enabled ? "      profile = T.must(user.profile)\n" : ""
  profile_setup = if display_name_enabled || screen_name_enabled
    attributes = []
    attributes << 'screen_name: "sample_user"' if screen_name_enabled
    attributes << 'display_name: "Sample User"' if display_name_enabled
    "      profile.update!(#{attributes.join(', ')})\n"
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
        assert_select '[data-controller="image-crop"]', count: 1
        assert_select '[data-controller="image-crop"][data-image-crop-aspect-ratio-value="1"][data-image-crop-output-width-value="512"][data-image-crop-output-height-value="512"]', count: 1
        assert_select 'form[action=?] fieldset.fieldset.min-w-0.grid-cols-1 input.file-input.min-w-0[name="profile[avatar_upload]"][accept="image/jpeg,image/png,image/webp"][data-image-crop-target="input"]', profile_path, count: 1
        assert_select 'form[action=?] fieldset.fieldset p.label > span.min-w-0.whitespace-normal', profile_path, text: I18n.t("profiles.avatar_hint"), count: 1
        assert_select 'form[action=?] .avatar svg[width="64"][height="64"]', profile_path, count: 1
        assert_select 'form[action=?] dialog', profile_path, count: 0
        assert_select 'dialog#avatar-crop-modal.modal[aria-labelledby="avatar-crop-modal-title"][aria-describedby="avatar-crop-modal-description"]', count: 1 do
          assert_select '.modal-box > h2#avatar-crop-modal-title', text: I18n.t("profiles.avatar_crop.title"), count: 1
          assert_select '.modal-action button[data-action="image-crop#apply"]', text: I18n.t("profiles.avatar_crop.apply"), count: 1
          assert_select 'form.modal-backdrop[method="dialog"]', count: 1
        end
        assert_select 'form[action=?]', profile_avatar_path, count: 0
      RUBY
    end
    update_assertion = if screen_name_enabled
      <<~RUBY
        patch profile_url, params: { profile: { screen_name: 'updated_user' } }
        assert_redirected_to profile_url
        assert_equal 'updated_user', profile.reload.screen_name
      RUBY
    elsif display_name_enabled
      <<~RUBY
        patch profile_url, params: { profile: { display_name: 'Updated User' } }
        assert_redirected_to profile_url
        assert_equal 'Updated User', profile.reload.display_name
      RUBY
    else
      ""
    end
    <<~RUBY
      get profile_url
      assert_response :success
      assert_select '[data-layout="with-menu"] .list > .list-row', count: #{profile_features.length}
      assert_select 'a[href=?]', edit_profile_path, text: I18n.t("profiles.edit"), count: 1
      #{avatar_enabled ? "assert_select '.list .avatar svg[width=\"64\"][height=\"64\"]', count: 1\n      assert_select '.avatar-placeholder', count: 0" : ""}

      get edit_profile_url
      assert_response :success
      #{form_assertions.join}#{update_assertion}
      #{if avatar_enabled
          <<~RUBY
            patch profile_url, params: { profile: { avatar_upload: AvatarTestImage.upload } }
            assert_redirected_to profile_url
            assert_predicate profile.reload.avatar, :attached?
            get edit_profile_url
            assert_select 'form[action=?] [data-image-crop-target="currentPreview"] img[width="64"][height="64"]', profile_path, count: 1
            assert_select 'form[action=?][method="post"]', profile_avatar_path, count: 1 do
              assert_select 'input[name="_method"][value="delete"]', count: 1
              assert_select 'button.btn.btn-outline.btn-error[data-turbo-confirm]', text: I18n.t("profiles.avatar_delete"), count: 1
            end

            original_blob = profile.avatar.blob
            patch profile_url, params: { profile: { avatar_upload: AvatarTestImage.corrupt_png_upload } }
            assert_response :unprocessable_content
            error_text = I18n.t("activerecord.errors.models.profile.attributes.avatar_upload.undecodable")
            assert_select '.alert.alert-error[role="alert"]', text: /\#{Regexp.escape(error_text)}/, count: 1
            assert_equal original_blob, profile.reload.avatar.blob

            patch profile_url, params: { profile: { avatar_upload: AvatarTestImage.upload(width: 96, height: 72) } }
            assert_response :unprocessable_content
            square_error = I18n.t("activerecord.errors.models.profile.attributes.avatar_upload.not_square")
            assert_select '.alert.alert-error[role="alert"]', text: /\#{Regexp.escape(square_error)}/, count: 1
            assert_equal original_blob, profile.reload.avatar.blob

            delete profile_avatar_url
            assert_redirected_to profile_url
            assert_not profile.reload.avatar.attached?
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
            app/helpers/admin/job_operations_helper.rb
            app/policies/job_operation_policy.rb
            app/views/layouts/mission_control/jobs/application.html.erb
            app/views/layouts/mission_control/jobs/_navigation.html.erb
            app/views/mission_control/jobs/queues/index.html.erb
            app/views/mission_control/jobs/jobs/index.html.erb
            app/views/mission_control/jobs/jobs/show.html.erb
            app/views/mission_control/jobs/recurring_tasks/index.html.erb
            app/views/mission_control/jobs/workers/index.html.erb
            app/views/mission_control/jobs/shared/_pagination_toolbar.html.erb
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
    production_worker_assertion = if dokploy_enabled
      expected_workers = solid_queue_enabled ? 1 : 0
      %(assert_equal #{expected_workers}, Rails.root.join("Procfile.prod").read.lines.count { |line| line.start_with?("worker:") })
    else
      %(assert_not Rails.root.join("Procfile.prod").exist?)
    end
    solid_queue_cleanup_assertion = if solid_queue_enabled
      <<~RUBY
        recurring = YAML.safe_load_file(Rails.root.join("config/recurring.yml"), aliases: true)
          .fetch("production").fetch("clear_solid_queue_finished_jobs")
        assert_equal "SolidQueue::Job.clear_finished_in_batches(sleep_between_batches: 0.3)", recurring.fetch("command")
        assert_equal "every hour at minute 12", recurring.fetch("schedule")
        #{production_worker_assertion}
      RUBY
    else
      <<~RUBY
        assert_not Rails.root.join("config/recurring.yml").exist?
        #{production_worker_assertion}
      RUBY
    end
    <<~RUBY

        test "does not expose Mission Control Jobs when the feature is disabled" do
          assert_not_respond_to Rails.application.routes.url_helpers, :admin_jobs_path
          %w[
            config/initializers/mission_control_jobs.rb
            app/controllers/admin/job_operations_controller.rb
            app/helpers/admin/job_operations_helper.rb
            app/policies/job_operation_policy.rb
            app/views/layouts/mission_control/jobs/application.html.erb
            app/views/layouts/mission_control/jobs/_navigation.html.erb
            app/views/mission_control/jobs/queues/index.html.erb
            app/views/mission_control/jobs/jobs/index.html.erb
            app/views/mission_control/jobs/jobs/show.html.erb
            app/views/mission_control/jobs/recurring_tasks/index.html.erb
            app/views/mission_control/jobs/workers/index.html.erb
            app/views/mission_control/jobs/shared/_pagination_toolbar.html.erb
            config/locales/job_operations.ja.yml
            config/locales/job_operations.en.yml
            docs/job_operations.md
            test/policies/job_operation_policy_test.rb
            test/controllers/admin/job_operations_controller_test.rb
            test/models/solid_queue_cleanup_test.rb
          ].each { |path| assert_not Rails.root.join(path).exist?, path }
          assert_no_match(/gem ["']mission_control-jobs["']/, Rails.root.join("Gemfile").read)
          #{solid_queue_cleanup_assertion.lines.map { |line| "          #{line}" }.join}
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

  default_pages_test = <<~RUBY
    require "test_helper"

    class DefaultPagesTest < ActionDispatch::IntegrationTest
      include Devise::Test::IntegrationHelpers

      test "renders public and passwordless authentication pages" do
        get root_url
        assert_response :success
        assert_select 'header a[href=?]', new_user_session_path, count: 2
        assert_select 'header a[href=?]', new_user_registration_path, count: 2

        {
          new_user_session_url => I18n.t("authentication.sign_in_title"),
          new_user_registration_url => I18n.t("authentication.sign_up_title")
        }.each do |url, title|
          get url
          assert_response :success
          assert_select "h1", text: title, count: 1
          assert_select '[data-controller="passkey"]', count: 1
          assert_select 'input[type="password"]', count: 0
          assert_select 'input[name*="login_id"]', count: 0
        end
      end

      test "protects account pages and renders passkey settings" do
        get account_url
        assert_redirected_to new_user_session_url

        user = User.create!
        user.passkey_credentials.create!(
          name: "Primary",
          webauthn_id: "generated-default-pages-credential",
          public_key: "test-public-key",
          sign_count: 0,
          transports: ["internal"],
          backup_eligible: true,
          backup_state: false
        )
    #{profile_binding}#{generated_profile_assertion}#{profile_setup}      user.grant_role!(:admin)
        sign_in user

        get account_url
        assert_response :success
        assert_select 'nav[aria-label=?] a.menu-active[href=?]', I18n.t("navigation.account_menu"), account_path, count: 1

        get account_passkeys_url
        assert_response :success
        assert_select '.tab-active[href=?]', account_passkeys_path, count: 1
        assert_select 'ul.list > li.list-row', count: 1
        assert_select 'input[type="password"]', count: 0

        get delete_account_url
        assert_redirected_to account_url
      end
    #{job_operations_route_test}#{maintenance_route_test}
    end
  RUBY

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
  authentication_callback = "  before_action :authenticate_user!\n"
  account_user = "current_user"

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
      extend T::Sig

      belongs_to :user

      validates :browser_id, :endpoint, :p256dh, :auth, presence: true
      validates :browser_id, :endpoint, uniqueness: true
      validates :endpoint, format: { with: %r{\\Ahttps://[^\\s]+\\z} }

      sig { params(user: User, attributes: T::Hash[Symbol, String]).returns(PushSubscription) }
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
      extend T::Sig

      Error = Class.new(StandardError)

      sig { returns(String) }
      attr_reader :public_key

      sig { returns(String) }
      attr_reader :private_key

      sig { returns(String) }
      attr_reader :subject

      sig { returns(VapidConfiguration) }
      def self.fetch!
        new(
          public_key: ENV.fetch("VAPID_PUBLIC_KEY"),
          private_key: ENV.fetch("VAPID_PRIVATE_KEY"),
          subject: ENV.fetch("VAPID_SUBJECT")
        )
      rescue KeyError => error
        raise Error, "Web Push environment is incomplete: \#{error.key}"
      end

      sig { params(public_key: String, private_key: String, subject: String).void }
      def initialize(public_key:, private_key:, subject:)
        @public_key = T.let(public_key.presence || raise(Error, "VAPID_PUBLIC_KEY is blank"), String)
        @private_key = T.let(private_key.presence || raise(Error, "VAPID_PRIVATE_KEY is blank"), String)
        @subject = T.let(subject.presence || raise(Error, "VAPID_SUBJECT is blank"), String)
        uri = URI.parse(@subject)
        raise Error, "VAPID_SUBJECT must use mailto or https" unless %w[mailto https].include?(uri.scheme)
      rescue URI::InvalidURIError => error
        raise Error, "VAPID_SUBJECT is invalid: \#{error.message}"
      end

      sig { returns(T::Hash[Symbol, String]) }
      def to_h
        { subject:, public_key:, private_key: }
      end
    end
  RUBY

  create_file "app/jobs/push_notification_job.rb", <<~RUBY, force: true
    class PushNotificationJob < ApplicationJob
      extend T::Sig

      queue_as :default

      retry_on WebPush::TooManyRequests, WebPush::PushServiceError,
        Net::OpenTimeout, Net::ReadTimeout, Timeout::Error,
        wait: :polynomially_longer, attempts: 5

      sig do
        params(
          subscription_id: Integer,
          expected_user_id: Integer,
          title: String,
          body: String,
          path: String,
          tag: T.nilable(String),
          icon: String,
          ttl: Integer
        ).void
      end
      def perform(subscription_id, expected_user_id, title, body, path, tag, icon, ttl)
        subscription = PushSubscription.find_by(id: subscription_id, user_id: expected_user_id)
        return unless subscription

        payload = PushNotificationPayload.new(title:, body:, path:, tag:, icon:)
        WebPush.payload_send(
          endpoint: subscription.endpoint,
          message: payload.to_json,
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

  create_file "app/services/push_notification_payload.rb", <<~RUBY, force: true
    class PushNotificationPayload < T::Struct
      extend T::Sig

      const :title, String
      const :body, String
      const :path, String
      const :tag, T.nilable(String)
      const :icon, String

      sig { params(_state: T.nilable(JSON::State)).returns(String) }
      def to_json(_state = nil)
        data = T.let({ path: }, T::Hash[Symbol, String])
        options = T.let(
          { body:, icon:, data: },
          T::Hash[Symbol, T.any(String, T::Hash[Symbol, String])]
        )
        options[:tag] = T.must(tag) unless tag.nil?
        JSON.generate(title:, options:)
      end
    end
  RUBY

  create_file "app/services/push_notifier.rb", <<~RUBY, force: true
    class PushNotifier
      extend T::Sig

      DEFAULT_TTL = 86_400

      sig do
        params(
          user: T.nilable(User),
          title: String,
          body: String,
          path: String,
          tag: T.nilable(String),
          icon: String,
          ttl: Integer
        ).void
      end
      def self.deliver_later(user:, title:, body:, path:, tag: nil, icon: "/icon.png", ttl: DEFAULT_TTL)
        raise ArgumentError, "user must be persisted" unless user&.persisted?
        raise ArgumentError, "title is required" if title.blank?
        raise ArgumentError, "body is required" if body.blank?
        raise ArgumentError, "path must be a same-origin absolute path" unless path.start_with?("/") && !path.start_with?("//")
        raise ArgumentError, "ttl must be positive" unless ttl.to_i.positive?

        VapidConfiguration.fetch!
        user.push_subscriptions.find_each do |subscription|
          PushNotificationJob.perform_later(
            subscription.id,
            user.id,
            title,
            body,
            path,
            tag,
            icon,
            ttl.to_i
          )
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
      extend T::Sig

    #{authentication_callback}  rate_limit to: 5, within: 1.minute, only: :test

      sig { void }
      def vapid_public_key
        response.set_header("Cache-Control", "no-store")
        render json: { public_key: VapidConfiguration.fetch!.public_key }
      rescue VapidConfiguration::Error
        render json: { error: I18n.t("web_push.errors.configuration") }, status: :service_unavailable
      end

      sig { void }
      def create
        PushSubscription.register!(user: account_user, attributes: subscription_params.to_h.symbolize_keys)
        head :no_content
      rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
        head :unprocessable_content
      end

      sig { void }
      def destroy
        account_user.push_subscriptions.find_by(browser_id: browser_id_param)&.destroy!
        head :no_content
      end

      sig { void }
      def test
        subscription = account_user.push_subscriptions.find_by(browser_id: browser_id_param)
        return head :not_found unless subscription

        VapidConfiguration.fetch!
        PushNotificationJob.perform_later(
          subscription.id,
          account_user.id,
          I18n.t("web_push.test.title"),
          I18n.t("web_push.test.body"),
          notification_path,
          "web-push-test",
          "/icon.png",
          PushNotifier::DEFAULT_TTL
        )
        head :accepted
      rescue VapidConfiguration::Error
        render json: { error: I18n.t("web_push.errors.configuration") }, status: :service_unavailable
      end

      private
        sig { returns(User) }
        def account_user
          T.must(#{account_user})
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
    <% content_for :page_title, t("web_push.page.title") %>
    <div class="space-y-6">
      <header>
        <p class="text-sm text-neutral"><%= t("web_push.page.description") %></p>
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
        captured = T.let(nil, T.nilable(T::Hash[Symbol, T.untyped]))
        with_vapid_env do
          with_payload_send(->(**options) { captured = options }) do
            PushNotificationJob.perform_now(*job_arguments(users(:one).id))
          end
        end

        delivered = T.must(captured)
        assert_equal @subscription.endpoint, delivered.fetch(:endpoint)
        assert_equal expected_payload.deep_stringify_keys, JSON.parse(delivered.fetch(:message))
        assert_equal 600, delivered.fetch(:ttl)
        assert_equal 5, delivered.fetch(:open_timeout)
        assert_equal 5, delivered.fetch(:read_timeout)
        assert_equal 5, delivered.fetch(:ssl_timeout)
        assert_equal "https://example.com", delivered.dig(:vapid, :subject)
      end

      test "does not deliver after subscription ownership changes" do
        called = T.let(false, T::Boolean)
        with_payload_send(->(**) { called = true }) do
          PushNotificationJob.perform_now(*job_arguments(users(:two).id))
        end

        assert_not called
      end

      test "removes expired subscriptions" do
        response = Struct.new(:body).new("")
        error = WebPush::ExpiredSubscription.new(response, "push.example.com")

        with_vapid_env do
          with_payload_send(->(**) { raise error }) do
            assert_difference("PushSubscription.count", -1) do
              PushNotificationJob.perform_now(*job_arguments(users(:one).id))
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
          T.must(singleton_class).define_method(:payload_send, T.must(original_method))
        end

        def job_arguments(user_id)
          [@subscription.id, user_id, "Title", "Body", "/account", nil, "/icon.png", 600]
        end

        def expected_payload
          { title: "Title", options: { body: "Body", icon: "/icon.png", data: { path: "/account" } } }
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
          T.must(original).each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
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
          T.must(original).each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
        end
    end
  RUBY

  controller_test_support = <<~RUBY
      include Devise::Test::IntegrationHelpers
      include ActiveJob::TestHelper

      setup do
        @user = users(:one)
        sign_in @user
        PushSubscriptionsController.cache_store.clear
        configure_vapid
      end
  RUBY
  create_file "test/controllers/push_subscriptions_controller_test.rb", <<~RUBY, force: true
    require "test_helper"

    class PushSubscriptionsControllerTest < ActionDispatch::IntegrationTest
    #{controller_test_support}
      teardown do
        @original_vapid.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
      end

      test "requires authentication" do
        sign_out @user
        get vapid_public_key_push_subscription_url

        assert_redirected_to new_user_session_url
        get notification_url
        assert_redirected_to new_user_session_url
      end

      test "renders the dedicated notification settings page" do
        get notification_url

        assert_response :success
        page_title = I18n.t("web_push.page.title")
        assert_select "h1", text: page_title, count: 1
        assert_select "title", text: "\#{page_title} | \#{Rails.configuration.x.application_identity.app_name}", count: 1
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
        "page" => { "title" => "通知", "description" => "このブラウザで受け取る通知を管理します。", "card_title" => "Web Push通知", "card_description" => "アプリからの更新を、このブラウザへ通知します。", "receive" => "通知を受け取る", "toggle_label" => "このブラウザのWeb Push通知を切り替える", "send_test" => "テスト通知を送信" },
        "client" => { "unsupported" => "このブラウザはWeb Pushに対応していません。", "test_failed" => "テスト通知を送信できませんでした。", "test_sent" => "テスト通知を送信しました。", "blocked" => "通知がブロックされています。ブラウザの設定から許可してください。", "off" => "このブラウザでは通知が無効です。", "unsubscribe_failed" => "Web Push購読を解除できませんでした。", "reconciled" => "VAPID鍵の変更に合わせて通知を再登録しました。", "on" => "このブラウザでは通知が有効です。", "denied" => "通知が許可されていません。ブラウザの設定を確認してください。", "enabled" => "このブラウザの通知を有効にしました。", "disabled" => "このブラウザの通知を無効にしました。", "public_key_failed" => "VAPID公開鍵を取得できませんでした。", "save_failed" => "Web Push購読を保存できませんでした。", "delete_failed" => "Web Push購読を削除できませんでした。", "csrf_missing" => "CSRF tokenが見つかりません。", "request_failed" => "Web Pushリクエストに失敗しました。", "operation_failed" => "Web Pushの処理に失敗しました。" }
      }
    },
    en: {
      "web_push" => {
        "errors" => { "configuration" => "The Web Push server configuration is incomplete." },
        "test" => { "title" => "Test notification", "body" => "Web Push is configured correctly." },
        "page" => { "title" => "Notifications", "description" => "Manage notifications received by this browser.", "card_title" => "Web Push notifications", "card_description" => "Receive application updates in this browser.", "receive" => "Receive notifications", "toggle_label" => "Toggle Web Push notifications for this browser", "send_test" => "Send test notification" },
        "client" => { "unsupported" => "This browser does not support Web Push.", "test_failed" => "Could not send the test notification.", "test_sent" => "The test notification was sent.", "blocked" => "Notifications are blocked. Allow them in your browser settings.", "off" => "Notifications are disabled in this browser.", "unsubscribe_failed" => "Could not remove the Web Push subscription.", "reconciled" => "Notifications were re-registered for the new VAPID key.", "on" => "Notifications are enabled in this browser.", "denied" => "Notifications are not allowed. Check your browser settings.", "enabled" => "Notifications were enabled for this browser.", "disabled" => "Notifications were disabled for this browser.", "public_key_failed" => "Could not obtain the VAPID public key.", "save_failed" => "Could not save the Web Push subscription.", "delete_failed" => "Could not delete the Web Push subscription.", "csrf_missing" => "The CSRF token was not found.", "request_failed" => "The Web Push request failed.", "operation_failed" => "The Web Push operation failed." }
      }
    }
  )
end

def install_solid_components
  if VALUES.fetch("active_job") == "solid_queue"
    generate "solid_queue:install"
    environment "config.active_job.queue_adapter = :solid_queue"
    environment "config.solid_queue.connects_to = { database: { writing: :queue } }", env: "development"
    environment "config.active_job.queue_adapter = :test", env: "test"
    append_to_file "config/puma.rb", "\nplugin :solid_queue if ENV.fetch(\"RAILS_ENV\", \"development\") == \"development\"\n"
  end
  generate "solid_cache:install" if VALUES.fetch("solid_cache") == "use"
  generate "solid_cable:install" if VALUES.fetch("action_cable") == "solid_cable"
end

def install_job_operations
  production_worker = if VALUES.fetch("deployment") == "dokploy"
    "Dokployでは既存の`worker: bin/jobs --mode async`がworker、dispatcher、schedulerを起動します。cleanup専用processは追加しません。"
  else
    "このテンプレートはproduction worker processを設定しません。利用環境に合わせてSolid Queue worker、dispatcher、schedulerの起動と監視を別途構成してください。"
  end
  authentication_route_bridge = ""

  environment "config.mission_control.jobs.adapters = [:solid_queue]"
  environment "config.solid_queue.connects_to = { database: { writing: :queue } }", env: "test"
  route 'mount MissionControl::Jobs::Engine, at: "/admin/jobs", as: :admin_jobs'

  create_file "config/initializers/mission_control_jobs.rb", <<~RUBY, force: true
    MissionControl::Jobs.base_controller_class = "Admin::JobOperationsController"
    MissionControl::Jobs.http_basic_auth_enabled = false
  RUBY

  create_file "app/policies/job_operation_policy.rb", <<~RUBY, force: true
    class JobOperationPolicy < ApplicationPolicy
      T::Sig::WithoutRuntime.sig { returns(T::Boolean) }
      def manage?
        admin?
      end
    end
  RUBY

  create_file "app/controllers/admin/job_operations_controller.rb", <<~RUBY, force: true
    module Admin
      class JobOperationsController < BaseController
        helper Admin::JobOperationsHelper

        before_action :authorize_job_operations!

    #{authentication_route_bridge.lines.map { |line| "    #{line}" }.join}    private
          def authorize_job_operations!
            authorize! :job_operation, to: :manage?
          end
      end
    end
  RUBY

  create_file "app/helpers/admin/job_operations_helper.rb", <<~'RUBY', force: true
    module Admin
      module JobOperationsHelper
        extend T::Sig

        JOB_STATUS_CLASSES = {
          "failed" => "badge-error",
          "blocked" => "badge-warning",
          "finished" => "badge-success",
          "scheduled" => "badge-info",
          "in_progress" => "badge-info"
        }.freeze

        sig { params(status: T.any(String, Symbol)).returns(String) }
        def job_operation_status_class(status)
          JOB_STATUS_CLASSES.fetch(status.to_s, "badge-neutral")
        end
      end
    end
  RUBY

  create_file "app/views/layouts/mission_control/jobs/application.html.erb", <<~'ERB', force: true
    <% content_for :javascript_importmap do %>
      <%= javascript_importmap_tags "application", importmap: MissionControl::Jobs.importmap %>
    <% end %>
    <% content_for :admin_content, flush: true do %>
      <%= render layout: "layouts/mission_control/jobs/navigation" do %>
        <div class="min-w-0 space-y-6" data-mission-control-jobs-root>
          <%= render "layouts/mission_control/jobs/application_selection" %>
          <%= render "layouts/mission_control/jobs/flash" %>
          <%= yield %>
        </div>
      <% end %>
    <% end %>
    <%= render template: "layouts/admin" %>
  ERB

  create_file "app/views/layouts/mission_control/jobs/_application_selection.html.erb", <<~'ERB', force: true
    <% if @application.servers.many? || selectable_applications.any? %>
      <section class="card card-border border-base-300 bg-base-100" aria-label="Application selection">
        <div class="card-body flex-row flex-wrap items-center justify-end gap-4 py-4">
          <div class="flex flex-wrap items-center justify-end gap-3">
            <% if @application.servers.many? %>
              <div role="tablist" class="tabs tabs-lift tabs-sm" aria-label="Servers">
                <% @application.servers.each do |server| %>
                  <%= link_to server.name, application_queues_path(@application, server_id: server),
                    role: "tab", class: class_names("tab", "tab-active": selected_server?(server)),
                    aria: { current: ("page" if selected_server?(server)) } %>
                <% end %>
              </div>
            <% end %>

            <% if selectable_applications.any? %>
              <div class="dropdown dropdown-end">
                <button type="button" tabindex="0" class="btn btn-sm">
                  <%= MissionControl::Jobs::Current.application.name %>
                </button>
                <ul tabindex="0" class="dropdown-content menu z-10 mt-2 w-52 rounded-box border border-base-300 bg-base-100 p-2 shadow">
                  <% selectable_applications.each do |application| %>
                    <li><%= link_to application.name, application_queues_path(application, server_id: nil) %></li>
                  <% end %>
                </ul>
              </div>
            <% else %>
              <span class="badge badge-outline"><%= MissionControl::Jobs::Current.application.name %></span>
            <% end %>
          </div>
        </div>
      </section>
    <% end %>
  ERB

  create_file "app/views/layouts/mission_control/jobs/_flash.html.erb", <<~'ERB', force: true
    <% flash.each do |name, message| %>
      <div class="alert <%= name.to_sym == :notice ? "alert-success" : "alert-error" %>" role="alert">
        <span><%= message %></span>
      </div>
    <% end %>
  ERB

  create_file "app/views/layouts/mission_control/jobs/_navigation.html.erb", <<~'ERB', force: true
    <% tabs = navigation_sections.map do |key, (label, url)|
         ApplicationHelper::Tab.new(name: label, path: url, is_active: -> { key == current_section })
       end %>
    <nav aria-label="Job operations sections">
      <%= with_tab(tabs:, size: :xs) do %>
        <%= yield %>
      <% end %>
    </nav>
  ERB

  create_file "app/views/mission_control/jobs/shared/_pagination_toolbar.html.erb", <<~'ERB', force: true
    <nav class="flex flex-wrap items-center justify-end gap-3" aria-label="pagination">
      <span class="text-sm text-base-content/70"><%= page.index %> / <%= page.pages_count || "..." %></span>
      <div class="join">
        <% if page.first? %>
          <span class="btn join-item btn-disabled" aria-disabled="true">Previous page</span>
        <% else %>
          <%= link_to "Previous page", url_for(page: page.previous_index, **filter_param), class: "btn join-item" %>
        <% end %>
        <% if page.last? %>
          <span class="btn join-item btn-disabled" aria-disabled="true">Next page</span>
        <% else %>
          <%= link_to "Next page", url_for(page: page.next_index, **filter_param), class: "btn join-item" %>
        <% end %>
      </div>
    </nav>
  ERB

  create_file "app/views/mission_control/jobs/queues/index.html.erb", <<~'ERB', force: true
    <% navigation(title: "Queues", section: :queues) %>
    <% content_for :page_title, "Queues" %>

    <% if @queues.empty? %>
      <div class="alert" role="status"><span>There are no queues.</span></div>
    <% else %>
      <div class="card card-border overflow-x-auto border-base-300 bg-base-100">
        <table class="table">
          <thead><tr><th>Queue</th><th>Pending jobs</th><th><span class="sr-only">Actions</span></th></tr></thead>
          <tbody>
            <% @queues.each do |queue| %>
              <tr>
                <td>
                  <div class="flex flex-wrap items-center gap-2">
                    <%= link_to queue.name, application_queue_path(@application, queue), class: "link link-hover font-semibold" %>
                    <% if queue.paused? %><span class="badge badge-warning">Paused</span><% end %>
                  </div>
                </td>
                <td><%= queue.size %></td>
                <td>
                  <% if queue_pausing_supported? %>
                    <div class="flex justify-end">
                      <% if queue.active? %>
                        <%= button_to "Pause", application_queue_pause_path(@application, queue.name), method: :post, class: "btn btn-sm btn-warning" %>
                      <% else %>
                        <%= button_to "Resume", application_queue_pause_path(@application, queue.name), method: :delete, class: "btn btn-sm" %>
                      <% end %>
                    </div>
                  <% end %>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>
    <% end %>
  ERB

  create_file "app/views/mission_control/jobs/queues/show.html.erb", <<~'ERB', force: true
    <% navigation(title: "Queue #{@queue.name}", section: :queues) %>
    <% content_for :page_title, @queue.name %>

    <header class="flex flex-wrap items-start justify-between gap-4">
      <div>
        <% if @queue.paused? %><span class="badge badge-warning">Paused</span><% end %>
        <p class="text-sm text-base-content/70"><%= pluralize @queue.size, "pending job" %></p>
      </div>
      <% if queue_pausing_supported? %>
        <% if @queue.active? %>
          <%= button_to "Pause", application_queue_pause_path(@application, @queue.name), method: :post, class: "btn btn-warning" %>
        <% else %>
          <%= button_to "Resume", application_queue_pause_path(@application, @queue.name), method: :delete, class: "btn" %>
        <% end %>
      <% end %>
    </header>

    <% if @jobs_page.empty? %>
      <div class="alert" role="status"><span>The queue is empty.</span></div>
    <% else %>
      <div class="card card-border overflow-x-auto border-base-300 bg-base-100">
        <table class="table">
          <thead><tr><th>Job</th><th>Arguments</th></tr></thead>
          <tbody>
            <% @jobs_page.records.each do |job| %>
              <tr>
                <td>
                  <%= link_to job_title(job), application_job_path(@application, job.job_id, filter: { queue_name: job.queue }), class: "link link-hover font-semibold" %>
                  <div class="text-sm text-base-content/70">Enqueued <%= time_distance_in_words_with_title(job.enqueued_at.to_datetime) %> ago</div>
                </td>
                <td class="font-mono text-sm"><%= job_arguments(job) if job.serialized_arguments.present? %></td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>
      <%= render "mission_control/jobs/shared/pagination_toolbar", page: @jobs_page, filter_param: {} %>
    <% end %>
  ERB

  create_file "app/views/mission_control/jobs/jobs/index.html.erb", <<~'ERB', force: true
    <% navigation(title: "#{jobs_status.titleize} jobs", section: "#{jobs_status}_jobs".to_sym) %>
    <% content_for :page_title, "#{jobs_status.titleize} jobs" %>

    <span class="badge <%= job_operation_status_class(jobs_status) %>"><%= jobs_status %></span>

    <% unless @jobs_page.empty? && !active_filters? %>
      <section class="card card-border border-base-300 bg-base-100" aria-label="Job filters">
        <div class="card-body">
          <%= form_for :filter, url: application_jobs_path(MissionControl::Jobs::Current.application, jobs_status), method: :get,
            html: { class: "grid gap-4 md:grid-cols-2 xl:grid-cols-4" },
            data: { controller: "form", action: "input->form#debouncedSubmit" } do |form| %>
            <fieldset class="fieldset">
              <%= form.label :job_class_name, class: "fieldset-legend" %>
              <%= form.text_field :job_class_name, value: @job_filters[:job_class_name], class: "input input-rapid w-full", list: "job-classes", placeholder: "Filter by job class...", autocomplete: "off" %>
            </fieldset>
            <fieldset class="fieldset">
              <%= form.label :queue_name, class: "fieldset-legend" %>
              <%= form.text_field :queue_name, value: @job_filters[:queue_name], class: "input input-rapid w-full", list: "queue-names", placeholder: "Filter by queue name...", autocomplete: "off" %>
            </fieldset>
            <% if jobs_status == "finished" %>
              <fieldset class="fieldset">
                <%= form.label :finished_at_start, class: "fieldset-legend" %>
                <%= form.datetime_field :finished_at_start, value: @job_filters[:finished_at]&.begin, class: "input input-rapid w-full" %>
              </fieldset>
              <fieldset class="fieldset">
                <%= form.label :finished_at_end, class: "fieldset-legend" %>
                <%= form.datetime_field :finished_at_end, value: @job_filters[:finished_at]&.end, class: "input input-rapid w-full" %>
              </fieldset>
            <% end %>
            <%= hidden_field_tag :server_id, MissionControl::Jobs::Current.server.id %>
            <datalist id="job-classes"><% @job_class_names.each do |name| %><option value="<%= name %>"></option><% end %></datalist>
            <datalist id="queue-names"><% @queue_names.each do |name| %><option value="<%= name %>"></option><% end %></datalist>
            <div class="card-actions items-end md:col-span-2 xl:col-span-4">
              <%= link_to "Clear filters", application_jobs_path(MissionControl::Jobs::Current.application, jobs_status, job_class_name: nil, queue_name: nil, finished_at: nil..nil), class: "btn" %>
            </div>
          <% end %>
        </div>
      </section>
    <% end %>

    <% if jobs_status.failed? && !@jobs_page.empty? %>
      <% target = active_filters? ? "selection" : "all" %>
      <div class="flex flex-wrap items-center justify-end gap-3">
        <% if active_filters? %><span class="text-sm text-base-content/70"><%= @jobs_count %> jobs found</span><% end %>
        <%= button_to "Discard #{target}", application_bulk_discards_path(@application, **jobs_filter_param), method: :post,
          disabled: @jobs_count == 0, class: "btn btn-error",
          form: { data: { turbo_confirm: "This will delete #{@jobs_count} jobs and can't be undone. Are you sure?" } } %>
        <%= button_to "Retry #{target}", application_bulk_retries_path(@application, **jobs_filter_param), method: :post,
          disabled: @jobs_count == 0, class: "btn btn-warning" %>
      </div>
    <% end %>

    <% if @jobs_page.empty? %>
      <div class="alert" role="status">
        <span><%= active_filters? ? "No #{jobs_status.dasherize} jobs found with the given filters." : "There are no #{jobs_status.dasherize} jobs #{blank_status_emoji(jobs_status)}" %></span>
      </div>
    <% else %>
      <div class="card card-border overflow-x-auto border-base-300 bg-base-100">
        <table class="table">
          <thead><tr><th>Job</th><% attribute_names_for_job_status(jobs_status).each do |attribute| %><th><%= attribute %></th><% end %></tr></thead>
          <tbody>
            <% @jobs_page.records.each do |job| %>
              <tr>
                <td>
                  <%= link_to job_title(job), application_job_path(@application, job.job_id), class: "link link-hover font-semibold" %>
                  <% if job.serialized_arguments.present? %><div class="font-mono text-sm"><%= job_arguments(job) %></div><% end %>
                  <div class="text-sm text-base-content/70">Enqueued <%= time_distance_in_words_with_title(job.enqueued_at.to_datetime) %> ago</div>
                </td>
                <% case jobs_status.to_s %>
                <% when "failed" %>
                  <td><%= link_to failed_job_error(job), application_job_path(@application, job.job_id, anchor: "error"), class: "link link-hover" %><div class="text-sm text-base-content/70"><%= time_distance_in_words_with_title(job.failed_at) %> ago</div></td>
                  <td><div class="flex justify-end gap-2"><%= button_to "Discard", application_job_discard_path(@application, job.job_id, params: jobs_filter_param), class: "btn btn-sm btn-error", form: { data: { turbo_confirm: "This will delete the job and can't be undone. Are you sure?" } } %><%= button_to "Retry", application_job_retry_path(@application, job.job_id, params: jobs_filter_param), class: "btn btn-sm btn-warning" %></div></td>
                <% when "blocked" %>
                  <td><%= link_to job.queue_name, application_queue_path(@application, job.queue), class: "link link-hover" %></td>
                  <td><div class="font-mono text-sm"><%= job.blocked_by %></div><div class="text-sm text-base-content/70"><%= job.blocked_until ? "Expires #{bidirectional_time_distance_in_words_with_title(job.blocked_until)}" : "" %></div></td>
                  <td><%= button_to "Run now", application_job_dispatch_path(@application, job.job_id), class: "btn btn-sm btn-warning" %></td>
                <% when "scheduled" %>
                  <td><%= link_to job.queue_name, application_queue_path(@application, job.queue), class: "link link-hover" %></td>
                  <td><%= bidirectional_time_distance_in_words_with_title(job.scheduled_at) %> <% if job_delayed?(job) %><span class="badge badge-error">delayed</span><% end %></td>
                  <td><div class="flex justify-end gap-2"><%= button_to "Run now", application_job_dispatch_path(@application, job.job_id), class: "btn btn-sm btn-warning" %><%= button_to "Discard", application_job_discard_path(@application, job.job_id), class: "btn btn-sm btn-error", form: { data: { turbo_confirm: "This will delete the job and can't be undone. Are you sure?" } } %></div></td>
                <% when "in_progress" %>
                  <td><%= link_to job.queue_name, application_queue_path(@application, job.queue), class: "link link-hover" %></td>
                  <td><% if job.worker_id %><%= link_to "worker #{job.worker_id}", application_worker_path(@application, job.worker_id), class: "link link-hover" %><% else %>—<% end %></td>
                  <td class="text-base-content/70"><%= job.started_at ? time_distance_in_words_with_title(job.started_at) : "(Finished)" %></td>
                <% when "finished" %>
                  <td><%= link_to job.queue_name, application_queue_path(@application, job.queue), class: "link link-hover" %></td>
                  <td class="text-base-content/70"><%= time_distance_in_words_with_title(job.finished_at) %> ago</td>
                <% end %>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>
      <%= render "mission_control/jobs/shared/pagination_toolbar", page: @jobs_page, filter_param: jobs_filter_param %>
    <% end %>
  ERB

  create_file "app/views/mission_control/jobs/jobs/show.html.erb", <<~'ERB', force: true
    <% navigation(title: "Job #{@job.job_id}", section: navigation_section_for_status(@job.status)) %>
    <% content_for :page_title, job_title(@job) %>

    <header class="flex flex-wrap items-start justify-between gap-4">
      <span class="badge <%= job_operation_status_class(@job.status) %>"><%= @job.status %></span>
      <div class="flex flex-wrap justify-end gap-2">
        <% if @job.failed? %>
          <%= button_to "Discard", application_job_discard_path(@application, @job.job_id, params: jobs_filter_param), class: "btn btn-error", form: { data: { turbo_confirm: "This will delete the job and can't be undone. Are you sure?" } } %>
          <%= button_to "Retry", application_job_retry_path(@application, @job.job_id, params: jobs_filter_param), class: "btn btn-warning" %>
        <% elsif @job.blocked? %>
          <%= button_to "Run now", application_job_dispatch_path(@application, @job.job_id), class: "btn btn-warning" %>
        <% elsif @job.scheduled? %>
          <%= button_to "Run now", application_job_dispatch_path(@application, @job.job_id), class: "btn btn-warning" %>
          <%= button_to "Discard", application_job_discard_path(@application, @job.job_id), class: "btn btn-error", form: { data: { turbo_confirm: "This will delete the job and can't be undone. Are you sure?" } } %>
        <% end %>
      </div>
    </header>

    <section class="card card-border overflow-x-auto border-base-300 bg-base-100" aria-labelledby="job-information">
      <div class="card-body p-0">
        <h2 id="job-information" class="sr-only leading-[1.5]">Job information</h2>
        <table class="table">
          <tbody>
            <tr><th>Arguments</th><td class="font-mono text-sm"><%= job_arguments(@job) %></td></tr>
            <tr><th>Job id</th><td class="break-all font-mono text-sm"><%= @job.job_id %></td></tr>
            <tr><th>Queue</th><td><%= link_to @job.queue_name, application_queue_path(@application, @job.queue), class: "badge badge-outline link link-hover" %></td></tr>
            <tr><th>Enqueued</th><td><%= time_distance_in_words_with_title(@job.enqueued_at.to_datetime) %> ago</td></tr>
            <% if @job.scheduled? %><tr><th>Scheduled</th><td><%= bidirectional_time_distance_in_words_with_title(@job.scheduled_at) %> <% if job_delayed?(@job) %><span class="badge badge-error">delayed</span><% end %></td></tr><% end %>
            <% if @job.failed? %><tr><th>Failed</th><td><%= time_distance_in_words_with_title(@job.failed_at) %> ago</td></tr><% end %>
            <% if @job.finished_at.present? %><tr><th>Finished</th><td><%= time_distance_in_words_with_title(@job.finished_at) %> ago</td></tr><tr><th>Duration</th><td><%= @job.duration.round(3) %> seconds</td></tr><% end %>
            <% if @job.worker_id.present? %><tr><th>Processed by</th><td><%= link_to "worker #{@job.worker_id}", application_worker_path(@application, @job.worker_id), class: "link link-hover" %></td></tr><% end %>
          </tbody>
        </table>
      </div>
    </section>

    <% if @job.failed? %>
      <section id="error" class="space-y-4" aria-labelledby="error-title">
        <h2 id="error-title" class="text-xl font-bold leading-[1.5]">Error information</h2>
        <div class="alert alert-error alert-vertical" role="alert">
          <div class="font-semibold"><%= @job.last_execution_error.error_class %></div>
          <p><%= @job.last_execution_error.try(:message) || @job.last_execution_error.inspect %></p>
        </div>
        <% if @server.backtrace_cleaner %>
          <div role="tablist" class="tabs tabs-box tabs-sm justify-end" aria-label="Backtrace detail">
            <%= link_to "Clean", application_job_path(@application, @job.job_id, clean_backtrace: true), role: "tab", class: class_names("tab", "tab-active": clean_backtrace?) %>
            <%= link_to "Full", application_job_path(@application, @job.job_id, clean_backtrace: false), role: "tab", class: class_names("tab", "tab-active": !clean_backtrace?) %>
          </div>
        <% end %>
        <div class="mockup-code overflow-x-auto"><pre data-prefix=""><code><%= failed_job_backtrace(@job, @server) %></code></pre></div>
      </section>
    <% end %>

    <details class="collapse collapse-arrow card card-border border-base-300 bg-base-100">
      <summary class="collapse-title text-lg font-semibold">Raw data</summary>
      <div class="collapse-content"><div class="mockup-code overflow-x-auto"><pre data-prefix=""><code><%= JSON.pretty_generate(@job.raw_data.without("backtrace")) %></code></pre></div></div>
    </details>
  ERB

  create_file "app/views/mission_control/jobs/recurring_tasks/index.html.erb", <<~'ERB', force: true
    <% navigation(title: "Recurring tasks", section: :recurring_tasks) %>
    <% content_for :page_title, "Recurring tasks" %>

    <% if @recurring_tasks.empty? %>
      <div class="alert" role="status"><span>There are no recurring tasks.</span></div>
    <% else %>
      <div class="card card-border overflow-x-auto border-base-300 bg-base-100">
        <table class="table">
          <thead><tr><th>Task</th><th>Job</th><th>Schedule</th><th>Last enqueued</th><th>Next</th><th><span class="sr-only">Actions</span></th></tr></thead>
          <tbody>
            <% @recurring_tasks.each do |task| %>
              <tr>
                <td><%= link_to task.id, application_recurring_task_path(@application, task.id), class: "link link-hover font-semibold" %></td>
                <td><% if task.job_class_name.present? %><%= task.job_class_name %><% if task.arguments.present? %><div class="font-mono text-sm"><%= task.arguments.join(",") %></div><% end %><% elsif task.command.present? %><div class="font-mono text-sm"><%= task.command %></div><% end %></td>
                <td><%= task.schedule %></td>
                <td class="text-base-content/70"><%= task.last_enqueued_at ? bidirectional_time_distance_in_words_with_title(task.last_enqueued_at) : "Never" %></td>
                <td class="text-base-content/70"><%= bidirectional_time_distance_in_words_with_title(task.next_time) %></td>
                <td><% if task.runnable? %><%= button_to "Run now", application_recurring_task_path(@application, task.id), class: "btn btn-sm btn-warning", method: :put %><% end %></td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>
    <% end %>
  ERB

  create_file "app/views/mission_control/jobs/recurring_tasks/show.html.erb", <<~'ERB', force: true
    <% navigation(title: @recurring_task.id, section: :recurring_tasks) %>
    <% content_for :page_title, @recurring_task.id %>

    <div class="flex justify-end">
      <% if @recurring_task.runnable? %><%= button_to "Run now", application_recurring_task_path(@application, @recurring_task.id), class: "btn btn-warning", method: :put %><% end %>
    </div>

    <section class="card card-border overflow-x-auto border-base-300 bg-base-100">
      <div class="card-body p-0"><table class="table"><tbody>
        <% if @recurring_task.job_class_name.present? %><tr><th>Job class</th><td><%= @recurring_task.job_class_name %></td></tr><tr><th>Arguments</th><td class="font-mono text-sm"><%= @recurring_task.arguments.join(",") %></td></tr><% elsif @recurring_task.command.present? %><tr><th>Command</th><td class="font-mono text-sm"><%= @recurring_task.command %></td></tr><% end %>
        <tr><th>Schedule</th><td><%= @recurring_task.schedule %></td></tr>
        <% if @recurring_task.queue_name.present? %><tr><th>Queue</th><td><%= @recurring_task.queue_name %></td></tr><% end %>
        <% if @recurring_task.priority.present? %><tr><th>Priority</th><td><%= @recurring_task.priority %></td></tr><% end %>
      </tbody></table></div>
    </section>

    <% if @jobs_page.empty? %>
      <div class="alert" role="status"><span>No jobs found for this recurring task.</span></div>
    <% else %>
      <section class="space-y-4"><h2 class="text-xl font-bold leading-[1.5]"><%= pluralize @recurring_task.jobs.count, "job" %></h2>
        <div class="card card-border overflow-x-auto border-base-300 bg-base-100"><table class="table"><thead><tr><th>Job</th><th>Arguments</th><th>Status</th></tr></thead><tbody>
          <% @jobs_page.records.each do |job| %><tr><td><%= link_to job_title(job), application_job_path(@application, job.job_id, filter: { queue_name: job.queue }), class: "link link-hover font-semibold" %><div class="text-sm text-base-content/70">Enqueued <%= time_distance_in_words_with_title(job.enqueued_at.to_datetime) %> ago</div></td><td class="font-mono text-sm"><%= job_arguments(job) if job.serialized_arguments.present? %></td><td><span class="badge <%= job_operation_status_class(job.status) %>"><%= job.status %></span></td></tr><% end %>
        </tbody></table></div>
        <%= render "mission_control/jobs/shared/pagination_toolbar", page: @jobs_page, filter_param: jobs_filter_param %>
      </section>
    <% end %>
  ERB

  create_file "app/views/mission_control/jobs/workers/index.html.erb", <<~'ERB', force: true
    <% navigation(title: "Workers", section: :workers) %>
    <% content_for :page_title, "Workers" %>

    <% if @workers_page.empty? %>
      <div class="alert" role="status"><span>There are no workers.</span></div>
    <% else %>
      <div class="card card-border overflow-x-auto border-base-300 bg-base-100"><table class="table"><thead><tr><th>Worker</th><th>Hostname</th><th>Jobs</th><th>Last heartbeat</th></tr></thead><tbody>
        <% @workers_page.records.each do |worker| %><tr><td><%= link_to "worker #{worker.id}", application_worker_path(@application, worker.id), class: "link link-hover font-semibold" %><br><%= worker.name %></td><td><%= worker.hostname %></td><td><% worker.jobs.each do |job| %><div><%= link_to job_title(job), application_job_path(@application, job.job_id), class: "link link-hover" %><% if job.serialized_arguments.present? %><div class="font-mono text-sm"><%= job_arguments(job) %></div><% end %></div><% end %></td><td class="text-base-content/70"><%= time_distance_in_words_with_title(worker.last_heartbeat_at) %> ago</td></tr><% end %>
      </tbody></table></div>
      <%= render "mission_control/jobs/shared/pagination_toolbar", page: @workers_page, filter_param: {} %>
    <% end %>
  ERB

  create_file "app/views/mission_control/jobs/workers/show.html.erb", <<~'ERB', force: true
    <% navigation(title: "Worker #{@worker.id}", section: :workers) %>
    <% content_for :page_title, "worker #{@worker.id}" %>

    <p class="text-base-content/70"><%= @worker.name %> · <%= @worker.hostname %></p>

    <details class="collapse collapse-arrow card card-border border-base-300 bg-base-100" open><summary class="collapse-title text-lg font-semibold">Configuration</summary><div class="collapse-content"><div class="mockup-code overflow-x-auto"><pre data-prefix=""><code><%= JSON.pretty_generate(@worker.configuration) %></code></pre></div></div></details>

    <% if @worker.jobs.empty? %>
      <div class="alert" role="status"><span>This worker is idle.</span></div>
    <% else %>
      <section class="space-y-4"><h2 class="text-xl font-bold leading-[1.5]">Running <%= pluralize @worker.jobs.size, "job" %></h2><div class="card card-border overflow-x-auto border-base-300 bg-base-100"><table class="table"><thead><tr><th>Job</th><th>Arguments</th><th>Status</th></tr></thead><tbody>
        <% @worker.jobs.each do |job| %><tr><td><%= link_to job_title(job), application_job_path(@application, job.job_id), class: "link link-hover font-semibold" %></td><td class="font-mono text-sm"><%= job_arguments(job) if job.serialized_arguments.present? %></td><td><span class="badge <%= job_operation_status_class(job.status) %>"><%= job.status %></span></td></tr><% end %>
      </tbody></table></div></section>
    <% end %>

    <details class="collapse collapse-arrow card card-border border-base-300 bg-base-100"><summary class="collapse-title text-lg font-semibold">Raw data</summary><div class="collapse-content"><div class="mockup-code overflow-x-auto"><pre data-prefix=""><code><%= JSON.pretty_generate(@worker.raw_data) %></code></pre></div></div></details>
  ERB

  create_locale_pair(
    "job_operations",
    ja: {
      "navigation" => { "job_operations" => "ジョブ運用" }
    },
    en: {
      "navigation" => { "job_operations" => "Job operations" }
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

    engineの英語label、route、操作契約はMission Control Jobs 1.1.0の公式実装を維持し、表示はhost application側のdaisyUI View overrideを使用します。Bulma stylesheetと専用CSSは読み込みません。

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

  controller_test_support = <<~RUBY
      include Devise::Test::IntegrationHelpers

      setup do
        @admin = User.create!
        @regular = User.create!
        @admin.grant_role!(:admin)
      end

      private
        def sign_in_as(user, _key = nil)
          sign_in user
        end
  RUBY
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

        assert_redirected_to new_user_session_url
      end

      test "denies regular users" do
        sign_in_as(@regular)

        get admin_jobs_url

        assert_response :forbidden
      end

      test "renders the console for admins inside the admin layout" do
        sign_in_as(@admin)

        get admin_jobs_url

        assert_response :success
        assert_select "[data-mission-control-jobs-root]", count: 1
        assert_select '[data-layout="with-menu"] > div > h1', text: "Queues", count: 1
        assert_select '[data-layout="with-menu"] > div > nav[aria-label="Job operations sections"] > .overflow-x-auto > [role="tablist"].tabs.tabs-lift.min-w-max', count: 1
        assert_select '[data-layout="with-menu"] > div > nav[aria-label="Job operations sections"] [role="tablist"] > .tab-content[role="tabpanel"]', count: 1
        assert_select '[data-layout="with-menu"] > div > nav[aria-label="Job operations sections"] [role="tablist"] > .tab-active + .tab-content.sticky.bg-base-100.border-base-300.p-3', count: 1 do |panels|
          assert_includes panels.first["class"].split, "[contain:inline-size]"
        end
        assert_select '.tab-content[role="tabpanel"] > [data-mission-control-jobs-root]', count: 1
        assert_select '[data-mission-control-jobs-root] nav[aria-label="Job operations sections"]', count: 0
        app_name = Rails.configuration.x.application_identity.app_name
        assert_select "title", text: "Queues | \#{app_name}", count: 1
        assert_select 'meta[property="og:title"][content=?]', "Queues | \#{app_name}", count: 1
        assert_select 'a[role="tab"].tab.tab-active.z-10', minimum: 1
        assert_select 'section[aria-label="Application selection"]', count: 0
        assert_not_includes response.body, "bulma.min.css"
        assert_not_includes response.body, "is-boxed"
        assert_select '[data-layout="with-menu"] nav[aria-label=?]', host_translate("navigation.admin_menu"), count: 1
        assert_select '[data-layout="with-menu"] a.menu-active[href=?]', Rails.application.routes.url_helpers.admin_jobs_path,
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

      test "keeps the matching section active on queue, job, and worker details" do
        sign_in_as(@admin)
        active_job = RetryProbeJob.perform_later
        solid_queue_job = SolidQueue::Job.find_by!(active_job_id: active_job.job_id)
        application = MissionControl::Jobs.applications.first
        server = application.servers.first
        route_options = { application_id: application.to_param, server_id: server.to_param }

        get MissionControl::Jobs::Engine.routes.url_helpers.application_queue_path(
          **route_options, id: solid_queue_job.queue_name
        )
        assert_active_job_section "Queues"

        T.must(solid_queue_job.ready_execution).destroy!
        solid_queue_job.failed_with(RuntimeError.new("expected failure"))
        get MissionControl::Jobs::Engine.routes.url_helpers.application_job_path(
          **route_options, id: active_job.job_id
        )
        assert_active_job_section(/^Failed jobs/)

        worker = SolidQueue::Process.create!(
          kind: "Worker", last_heartbeat_at: Time.current, pid: Process.pid,
          hostname: "localhost", metadata: { queues: [solid_queue_job.queue_name] }, name: "test-worker"
        )
        get MissionControl::Jobs::Engine.routes.url_helpers.application_worker_path(
          **route_options, id: worker.id
        )
        assert_active_job_section "Workers"
      end

      test "allows admins to retry a failed Solid Queue job" do
        sign_in_as(@admin)
        active_job = RetryProbeJob.perform_later
        solid_queue_job = SolidQueue::Job.find_by!(active_job_id: active_job.job_id)
        T.must(solid_queue_job.ready_execution).destroy!
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
        def assert_active_job_section(label)
          assert_response :success
          assert_select 'a[role="tab"].tab-active[aria-current="page"]', text: label, count: 1
          assert_select '[role="tablist"] > .tab-content[role="tabpanel"]', count: 1
        end

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
  production_worker = if VALUES.fetch("deployment") == "dokploy"
    "Dokployでは既存の`worker: bin/jobs --mode async`がMaintenance Taskも処理します。専用workerは追加しません。"
  else
    "このテンプレートはproduction worker processを設定しません。利用環境に合わせてSolid Queue workerの起動と監視を別途構成してください。"
  end
  authentication_route_bridge = ""

  generate "maintenance_tasks:install"
  configure_maintenance_tasks_route

  create_file "config/initializers/maintenance_tasks.rb", <<~RUBY, force: true
    MaintenanceTasks.parent_controller = "Admin::MaintenanceTasksController"

    Rails.application.config.to_prepare do
      helper = Admin::MaintenanceTasksHelper
      [MaintenanceTasks::ApplicationHelper, MaintenanceTasks::TasksHelper].each do |target|
        target.prepend(helper) unless target < helper
      end
      MaintenanceTasks::ApplicationController.content_security_policy false
    end

    MaintenanceTasks.metadata = lambda do
      T.bind(self, Admin::MaintenanceTasksController)

      {
        "triggered_by_user_id" => T.must(authorization_user).id
      }
    end
  RUBY

  create_file "app/policies/maintenance_task_policy.rb", <<~RUBY, force: true
    class MaintenanceTaskPolicy < ApplicationPolicy
      T::Sig::WithoutRuntime.sig { returns(T::Boolean) }
      def manage?
        admin?
      end
    end
  RUBY

  create_file "app/controllers/admin/maintenance_tasks_controller.rb", <<~RUBY, force: true
    module Admin
      class MaintenanceTasksController < BaseController
        helper Admin::MaintenanceTasksHelper

        layout "maintenance_tasks/admin"

        before_action :authorize_maintenance_tasks!

    #{authentication_route_bridge.lines.map { |line| "    #{line}" }.join}    private
          def authorize_maintenance_tasks!
            authorize! :maintenance_task, to: :manage?
          end
      end
    end
  RUBY

  create_file "app/views/layouts/maintenance_tasks/admin.html.erb", <<~ERB, force: true
    <% content_for :admin_content, flush: true do %>
      <div class="min-w-0 space-y-8" data-controller="maintenance-tasks-refresh" data-maintenance-tasks-root>
        <%= yield %>
      </div>
    <% end %>
    <%= render template: "layouts/admin" %>
  ERB

  create_file "app/helpers/admin/maintenance_tasks_helper.rb", <<~RUBY, force: true
    module Admin
      module MaintenanceTasksHelper
        extend T::Sig

        STATUS_CLASSES = {
          "new" => { badge: "badge-neutral", progress: "progress-neutral" },
          "enqueued" => { badge: "badge-info", progress: "progress-info" },
          "running" => { badge: "badge-info", progress: "progress-info" },
          "interrupted" => { badge: "badge-info", progress: "progress-info" },
          "pausing" => { badge: "badge-warning", progress: "progress-warning" },
          "paused" => { badge: "badge-warning", progress: "progress-warning" },
          "succeeded" => { badge: "badge-success", progress: "progress-success" },
          "cancelling" => { badge: "badge-neutral", progress: "progress-neutral" },
          "cancelled" => { badge: "badge-neutral", progress: "progress-neutral" },
          "errored" => { badge: "badge-error", progress: "progress-error" }
        }.freeze

        sig { params(status: String).returns(ActiveSupport::SafeBuffer) }
        def status_tag(status)
          tag.span(status.capitalize, class: ["badge", STATUS_CLASSES.fetch(status).fetch(:badge)])
        end

        sig { params(run: MaintenanceTasks::Run).returns(T.nilable(ActiveSupport::SafeBuffer)) }
        def progress(run)
          return unless run.started?

          progress = MaintenanceTasks::Progress.new(run)
          attributes = { max: progress.max, class: ["progress", STATUS_CLASSES.fetch(run.status).fetch(:progress)] }
          attributes[:value] = progress.value unless progress.value.nil?
          tag.div(class: "space-y-2") do
            tag.progress(**attributes) + tag.p(tag.i(progress.text), class: "text-sm text-neutral")
          end
        end

        sig do
          params(
            form_builder: ActionView::Helpers::FormBuilder,
            parameter_name: T.any(String, Symbol)
          ).returns(ActiveSupport::SafeBuffer)
        end
        def parameter_field(form_builder, parameter_name)
          inclusion_values = resolve_inclusion_value(form_builder.object, parameter_name)
          return form_builder.select(parameter_name, inclusion_values, { prompt: "Select a value" }, class: "select w-full") if inclusion_values

          case form_builder.object.class.attribute_types[parameter_name]
          when ActiveModel::Type::Integer
            form_builder.number_field(parameter_name, class: "input input-rapid w-full")
          when ActiveModel::Type::Decimal, ActiveModel::Type::Float
            form_builder.number_field(parameter_name, step: "any", class: "input input-rapid w-full")
          when ActiveModel::Type::DateTime
            form_builder.datetime_field(parameter_name, class: "input input-rapid w-full sm:w-fit") + datetime_field_help_text
          when ActiveModel::Type::Date
            form_builder.date_field(parameter_name, class: "input input-rapid w-full sm:w-fit")
          when ActiveModel::Type::Time
            form_builder.time_field(parameter_name, class: "input input-rapid w-full sm:w-fit")
          when ActiveModel::Type::Boolean
            form_builder.check_box(parameter_name, class: "checkbox")
          else
            form_builder.text_area(parameter_name, class: "textarea w-full")
          end
        end

        sig { returns(ActiveSupport::SafeBuffer) }
        def datetime_field_help_text
          zone = if Time.zone_default.nil? || Time.zone_default.name == "UTC"
            "UTC"
          else
            Time.now.zone
          end
          tag.p("Timezone: \#{zone}.", class: "label")
        end

        sig do
          params(datetime: T.any(Time, ActiveSupport::TimeWithZone))
            .returns(ActiveSupport::SafeBuffer)
        end
        def time_ago(datetime)
          time_tag(datetime, title: datetime.utc, class: "cursor-help") do
            time_ago_in_words(datetime) + " ago"
          end
        end
      end
    end
  RUBY

  create_file "app/views/maintenance_tasks/tasks/index.html.erb", <<~ERB, force: true
    <% content_for :page_title, t("maintenance_tasks.title") %>

    <%= tag.div(data: { refresh: (defined?(@refresh) && @refresh) || "" }, class: "space-y-8") do %>
      <% if @available_tasks.empty? %>
        <section class="card card-border border-base-300 bg-base-100">
          <div class="card-body">
            <h2 class="card-title leading-[1.5]">The MaintenanceTasks gem has been successfully installed!</h2>
            <p>Any new Tasks will show up here. To start writing your first Task, run <code>bin/rails generate maintenance_tasks:task my_task</code>.</p>
          </div>
        </section>
      <% else %>
        <% [["Active Tasks", @available_tasks[:active]], ["New Tasks", @available_tasks[:new]], ["Completed Tasks", @available_tasks[:completed]]].each do |heading, tasks| %>
          <% if tasks.present? %>
            <section class="space-y-4" aria-labelledby="<%= heading.parameterize %>">
              <h2 id="<%= heading.parameterize %>" class="text-xl font-bold leading-[1.5]"><%= heading %></h2>
              <div class="grid gap-4 lg:grid-cols-2">
                <%= render partial: "maintenance_tasks/tasks/task", collection: tasks %>
              </div>
            </section>
          <% end %>
        <% end %>
      <% end %>
    <% end %>
  ERB

  create_file "app/views/maintenance_tasks/tasks/_task.html.erb", <<~ERB, force: true
    <article class="card card-border min-w-0 border-base-300 bg-base-100">
      <div class="card-body min-w-0">
        <div class="flex min-w-0 flex-wrap items-center justify-between gap-3">
          <h3 class="card-title min-w-0 text-base leading-[1.5]">
            <%= link_to task, admin_maintenance_tasks.task_path(task), class: "link link-hover min-w-0 break-all" %>
          </h3>
          <%= status_tag(task.status) %>
        </div>

        <% if (run = task.related_run) %>
          <% if task.stale? %>
            <div class="alert alert-warning alert-soft text-sm" role="status">
              <svg xmlns="http://www.w3.org/2000/svg" class="size-5 shrink-0" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" aria-hidden="true">
                <path stroke-linecap="round" stroke-linejoin="round" d="m11.25 11.25.041-.02a.75.75 0 0 1 1.063.852l-.708 2.836a.75.75 0 0 0 1.063.853l.041-.021M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0Zm-9-3.75h.008v.008H12V8.25Z" />
              </svg>
              <span>This task last ran <%= MaintenanceTasks.task_staleness_threshold.inspect %> ago. Consider removing it as it may be stale.</span>
            </div>
          <% end %>

          <time class="text-sm font-semibold" datetime="<%= run.created_at.iso8601 %>" title="<%= run.created_at.utc %>"><%= run.created_at.to_fs(:long) %></time>
          <%= progress run %>
          <div class="text-sm"><%= render "maintenance_tasks/runs/info/\#{run.status}", run: run %></div>
          <div class="text-sm" id="custom-content"><%= render "maintenance_tasks/runs/info/custom", run: run %></div>
          <%= render "maintenance_tasks/runs/csv", run: run %>
          <%= render "maintenance_tasks/runs/arguments", arguments: run.masked_arguments %>
          <%= render "maintenance_tasks/runs/metadata", metadata: run.metadata %>
        <% end %>
      </div>
    </article>
  ERB

  create_file "app/views/maintenance_tasks/tasks/show.html.erb", <<~ERB, force: true
    <% content_for :page_title, @task %>

    <section class="card card-border border-base-300 bg-base-100">
      <div class="card-body">
        <%= form_with url: admin_maintenance_tasks.task_runs_path(@task), method: :post, class: "space-y-6" do |form| %>
          <% if @task.csv_task? %>
            <fieldset class="fieldset">
              <%= form.label :csv_file, class: "fieldset-legend" %>
              <%= form.file_field :csv_file, accept: "text/csv", class: "file-input w-full" %>
            </fieldset>
          <% end %>

          <% parameter_names = @task.parameter_names %>
          <% if parameter_names.any? %>
            <div class="grid gap-5 md:grid-cols-2">
              <%= fields_for :task, @task.new do |ff| %>
                <% parameter_names.each do |parameter_name| %>
                  <fieldset class="fieldset min-w-0">
                    <%= ff.label parameter_name, class: "fieldset-legend" do %>
                      <span class="font-mono"><%= parameter_name %></span>
                      <% if attribute_required?(ff.object, parameter_name) %>
                        <span class="text-error" aria-hidden="true">*</span><span class="sr-only"> required</span>
                      <% end %>
                    <% end %>
                    <%= parameter_field(ff, parameter_name) %>
                  </fieldset>
                <% end %>
              <% end %>
            </div>
          <% end %>

          <%= render "maintenance_tasks/tasks/custom", form: form %>
          <div class="card-actions justify-end">
            <%= form.submit "Run", class: "btn btn-primary btn-rapid", disabled: @task.deleted? %>
          </div>
        <% end %>
      </div>
    </section>

    <% if (code = @task.code) %>
      <details class="collapse collapse-arrow card card-border border-base-300 bg-base-100">
        <summary class="collapse-title text-lg font-semibold">Source code</summary>
        <div class="collapse-content">
          <div class="mockup-code overflow-x-auto"><pre data-prefix=""><code><%= highlight_code(code) %></code></pre></div>
        </div>
      </details>
    <% end %>

    <%= tag.div(data: { refresh: @task.refresh? || "" }, class: "space-y-8") do %>
      <% if @task.active_runs.any? %>
        <section class="space-y-4">
          <h2 class="text-xl font-bold leading-[1.5]">Active Runs</h2>
          <%= render partial: "maintenance_tasks/runs/run", collection: @task.active_runs %>
        </section>
      <% end %>

      <% if @task.runs_page.records.present? %>
        <section class="space-y-4">
          <h2 class="text-xl font-bold leading-[1.5]">Previous Runs</h2>
          <%= render partial: "maintenance_tasks/runs/run", collection: @task.runs_page.records %>
          <% unless @task.runs_page.last? %>
            <div class="join"><%= link_to "Next page", admin_maintenance_tasks.task_path(@task, cursor: @task.runs_page.next_cursor), class: "btn join-item" %></div>
          <% end %>
        </section>
      <% end %>
    <% end %>
  ERB

  create_file "app/views/maintenance_tasks/runs/_run.html.erb", <<~ERB, force: true
    <details class="collapse collapse-arrow card card-border border-base-300 bg-base-100" open id="run_<%= run.id %>">
      <summary class="collapse-title pr-12">
        <span class="flex min-w-0 flex-wrap items-center justify-between gap-3">
          <span class="flex min-w-0 flex-wrap items-center gap-3">
            <time class="font-semibold" datetime="<%= run.created_at.iso8601 %>" title="<%= run.created_at.utc %>"><%= run.created_at.to_fs(:long) %></time>
            <%= status_tag run.status %>
          </span>
          <a href="#run_<%= run.id %>" class="link link-hover" title="Run ID">#<%= run.id %></a>
        </span>
      </summary>

      <div class="collapse-content space-y-5">
        <%= progress run %>
        <div class="text-sm"><%= render "maintenance_tasks/runs/info/\#{run.status}", run: run %></div>
        <div class="text-sm" id="custom-content"><%= render "maintenance_tasks/runs/info/custom", run: run %></div>
        <%= render "maintenance_tasks/runs/csv", run: run %>
        <%= render "maintenance_tasks/runs/arguments", arguments: run.masked_arguments %>
        <%= render "maintenance_tasks/runs/metadata", metadata: run.metadata %>

        <div class="card-actions flex-wrap justify-end">
          <% if run.paused? %>
            <%= button_to "Resume", admin_maintenance_tasks.resume_task_run_path(@task, run), class: "btn", disabled: @task.deleted? %>
            <%= button_to "Cancel", admin_maintenance_tasks.cancel_task_run_path(@task, run), class: "btn btn-error" %>
          <% elsif run.errored? %>
            <%= button_to "Resume", admin_maintenance_tasks.resume_task_run_path(@task, run), class: "btn", disabled: @task.deleted? %>
          <% elsif run.cancelling? %>
            <% if run.stuck? %><%= button_to "Cancel", admin_maintenance_tasks.cancel_task_run_path(@task, run), class: "btn btn-error", disabled: @task.deleted? %><% end %>
          <% elsif run.pausing? %>
            <%= button_to "Pausing", admin_maintenance_tasks.pause_task_run_path(@task, run), class: "btn btn-warning", disabled: true %>
            <%= button_to "Cancel", admin_maintenance_tasks.cancel_task_run_path(@task, run), class: "btn btn-error" %>
            <% if run.stuck? %><%= button_to "Force pause", admin_maintenance_tasks.pause_task_run_path(@task, run), class: "btn btn-error", disabled: @task.deleted? %><% end %>
          <% elsif run.active? %>
            <%= button_to "Pause", admin_maintenance_tasks.pause_task_run_path(@task, run), class: "btn btn-warning", disabled: @task.deleted? %>
            <%= button_to "Cancel", admin_maintenance_tasks.cancel_task_run_path(@task, run), class: "btn btn-error" %>
          <% end %>
        </div>
      </div>
    </details>
  ERB

  create_file "app/views/maintenance_tasks/runs/_arguments.html.erb", <<~ERB, force: true
    <% if arguments.present? %>
      <section class="space-y-3">
        <h3 class="text-sm font-semibold leading-[1.5]">Arguments:</h3>
        <%= render "maintenance_tasks/runs/serializable", serializable: arguments %>
      </section>
    <% end %>
  ERB

  create_file "app/views/maintenance_tasks/runs/_metadata.html.erb", <<~ERB, force: true
    <% if metadata.present? %>
      <section class="space-y-3">
        <h3 class="text-sm font-semibold leading-[1.5]">Metadata:</h3>
        <%= render "maintenance_tasks/runs/serializable", serializable: metadata %>
      </section>
    <% end %>
  ERB

  create_file "app/views/maintenance_tasks/runs/_csv.html.erb", <<~ERB, force: true
    <% if run.csv_file.present? %>
      <%= link_to "Download CSV", csv_file_download_path(run), class: "link link-hover" %>
    <% end %>
  ERB

  create_file "app/views/maintenance_tasks/runs/_serializable.html.erb", <<~ERB, force: true
    <% if serializable.present? %>
      <% case serializable %>
      <% when Hash %>
        <dl class="grid gap-3 md:grid-cols-2">
          <% serializable.transform_values(&:to_s).each do |key, value| %>
            <div class="rounded-box bg-base-200 p-4">
              <dt class="mb-2 break-all font-mono text-sm font-semibold"><%= key %></dt>
              <dd class="min-w-0">
                <% unless value.empty? %>
                  <% if value.include?("\n") %><pre class="overflow-x-auto whitespace-pre-wrap break-words text-sm"><%= value %></pre><% else %><code class="break-all text-sm"><%= value %></code><% end %>
                <% end %>
              </dd>
            </div>
          <% end %>
        </dl>
      <% else %>
        <code class="block break-all rounded-box bg-base-200 p-4 text-sm"><%= serializable.inspect %></code>
      <% end %>
    <% end %>
  ERB

  create_file "app/views/maintenance_tasks/runs/info/_errored.html.erb", <<~ERB, force: true
    <div class="space-y-4">
      <p>Ran for <%= time_running_in_words run %> until an error happened <%= time_ago run.ended_at %>.</p>
      <div class="alert alert-error alert-vertical" role="alert">
        <div class="font-semibold"><%= run.error_class %></div>
        <p><%= run.error_message %></p>
        <% if run.backtrace.present? %><pre class="max-w-full overflow-x-auto whitespace-pre-wrap break-words text-sm"><code><%= format_backtrace(run.backtrace) %></code></pre><% end %>
      </div>
    </div>
  ERB

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

    実行履歴、status、cursor、job ID、arguments、metadata、error class/message/backtraceは`maintenance_tasks_runs`へGem標準形式で保存されます。実行者はRun metadataの`triggered_by_user_id`へ実行時点の内部User IDをスナップショットとして保存します。User recordとの関連は持たないため、User削除後も履歴は維持されます。

    ## Worker

    Maintenance TaskはSolid Queueへenqueueされ、同期実行へ切り替わりません。#{production_worker}

    ## 秘密情報

    arguments、metadata、例外message、backtraceは永続化され、管理画面へ表示されます。password、token、秘密鍵、API credentialなどの秘密情報をargumentやmetadataへ渡さず、例外messageにも含めないでください。
  MARKDOWN

  create_file "test/support/maintenance_tasks/safe_test_task.rb", <<~RUBY, force: true
    module Maintenance
      class SafeTestTask < MaintenanceTasks::Task
        attribute :note, :string, default: "Evidence note"
        attribute :quantity, :integer, default: 1
        attribute :ratio, :float, default: 1.5
        attribute :amount, :decimal, default: 2.5
        attribute :scheduled_at, :datetime
        attribute :due_on, :date
        attribute :starts_at, :time
        attribute :mode, :integer
        attribute :notify, :boolean, default: false

        validates :note, presence: true
        validates :mode, inclusion: { in: [1, 2], allow_nil: true }

        no_collection

        def process
          nil
        end
      end

      class CsvTestTask < MaintenanceTasks::Task
        csv_collection

        def process(_row)
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

  controller_test_support = <<~RUBY
      include ActiveJob::TestHelper
      include Devise::Test::IntegrationHelpers

      setup do
        @admin = User.create!
        @regular = User.create!
        @admin.grant_role!(:admin)
      end

      private
        def sign_in_as(user, _key = nil)
          sign_in user
        end
  RUBY
  create_file "test/controllers/admin/maintenance_tasks_controller_test.rb", <<~RUBY, force: true
    require "test_helper"
    require "cgi"

    class Admin::MaintenanceTasksControllerTest < ActionDispatch::IntegrationTest
      TASK_NAME = "Maintenance::SafeTestTask"
      TASK_PATH = "/admin/maintenance_tasks/tasks/\#{CGI.escapeURIComponent(TASK_NAME)}"
      RUNS_PATH = "\#{TASK_PATH}/runs"
      CSV_TASK_NAME = "Maintenance::CsvTestTask"
      CSV_TASK_PATH = "/admin/maintenance_tasks/tasks/\#{CGI.escapeURIComponent(CSV_TASK_NAME)}"
      MAINTENANCE_TASK_ROUTES = MaintenanceTasks::Engine.routes.url_helpers

    #{controller_test_support}
      test "requires authentication" do
        get admin_maintenance_tasks_url

        assert_redirected_to new_user_session_url
      end

      test "denies every engine operation to regular users" do
        sign_in_as(@regular)

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
        sign_in_as(@admin)

        get admin_maintenance_tasks_url
        assert_response :success
        assert_nil response.headers["Content-Security-Policy"]
        assert_select "[data-maintenance-tasks-root]", count: 1
        page_title = I18n.t("maintenance_tasks.title")
        app_name = Rails.configuration.x.application_identity.app_name
        assert_select '[data-layout="with-menu"] > div > h1', text: page_title, count: 1
        assert_select "title", text: "\#{page_title} | \#{app_name}", count: 1
        assert_select '[data-layout="with-menu"] .tab-content', count: 0
        assert_select ".card.card-border", minimum: 1
        assert_select ".badge.badge-neutral", text: "New", count: 2
        assert_select 'link[href*="bulma"]', count: 0
        assert_select '[data-layout="with-menu"] nav[aria-label=?]', I18n.t("navigation.admin_menu"), count: 1
        assert_select '[data-layout="with-menu"] a[href=?]', Rails.application.routes.url_helpers.admin_users_path,
          text: I18n.t("navigation.users"), minimum: 1
        assert_select '[data-layout="with-menu"] a.menu-active[href=?]', Rails.application.routes.url_helpers.admin_maintenance_tasks_path,
          text: I18n.t("navigation.maintenance_tasks"), count: 1

        get TASK_PATH
        assert_response :success
        assert_select "[data-maintenance-tasks-root]", count: 1
        assert_select "fieldset.fieldset", count: 9
        assert_select "textarea.textarea[name=?]", "task[note]", count: 1
        assert_select "input.input[type=number][name=?]", "task[quantity]", count: 1
        assert_select "input.input[type=number][step=any][name=?]", "task[ratio]", count: 1
        assert_select "input.input[type=number][step=any][name=?]", "task[amount]", count: 1
        assert_select "input.input[type=datetime-local][name=?]", "task[scheduled_at]", count: 1
        assert_select "input.input[type=date][name=?]", "task[due_on]", count: 1
        assert_select "input.input[type=time][name=?]", "task[starts_at]", count: 1
        assert_select "select.select[name=?]", "task[mode]", count: 1
        assert_select "input.checkbox[name=?]", "task[notify]", count: 1
        assert_select "input.btn.btn-primary[type=submit]", value: "Run", count: 1
        assert_select "form[action=?]", MAINTENANCE_TASK_ROUTES.task_runs_path(TASK_NAME), count: 1
        assert_select "details.collapse.collapse-arrow", minimum: 1
        assert_select ".mockup-code", count: 1

        get CSV_TASK_PATH
        assert_response :success
        assert_select "input.file-input[type=file][name=csv_file]", count: 1
      end

      test "preserves pause, resume, and cancel operations" do
        sign_in_as(@admin)

        pausing_run = MaintenanceTasks::Run.create!(task_name: TASK_NAME, status: "running", job_id: "running-job")
        post "\#{RUNS_PATH}/\#{pausing_run.id}/pause"
        assert_redirected_to MAINTENANCE_TASK_ROUTES.task_path(TASK_NAME)
        assert_equal "pausing", pausing_run.reload.status

        resumable_run = MaintenanceTasks::Run.create!(task_name: TASK_NAME, status: "paused", job_id: "paused-job")
        assert_enqueued_with(job: MaintenanceTasks::TaskJob) do
          post "\#{RUNS_PATH}/\#{resumable_run.id}/resume"
        end
        assert_redirected_to MAINTENANCE_TASK_ROUTES.task_path(TASK_NAME)
        assert_equal "enqueued", resumable_run.reload.status

        cancellable_run = MaintenanceTasks::Run.create!(task_name: TASK_NAME, status: "paused", job_id: "cancel-job")
        post "\#{RUNS_PATH}/\#{cancellable_run.id}/cancel"
        assert_redirected_to MAINTENANCE_TASK_ROUTES.task_path(TASK_NAME)
        assert_equal "cancelled", cancellable_run.reload.status
      end

      test "renders daisyUI run controls, progress, and errors" do
        sign_in_as(@admin)
        now = Time.current
        MaintenanceTasks::Run.create!(
          task_name: TASK_NAME,
          status: "paused",
          job_id: "paused-job",
          started_at: now - 2.minutes,
          tick_count: 2,
          tick_total: 10
        )
        MaintenanceTasks::Run.create!(
          task_name: TASK_NAME,
          status: "errored",
          job_id: "errored-job",
          started_at: now - 1.minute,
          ended_at: now,
          error_class: "ArgumentError",
          error_message: "Something went wrong",
          backtrace: ["app/tasks/maintenance/safe_test_task.rb:10"]
        )

        get TASK_PATH

        assert_response :success
        assert_select ".badge.badge-warning", text: "Paused", count: 1
        assert_select "progress.progress-warning", count: 1
        assert_select "form[action$='/resume'] .btn", text: "Resume", count: 2
        assert_select "form[action$='/cancel'] .btn.btn-error", text: "Cancel", count: 1
        assert_select ".badge.badge-error", text: "Errored", count: 1
        assert_select ".alert.alert-error", text: /Something went wrong/, count: 1
      end

      test "enqueues and executes a task while preserving standard run history" do
        sign_in_as(@admin)

        assert_enqueued_with(job: MaintenanceTasks::TaskJob) do
          post RUNS_PATH
        end
        assert_response :redirect

        run = T.must(MaintenanceTasks::Run.order(:id).last)
        assert_predicate run.job_id, :present?
        assert_equal "enqueued", run.status
        assert_equal @admin.id, run.metadata.fetch("triggered_by_user_id")

        perform_enqueued_jobs

        assert_equal "succeeded", run.reload.status
        assert_predicate run.started_at, :present?
        assert_predicate run.ended_at, :present?
        assert_equal 1, MaintenanceTasks::Run.where(task_name: TASK_NAME).count

        get TASK_PATH
        assert_response :success
        assert_select ".badge.badge-success", text: "Succeeded", count: 1
        assert_select "progress.progress-success", count: 1
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

    Capybara.server_host = "localhost"

    class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
      include Warden::Test::Helpers

      driven_by :playwright,
        using: :chromium,
        screen_size: [1400, 900],
        options: {
          headless: true,
          playwright_cli_executable_path: Rails.root.join("node_modules/.bin/playwright").to_s
        }

      setup { Warden.test_mode! }
      teardown { Warden.test_reset! }
    end
  RUBY
  create_file "test/support/factory_bot.rb", "ActiveSupport.on_load(:active_support_test_case) { include FactoryBot::Syntax::Methods }\n"
  append_to_file "test/test_helper.rb", "\nrequire_relative \"support/factory_bot\"\n"
end

def configure_evidence_capture
  additional_login_methods = VALUES.fetch("additional_login_methods")
  avatar = VALUES.fetch("profile_features").include?("avatar")
  api = VALUES.fetch("api") == "enable"
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

      include ActiveJob::TestHelper

      SCENARIO_SET = "full"
      ADDITIONAL_LOGIN_METHODS = __ADDITIONAL_LOGIN_METHODS__
      AVATAR = __AVATAR__
      LOCALE = I18n.default_locale.to_s
      API = __API__
      WEB_PUSH = __WEB_PUSH__
      JOB_OPERATIONS = __JOB_OPERATIONS__
      MAINTENANCE_TASKS = __MAINTENANCE_TASKS__
      require "eth" if ADDITIONAL_LOGIN_METHODS.include?("siwe")
      VIEWPORTS = {
        "desktop" => { "width" => 1400, "height" => 900 },
        "mobile" => { "width" => 390, "height" => 844 }
      }.freeze
      PRIVATE_KEY = "1".rjust(64, "0")
      REGULAR_PRIVATE_KEY = "2".rjust(64, "0")

      test "captures every generated page and key visual state" do
        @output_directory = Pathname(ENV.fetch("EVIDENCE_OUTPUT_DIR")).expand_path
        raise "EVIDENCE_OUTPUT_DIR must be an existing empty directory" unless @output_directory.directory? && @output_directory.children.empty?

        @captures = []
        capture_common_scenarios
        capture_siwe_scenarios if ADDITIONAL_LOGIN_METHODS.include?("siwe")
        capture_avatar_scenarios if AVATAR

        File.write(
          @output_directory.join("captures.json"),
          JSON.pretty_generate(
            "scenario_set" => SCENARIO_SET,
            "additional_login_methods" => ADDITIONAL_LOGIN_METHODS,
            "locale" => LOCALE,
            "viewports" => VIEWPORTS,
            "captures" => @captures
          ) + "\n"
        )
      end

      private
        def capture_common_scenarios
          VIEWPORTS.each do |viewport_name, viewport|
            page.current_window.resize_to(viewport.fetch("width"), viewport.fetch("height"))
            prepare_guest_data
            verify_footer_geometry if viewport_name == "desktop"
            capture_guest_pages(viewport_name)
            authenticate
            prepare_authenticated_data
            verify_with_menu_layout_geometry if viewport_name == "desktop"
            verify_job_operations_geometry if viewport_name == "desktop" && JOB_OPERATIONS
            verify_maintenance_tasks_geometry if viewport_name == "desktop" && MAINTENANCE_TASKS
            capture_authenticated_pages(viewport_name)
            capture_regular_user_navigation(viewport_name)
            Capybara.reset_sessions!
          end
        end

        def capture_siwe_scenarios
          @user ||= create_evidence_user("evidence-primary")
          T.must(@user.profile).update!(screen_name: "evidence_user", display_name: "Evidence User")

          VIEWPORTS.each do |viewport_name, viewport|
            Capybara.reset_sessions!
            page.current_window.resize_to(viewport.fetch("width"), viewport.fetch("height"))
            @user.siwe_identities.delete_all

            capture_page(
              "siwe-login-option",
              translate("siwe.sign_in.title"),
              new_user_session_path,
              translate("authentication.sign_in_title"),
              viewport_name
            )
            assert_selector '[data-controller="siwe-sign-in"][data-siwe-sign-in-mode-value="login"]'

            authenticate
            capture_page(
              "siwe-identities-empty",
              translate("siwe.identities.title"),
              account_siwe_identities_path,
              translate("siwe.identities.title"),
              viewport_name
            )
            assert_account_settings_tabs_geometry
            capture_page(
              "siwe-identity-new",
              translate("siwe.identities.new_title"),
              new_account_siwe_identity_path,
              translate("siwe.identities.new_title"),
              viewport_name
            )
            assert_no_selector 'input[name="name"], input[name="current_password"]'
            assert_account_settings_tabs_geometry

            main_key = Eth::Key.new(priv: PRIVATE_KEY)
            regular_key = Eth::Key.new(priv: REGULAR_PRIVATE_KEY)
            main_identity = @user.siwe_identities.create!(name: "Wallet #1", address: main_key.address.to_s)
            @user.siwe_identities.create!(name: "Wallet #2", address: regular_key.address.to_s)
            capture_page(
              "siwe-identities-multiple",
              translate("siwe.identities.title"),
              account_siwe_identities_path,
              translate("siwe.identities.title"),
              viewport_name
            )
            assert_account_settings_tabs_geometry

            capture_page(
              "siwe-identity-edit",
              translate("siwe.identities.edit_title"),
              edit_account_siwe_identity_path(main_identity),
              translate("siwe.identities.edit_title"),
              viewport_name
            )
            assert_no_selector 'input[name="current_password"]'
            assert_account_settings_tabs_geometry
            capture_page(
              "siwe-identity-unlink",
              translate("siwe.identities.delete_title"),
              account_siwe_identity_path(main_identity),
              translate("siwe.identities.delete_title"),
              viewport_name
            )
            assert_selector '[data-controller="passkey"], [data-controller="siwe-sign-in"]', minimum: 1
            assert_no_selector 'input[name="siwe_identity[name]"]'
            assert_account_settings_tabs_geometry
            visit edit_account_siwe_identity_path(main_identity)
            fill_in translate("siwe.identities.name"), with: "Primary Wallet"
            click_button translate("common.update")
            capture_page(
              "siwe-identity-renamed",
              translate("siwe.identities.updated"),
              account_siwe_identities_path,
              translate("siwe.identities.title"),
              viewport_name
            )
            assert_account_settings_tabs_geometry
            authenticate_with_siwe(main_key, viewport)
            capture_page(
              "siwe-login-existing-user",
              translate("siwe.sign_in.title"),
              account_path,
              translate("accounts.show.title"),
              viewport_name
            )
          end
        end

        def assert_account_settings_tabs_geometry
          geometry = page.driver.with_playwright_page do |playwright_page|
            playwright_page.evaluate(<<~JAVASCRIPT)
              () => {
                const navigation = document.querySelector('nav[aria-label="アカウント設定"]')
                const scroller = navigation.querySelector(':scope > .overflow-x-auto')
                const tablist = scroller.querySelector(':scope > [role="tablist"]')
                const tabs = Array.from(tablist.querySelectorAll(':scope > .tab'))
                const activeTab = tablist.querySelector(':scope > .tab-active')
                const panel = activeTab.nextElementSibling
                const navigationRect = navigation.getBoundingClientRect()
                const panelRect = panel.getBoundingClientRect()
                const activeTabRect = activeTab.getBoundingClientRect()
                return {
                  documentWidth: document.documentElement.scrollWidth,
                  viewportWidth: window.innerWidth,
                  navigationLeft: navigationRect.left,
                  navigationRight: navigationRect.right,
                  panelLeft: panelRect.left,
                  panelRight: panelRect.right,
                  activeTabBottom: activeTabRect.bottom,
                  panelTop: panelRect.top,
                  activeTabBorderBottomWidth: parseFloat(getComputedStyle(activeTab).borderBottomWidth),
                  panelBorderTopWidth: parseFloat(getComputedStyle(panel).borderTopWidth),
                  panelMarginTop: parseFloat(getComputedStyle(panel).marginTop),
                  activeTabCoversSharedEdge: document.elementFromPoint(
                    activeTabRect.left + activeTabRect.width / 2,
                    panelRect.top + 0.5
                  ) === activeTab,
                  activeTabOwnsPanel: activeTab.nextElementSibling === panel,
                  panelInsideTablist: panel.parentElement === tablist,
                  panelIsTabContent: panel.classList.contains('tab-content'),
                  panelIsSticky: panel.classList.contains('sticky'),
                  panelContain: getComputedStyle(panel).contain,
                  panelCount: tablist.querySelectorAll(':scope > .tab-content').length,
                  tabRowCount: new Set(tabs.map((tab) => Math.round(tab.getBoundingClientRect().top))).size,
                  scrollerScrollWidth: scroller.scrollWidth,
                  scrollerClientWidth: scroller.clientWidth,
                  nestedBaseBorderCount: panel.querySelectorAll('.card-border.border-base-300').length
                }
              }
            JAVASCRIPT
          end
          assert_operator geometry.fetch("documentWidth"), :<=, geometry.fetch("viewportWidth")
          assert_in_delta geometry.fetch("navigationLeft"), geometry.fetch("panelLeft"), 1
          assert_operator geometry.fetch("panelRight"), :<=, geometry.fetch("navigationRight") + 1
          assert_in_delta geometry.fetch("activeTabBottom"), geometry.fetch("panelTop"), 1.5
          assert_in_delta 0, geometry.fetch("activeTabBorderBottomWidth"), 0.1
          assert_in_delta 1, geometry.fetch("panelBorderTopWidth"), 0.1
          assert_in_delta(-1, geometry.fetch("panelMarginTop"), 0.1)
          assert geometry.fetch("activeTabCoversSharedEdge")
          assert geometry.fetch("activeTabOwnsPanel")
          assert geometry.fetch("panelInsideTablist")
          assert geometry.fetch("panelIsTabContent")
          assert geometry.fetch("panelIsSticky")
          assert_equal "inline-size", geometry.fetch("panelContain")
          assert_equal 1, geometry.fetch("panelCount")
          assert_equal 1, geometry.fetch("tabRowCount")
          assert_operator geometry.fetch("scrollerScrollWidth"), :>=, geometry.fetch("scrollerClientWidth")
          assert_equal 0, geometry.fetch("nestedBaseBorderCount")
        end

        def authenticate_with_siwe(key, viewport)
          Capybara.reset_sessions!
          page.current_window.resize_to(viewport.fetch("width"), viewport.fetch("height"))
          visit new_user_session_path
          challenge_response = browser_post_json(
            "/users/sign_in/siwe/challenge",
            { address: key.address.to_s, chain_id: 1 }
          )
          assert_equal 200, challenge_response.fetch("status")
          challenge = challenge_response.fetch("body")
          verify_response = browser_post_json(
            "/users/sign_in/siwe",
            {
              challenge_token: challenge.fetch("challenge_token"),
              signature: key.personal_sign(challenge.fetch("message"))
            }
          )
          assert_equal 200, verify_response.fetch("status")
        end

        def browser_post_json(path, payload)
          page.evaluate_async_script(<<~JAVASCRIPT, path, payload)
            const [path, payload, done] = arguments
            const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content
            const headers = {
              'Accept': 'application/json',
              'Content-Type': 'application/json'
            }
            if (csrfToken) headers['X-CSRF-Token'] = csrfToken
            fetch(path, {
              method: 'POST',
              credentials: 'same-origin',
              headers,
              body: JSON.stringify(payload)
            }).then(async (response) => {
              done({ status: response.status, body: await response.json() })
            }).catch((error) => done({ status: 0, error: error.message }))
          JAVASCRIPT
        end

        def capture_avatar_scenarios
          VIEWPORTS.each do |viewport_name, viewport|
            Capybara.reset_sessions!
            page.current_window.resize_to(viewport.fetch("width"), viewport.fetch("height"))
            prepare_guest_data
            authenticate
            profile = T.must(@user.profile)
            profile.avatar.purge if profile.avatar.attached?
            profile.update!(avatar_upload: T.unsafe(Object.const_get("AvatarTestImage")).upload(width: 320, height: 320))
            capture_page(
              "avatar-home",
              "アバター（ホーム）",
              root_path,
              translate("home.heading"),
              viewport_name
            )
            assert_avatar_image_geometry(40)
            capture_page(
              "avatar-profile",
              "アバター（プロフィール）",
              host_routes.profile_path,
              translate("profiles.title"),
              viewport_name
            )
            assert_avatar_image_geometry(40, 64)
          end
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

          @user ||= create_evidence_user("evidence-primary")
          T.must(@user.profile).update!(screen_name: "evidence_user", display_name: "Evidence User")
        end

        def capture_guest_pages(viewport)
          capture_page("home-guest", "ホーム（未ログイン）", root_path, translate("home.heading"), viewport)
          capture_page("about", "アプリについて", about_path, Page::TITLES.fetch("about"), viewport)
          assert_selector ".lexxy-content", text: "管理画面から更新したAction Text本文"
          capture_faq_page(viewport)
          capture_page("login", translate("authentication.sign_in_title"), new_user_session_path, translate("authentication.sign_in_title"), viewport)
          capture_page("registration", "アカウント作成", new_user_registration_path, translate("authentication.sign_up_title"), viewport)
          capture_passkey_signup(viewport)
          Capybara.reset_sessions!

          return unless viewport == "mobile"

          viewport_size = VIEWPORTS.fetch(viewport)
          page.current_window.resize_to(viewport_size.fetch("width"), viewport_size.fetch("height"))
          visit root_path
          find("header details.dropdown > summary", visible: :visible).click
          capture_current_page("navigation-guest-open", "モバイルメニュー（未ログイン）", viewport)
        end

        def authenticate
          login_as(@user, scope: :user)
          visit root_path
          assert_current_path root_path
        end

        def prepare_authenticated_data
          profile = T.must(@user.profile)
          profile.update!(screen_name: "evidence_user", display_name: "Evidence User")
          profile.avatar.purge if profile.avatar.attached?
          @user.grant_role!(:admin)
          if @backup_admin.nil?
            @backup_admin = create_evidence_user("evidence-backup-admin")
            @backup_admin.grant_role!(:admin)
          end
          if MAINTENANCE_TASKS
            MaintenanceTasks::Run.delete_all
            clear_enqueued_jobs
            clear_performed_jobs
          end
          @regular_user = create_evidence_user("evidence-regular") if @regular_user.nil?
        end

        def capture_authenticated_pages(viewport)
          capture_page("home-authenticated", "ホーム（ログイン済み）", root_path, translate("home.heading"), viewport)
          capture_page("account", "マイページ", account_path, translate("accounts.show.title"), viewport)
          assert_account_navigation_scope
          capture_avatar_states(viewport)
          capture_passkey_pages(viewport)
          if WEB_PUSH
            set_evidence_web_push_mode("granted")
            capture_page("notifications", "通知", notification_path, translate("web_push.page.title"), viewport)
            capture_enabled_web_push(viewport)
          end

          if API
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
          end
          capture_page("admin-users", "ユーザー管理", admin_users_path, translate("admin.users.title"), viewport)
          assert_admin_navigation_active(translate("navigation.users"))
          if JOB_OPERATIONS
            visit host_routes.admin_jobs_path
            assert_equal 200, page.status_code
            assert_selector "[data-mission-control-jobs-root]", count: 1
            assert_admin_navigation_active(host_translate("navigation.job_operations"))
            assert_job_operations_tabs_single_row if viewport == "desktop"
            capture_current_page("admin-job-operations", "Queues", viewport)
            if viewport == "mobile"
              find("header details.dropdown > summary", visible: :visible).click
              capture_current_page(
                "admin-job-operations-navigation-open",
                "Queuesのモバイルメニュー",
                viewport
              )
              find("header details.dropdown > summary", visible: :visible).click
            end
            find('[role="tab"]', text: /^Failed jobs/).click
            assert_selector '[data-layout="with-menu"] > div > h1', text: "Failed jobs", count: 1
            assert_selector ".tab-active", text: /^Failed jobs/, count: 1
            assert_job_operations_tabs_single_row if viewport == "desktop"
            capture_current_page("admin-job-operations-failed", "Failed jobs", viewport)
          end
          if MAINTENANCE_TASKS
            visit host_routes.admin_maintenance_tasks_path
            assert_equal 200, page.status_code
            assert_selector "[data-maintenance-tasks-root]", count: 1
            assert_admin_navigation_active(translate("navigation.maintenance_tasks"))
            capture_current_page("admin-maintenance-tasks", "運用タスク", viewport)
            click_link "Maintenance::SafeTestTask"
            assert_selector "textarea[name='task[note]']", count: 1
            assert_selector "input.checkbox[name='task[notify]']", count: 1
            capture_current_page("admin-maintenance-task-details", "運用タスク詳細", viewport)
            click_button "Run"
            assert_text "Enqueued"
            perform_enqueued_jobs
            visit page.current_path
            assert_text "Succeeded"
            assert_selector ".badge.badge-success", text: "Succeeded", count: 1
            capture_current_page("admin-maintenance-task-completed", "運用タスク完了", viewport)
            if viewport == "mobile"
              visit admin_maintenance_tasks_path
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

        def capture_passkey_pages(viewport)
          capture_page("passkeys", "Passkey一覧", account_passkeys_path, translate("passkeys.title"), viewport)
          assert_account_settings_tabs_geometry
          capture_page("passkey-new", "Passkey追加", new_account_passkey_path, translate("passkeys.new_title"), viewport)
          assert_account_settings_tabs_geometry

          second = @user.passkey_credentials.find_or_create_by!(webauthn_id: "evidence-secondary-#{@user.id}") do |passkey|
            passkey.name = "Security Key"
            passkey.public_key = "evidence-public-key"
            passkey.sign_count = 0
            passkey.transports = ["usb"]
            passkey.backup_eligible = false
            passkey.backup_state = false
          end
          capture_page("passkeys-multiple", "Passkey一覧（複数登録）", account_passkeys_path, translate("passkeys.title"), viewport)
          assert_account_settings_tabs_geometry
          capture_page("passkey-edit", "Passkey名変更", edit_account_passkey_path(second), translate("passkeys.edit_title"), viewport)
          assert_account_settings_tabs_geometry
          fill_in translate("passkeys.name"), with: "Backup Security Key"
          click_button translate("common.update")
          assert_current_path account_passkeys_path
          capture_current_page("passkey-renamed", "Passkey一覧（名称変更後）", viewport)
          capture_page("passkey-delete-reauth", "Passkey解除（再認証）", account_passkey_path(second), translate("passkeys.delete_title"), viewport)
          assert_selector '[data-passkey-destruction-action-value="delete_passkey"]', count: 1
          assert_account_settings_tabs_geometry
          capture_page("account-delete-reauth", "アカウント削除（再認証）", delete_account_path, translate("accounts.delete.title"), viewport)
          assert_selector '[data-passkey-destruction-action-value="delete_account"]', count: 1
          assert_account_settings_tabs_geometry
        end

        def capture_passkey_signup(viewport)
          install_virtual_authenticator(backup_eligible: false, backup_state: false)
          visit new_user_registration_path
          configure_webauthn_for_current_page
          click_button translate("authentication.sign_up_with_passkey")
          assert_current_path root_path
          assert_selector ".alert-warning", text: translate("credential_risk.warning")
          assert_link translate("credential_risk.add_login_method"), href: account_passkeys_path
          assert_no_selector ".alert-warning .btn"
          capture_current_page("passkey-registration-risk-warning", "Passkey登録後の紛失リスク警告", viewport)
        end

        def install_virtual_authenticator(backup_eligible:, backup_state:)
          page.driver.with_playwright_page do |playwright_page|
            cdp = playwright_page.context.new_cdp_session(playwright_page)
            cdp.send_message("WebAuthn.enable")
            cdp.send_message(
              "WebAuthn.addVirtualAuthenticator",
              params: {
                options: {
                  protocol: "ctap2",
                  transport: "internal",
                  hasResidentKey: true,
                  hasUserVerification: true,
                  isUserVerified: true,
                  automaticPresenceSimulation: true,
                  defaultBackupEligibility: backup_eligible,
                  defaultBackupState: backup_state
                }
              }
            )
          end
        end

        def configure_webauthn_for_current_page
          origin = URI(page.current_url)
          WebAuthn.configure do |config|
            config.allowed_origins = ["#{origin.scheme}://#{origin.host}:#{origin.port}"]
            config.rp_id = origin.host
          end
        end

        def create_evidence_user(identifier)
          user = User.create!
          user.passkey_credentials.create!(
            name: "Passkey",
            webauthn_id: "#{identifier}-#{user.id}",
            public_key: "evidence-public-key",
            sign_count: 0,
            transports: ["internal"],
            backup_eligible: false,
            backup_state: false
          )
          user
        end

        def capture_regular_user_navigation(viewport)
          Capybara.reset_sessions!
          viewport_size = VIEWPORTS.fetch(viewport)
          page.current_window.resize_to(viewport_size.fetch("width"), viewport_size.fetch("height"))
          login_as(@regular_user, scope: :user)
          visit root_path
          assert_current_path root_path

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
          capture_page("profile-boring-avatar", "プロフィール（自動生成アバター）", host_routes.profile_path, translate("profiles.title"), viewport)
          capture_page("profile-edit-boring-avatar", "プロフィール編集（自動生成アバター）", host_routes.edit_profile_path, translate("profiles.edit_title"), viewport)

          source = T.unsafe(Object.const_get("AvatarTestImage")).image_file(width: 320, height: 180)
          visit host_routes.edit_profile_path
          attach_file translate("activerecord.attributes.profile.avatar_upload"), source.path
          assert_selector "dialog#avatar-crop-modal[open]"
          if viewport == "desktop"
            [320, 390, 640, 960, 961].each do |width|
              page.current_window.resize_to(width, VIEWPORTS.fetch("mobile").fetch("height"))
              assert_avatar_crop_modal_geometry
            end
            viewport_size = VIEWPORTS.fetch(viewport)
            page.current_window.resize_to(viewport_size.fetch("width"), viewport_size.fetch("height"))
          end
          assert_avatar_crop_modal_geometry
          capture_current_page("profile-avatar-crop-modal", "プロフィール画像の切り抜き", viewport)
          click_button translate("profiles.avatar_crop.apply")
          assert_no_selector "dialog#avatar-crop-modal[open]"
          assert_not T.must(@user.profile).reload.avatar.attached?
          cropped = page.evaluate_async_script(<<~JAVASCRIPT)
            const done = arguments[0]
            const file = document.querySelector('input[name="profile[avatar_upload]"]').files[0]
            createImageBitmap(file).then((image) => done({ width: image.width, height: image.height, type: file.type }))
              .catch((error) => done({ error: error.message }))
          JAVASCRIPT
          assert_equal({ "width" => 512, "height" => 512, "type" => "image/png" }, cropped)
          click_button translate("common.save")
          assert_current_path host_routes.profile_path
          stored = Vips::Image.new_from_buffer(T.must(@user.profile).reload.avatar.blob.download, "")
          assert_equal [512, 512], [stored.width, stored.height]

          capture_page("home-uploaded-avatar", "ホーム（画像アバター）", root_path, translate("home.heading"), viewport)
          assert_avatar_image_geometry(40)
          capture_page("profile-uploaded-avatar", "プロフィール（画像アバター）", host_routes.profile_path, translate("profiles.title"), viewport)
          assert_avatar_image_geometry(40, 64)
          capture_page("profile-edit-uploaded-avatar", "プロフィール編集（画像アバター）", host_routes.edit_profile_path, translate("profiles.edit_title"), viewport)
          assert_avatar_image_geometry(40, 64)

          accept_confirm { click_button translate("profiles.avatar_delete") }
          assert_current_path host_routes.profile_path
          assert_selector ".alert.alert-success", text: translate("profiles.avatar.destroy.notice")
          capture_current_page("profile-avatar-deleted", "プロフィール（画像削除後）", viewport)
          capture_page("home-avatar-deleted", "ホーム（画像削除後）", root_path, translate("home.heading"), viewport)
        ensure
          source&.close!
        end

        def assert_avatar_crop_modal_geometry
          geometry = page.driver.with_playwright_page do |playwright_page|
            playwright_page.evaluate(<<~JAVASCRIPT)
              () => {
                const dialog = document.querySelector("dialog#avatar-crop-modal")
                const box = dialog.querySelector(".modal-box")
                const cropper = dialog.querySelector('[data-image-crop-target="cropper"]')
                const selection = dialog.querySelector("cropper-selection")
                const boxRect = box.getBoundingClientRect()
                const cropperRect = cropper.getBoundingClientRect()
                return {
                  dialogOpen: dialog.open,
                  documentWidth: document.documentElement.scrollWidth,
                  viewportWidth: window.innerWidth,
                  boxLeft: boxRect.left,
                  boxRight: boxRect.right,
                  cropperWidth: cropperRect.width,
                  cropperHeight: cropperRect.height,
                  selectionWidth: selection.width,
                  selectionHeight: selection.height,
                  aspectRatio: selection.aspectRatio
                }
              }
            JAVASCRIPT
          end
          assert geometry.fetch("dialogOpen")
          assert_operator geometry.fetch("documentWidth"), :<=, geometry.fetch("viewportWidth")
          assert_operator geometry.fetch("boxLeft"), :>=, 0
          assert_operator geometry.fetch("boxRight"), :<=, geometry.fetch("viewportWidth")
          assert_in_delta geometry.fetch("cropperWidth"), geometry.fetch("cropperHeight"), 1
          assert_in_delta geometry.fetch("selectionWidth"), geometry.fetch("selectionHeight"), 1
          assert_equal 1, geometry.fetch("aspectRatio")
        end

        def assert_avatar_image_geometry(*sizes)
          geometry = page.driver.with_playwright_page do |playwright_page|
            playwright_page.wait_for_function(<<~JAVASCRIPT, arg: sizes)
              (expectedSizes) => expectedSizes.every((size) => {
                const image = document.querySelector(`img[width="${size}"][height="${size}"]`)
                return image && image.complete && image.naturalWidth === size && image.naturalHeight === size
              })
            JAVASCRIPT
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
          reconnect_web_push_controller
          toggle = find('[data-push-subscription-target="toggle"]:not([disabled])')
          assert_not toggle.checked?
          toggle.click
          assert_selector '[data-push-subscription-target="status"].alert-success', text: translate("web_push.client.enabled")
          assert_selector '[data-push-subscription-target="testButton"]:not([disabled])', text: translate("web_push.page.send_test")
          capture_current_page("web-push-enabled", "Web Push（購読済み・テスト通知可能）", viewport)

          find('[data-push-subscription-target="testButton"]').click
          assert_selector '[data-push-subscription-target="status"].alert-success', text: translate("web_push.client.test_sent")

          set_evidence_web_push_mode("rotated")
          visit notification_path
          reconnect_web_push_controller
          install_evidence_csrf_token
          assert_selector '[data-push-subscription-target="status"].alert-success',
            text: translate("web_push.client.reconciled")
          assert_equal({ "subscribeCount" => 1, "unsubscribeCount" => 1, "subscribed" => true,
                         "permissionRequests" => 0 }, evidence_web_push_stats)

          find('[data-push-subscription-target="toggle"]:not([disabled])').click
          assert_selector '[data-push-subscription-target="status"].alert-info',
            text: translate("web_push.client.disabled")
          assert_equal false, evidence_web_push_stats.fetch("subscribed")

          set_evidence_web_push_mode("default")
          visit notification_path
          reconnect_web_push_controller
          install_evidence_csrf_token
          find('[data-push-subscription-target="toggle"]:not([disabled])').click
          assert_selector '[data-push-subscription-target="status"].alert-success',
            text: translate("web_push.client.enabled")
          assert_equal 1, evidence_web_push_stats.fetch("permissionRequests")

          set_evidence_web_push_mode("denied")
          visit notification_path
          reconnect_web_push_controller
          assert_selector '[data-push-subscription-target="status"].alert-warning',
            text: translate("web_push.client.blocked")
          assert find('[data-push-subscription-target="toggle"]').disabled?

          set_evidence_web_push_mode("unsupported")
          visit notification_path
          reconnect_web_push_controller
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

        def reconnect_web_push_controller
          install_web_push_stub
          page.execute_script(<<~JAVASCRIPT)
            window.Stimulus
              .getControllerForElementAndIdentifier(document.body, "push-subscription")
              .connect()
          JAVASCRIPT
        end

        def install_web_push_stub
          page.driver.with_playwright_page do |playwright_page|
            script = <<~JAVASCRIPT
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
            playwright_page.evaluate(script)
          end
        end

        def assert_admin_navigation_active(label)
          assert_selector %([data-layout="with-menu"] nav[aria-label="#{host_translate("navigation.admin_menu")}"])
          assert_selector %([data-layout="with-menu"] nav[aria-label="#{host_translate("navigation.admin_menu")}"] li.menu-title), text: host_translate("navigation.admin"), count: 1
          assert_no_selector %([data-layout="with-menu"] nav[aria-label="#{host_translate("navigation.account_menu")}"])
          assert_selector '[data-layout="with-menu"] a.menu-active[aria-current="page"]', text: label, count: 1
          assert_selector 'header li.menu-title', text: host_translate("navigation.admin"), count: 1, visible: :all
          assert_no_selector %(header a[href="\#{account_path}"]), visible: :all
        end

        def assert_account_navigation_scope
          assert_selector %([data-layout="with-menu"] nav[aria-label="#{translate("navigation.account_menu")}"])
          assert_no_selector %([data-layout="with-menu"] nav[aria-label="#{translate("navigation.admin_menu")}"])
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

        def verify_with_menu_layout_geometry
          { "account" => account_path, "admin" => admin_pages_path }.each do |area, path|
            [320, 390, 640, 960, 961].each do |width|
              page.current_window.resize_to(width, 900)
              visit path
              geometry = page.driver.with_playwright_page do |playwright_page|
                playwright_page.evaluate(<<~JAVASCRIPT)
                  () => {
                    const layout = document.querySelector('[data-layout="with-menu"]')
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
                "#{area} with-menu layout horizontal overflow at #{width}px"
              if width < 961
                assert_operator geometry.fetch("contentTop"), :>=, geometry.fetch("sidebarBottom"),
                  "#{area} with-menu layout should use one column at #{width}px"
              else
                assert_in_delta geometry.fetch("sidebarTop"), geometry.fetch("contentTop"), 0.5
                assert_operator geometry.fetch("contentLeft"), :>=, geometry.fetch("sidebarRight"),
                  "#{area} with-menu layout should use two columns at #{width}px"
              end
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
                  const layout = document.querySelector('[data-layout="with-menu"]')
                  const heading = layout.querySelector(':scope > div > h1')
                  const subnavigation = layout.querySelector(':scope > div > nav[aria-label="Job operations sections"]')
                  const scroller = subnavigation.querySelector(':scope > .overflow-x-auto')
                  const tablist = scroller.querySelector(':scope > [role="tablist"]')
                  const tabs = Array.from(tablist.querySelectorAll(':scope > .tab'))
                  const activeTab = tablist.querySelector(':scope > .tab-active')
                  const tabContent = activeTab.nextElementSibling
                  const activeTabRect = activeTab.getBoundingClientRect()
                  const tabContentRect = tabContent.getBoundingClientRect()
                  const root = document.querySelector("[data-mission-control-jobs-root]")
                  return {
                    documentWidth: document.documentElement.scrollWidth,
                    viewportWidth: window.innerWidth,
                    rootWidth: root.getBoundingClientRect().width,
                    rootScrollWidth: root.scrollWidth,
                    rootClientWidth: root.clientWidth,
                    rootTop: root.getBoundingClientRect().top,
                    headingBottom: heading.getBoundingClientRect().bottom,
                    subnavigationTop: subnavigation.getBoundingClientRect().top,
                    activeTabBottom: activeTabRect.bottom,
                    activeTabWidth: activeTabRect.width,
                    activeTabBorderBottomWidth: parseFloat(getComputedStyle(activeTab).borderBottomWidth),
                    tabContentTop: tabContentRect.top,
                    tabContentBottom: tabContentRect.bottom,
                    tabContentWidth: tabContentRect.width,
                    tabContentBorderTopWidth: parseFloat(getComputedStyle(tabContent).borderTopWidth),
                    tabContentMarginTop: parseFloat(getComputedStyle(tabContent).marginTop),
                    activeTabCoversSharedEdge: document.elementFromPoint(
                      activeTabRect.left + activeTabRect.width / 2,
                      tabContentRect.top + 0.5
                    ) === activeTab,
                    rootBottom: root.getBoundingClientRect().bottom,
                    activeTabOwnsTabContent: activeTab.nextElementSibling === tabContent,
                    tabContentInsideTablist: tabContent.parentElement === tablist,
                    rootInsideTabContent: root.parentElement === tabContent,
                    tabContentIsSticky: tabContent.classList.contains("sticky"),
                    tabContentContain: getComputedStyle(tabContent).contain,
                    tabContentCount: tablist.querySelectorAll(':scope > .tab-content').length,
                    tabRowCount: new Set(tabs.map((tab) => Math.round(tab.getBoundingClientRect().top))).size,
                    scrollerScrollWidth: scroller.scrollWidth,
                    scrollerClientWidth: scroller.clientWidth
                  }
                }
              JAVASCRIPT
            end

            assert_operator geometry.fetch("documentWidth"), :<=, geometry.fetch("viewportWidth"),
              "Mission Control Jobs page overflow at #{width}px"
            assert_operator geometry.fetch("rootWidth"), :>, 0,
              "Mission Control Jobs content should be visible at #{width}px"
            assert_operator geometry.fetch("rootScrollWidth"), :>=, geometry.fetch("rootClientWidth")
            assert_operator geometry.fetch("subnavigationTop"), :>=, geometry.fetch("headingBottom"),
              "Mission Control Jobs heading should precede subnavigation at #{width}px"
            assert_in_delta geometry.fetch("activeTabBottom"), geometry.fetch("tabContentTop"), 1.5,
              "Mission Control Jobs active tab should connect to tab content at #{width}px"
            assert_in_delta 0, geometry.fetch("activeTabBorderBottomWidth"), 0.1,
              "Mission Control Jobs active tab should leave its bottom border open at #{width}px"
            assert_in_delta 1, geometry.fetch("tabContentBorderTopWidth"), 0.1,
              "Mission Control Jobs tab content should own the shared border at #{width}px"
            assert_in_delta(-1, geometry.fetch("tabContentMarginTop"), 0.1,
              "Mission Control Jobs tab content should collapse the shared border at #{width}px")
            assert geometry.fetch("activeTabCoversSharedEdge"),
              "Mission Control Jobs active tab should cover the shared border at #{width}px"
            assert geometry.fetch("activeTabOwnsTabContent"),
              "Mission Control Jobs active tab should immediately precede its content at #{width}px"
            assert geometry.fetch("tabContentInsideTablist"),
              "Mission Control Jobs tab content should be inside the tablist at #{width}px"
            assert geometry.fetch("rootInsideTabContent"),
              "Mission Control Jobs root should be wrapped by tab content at #{width}px"
            assert geometry.fetch("tabContentIsSticky"),
              "Mission Control Jobs tab content should be sticky at #{width}px"
            assert_equal "inline-size", geometry.fetch("tabContentContain"),
              "Mission Control Jobs tab content should use inline-size containment at #{width}px"
            assert_equal 1, geometry.fetch("tabContentCount"),
              "Mission Control Jobs should render only the active tab content at #{width}px"
            assert_equal 1, geometry.fetch("tabRowCount"),
              "Mission Control Jobs tabs should stay on one row at #{width}px"
            assert_operator geometry.fetch("rootTop"), :>=, geometry.fetch("tabContentTop"),
              "Mission Control Jobs subnavigation should precede content at #{width}px"
            assert_operator geometry.fetch("tabContentBottom"), :>=, geometry.fetch("rootBottom"),
              "Mission Control Jobs tab content should contain its body at #{width}px"
            assert_operator geometry.fetch("activeTabWidth"), :<, geometry.fetch("tabContentWidth"),
              "Mission Control Jobs active tab should not stretch across the content at #{width}px"
            assert_operator geometry.fetch("scrollerScrollWidth"), :>=, geometry.fetch("scrollerClientWidth"),
              "Mission Control Jobs scroll container should contain its tabs at #{width}px"
            if width <= 390
              assert_operator geometry.fetch("scrollerScrollWidth"), :>, geometry.fetch("scrollerClientWidth"),
                "Mission Control Jobs tabs should scroll horizontally at #{width}px"
            end

            find('[role="tab"]', text: /^Failed jobs/).click
            assert_selector '[data-layout="with-menu"] > div > h1', text: "Failed jobs", count: 1
            failed_geometry = page.driver.with_playwright_page do |playwright_page|
              playwright_page.evaluate(<<~JAVASCRIPT)
                () => {
                  const activeTab = document.querySelector('[role="tab"].tab-active')
                  const tabContent = activeTab.nextElementSibling
                  const activeTabRect = activeTab.getBoundingClientRect()
                  const tabContentRect = tabContent.getBoundingClientRect()
                  const tablist = activeTab.parentElement
                  const tabs = Array.from(tablist.querySelectorAll(':scope > .tab'))
                  const root = tabContent.querySelector("[data-mission-control-jobs-root]")
                  return {
                    activeTabBottom: activeTabRect.bottom,
                    activeTabBorderBottomWidth: parseFloat(getComputedStyle(activeTab).borderBottomWidth),
                    tabContentTop: tabContentRect.top,
                    tabContentBottom: tabContentRect.bottom,
                    tabContentBorderTopWidth: parseFloat(getComputedStyle(tabContent).borderTopWidth),
                    tabContentMarginTop: parseFloat(getComputedStyle(tabContent).marginTop),
                    activeTabCoversSharedEdge: document.elementFromPoint(
                      activeTabRect.left + activeTabRect.width / 2,
                      tabContentRect.top + 0.5
                    ) === activeTab,
                    rootBottom: root.getBoundingClientRect().bottom,
                    tabContentRadius: parseFloat(getComputedStyle(tabContent).borderStartStartRadius),
                    activeTabOwnsTabContent: tabContent.classList.contains("tab-content"),
                    tabContentIsSticky: tabContent.classList.contains("sticky"),
                    tabContentContain: getComputedStyle(tabContent).contain,
                    tabRowCount: new Set(tabs.map((tab) => Math.round(tab.getBoundingClientRect().top))).size
                  }
                }
              JAVASCRIPT
            end
            assert_in_delta failed_geometry.fetch("activeTabBottom"), failed_geometry.fetch("tabContentTop"), 1.5,
              "Mission Control Jobs middle tab should connect to tab content at #{width}px"
            assert_in_delta 0, failed_geometry.fetch("activeTabBorderBottomWidth"), 0.1,
              "Mission Control Jobs middle tab should leave its bottom border open at #{width}px"
            assert_in_delta 1, failed_geometry.fetch("tabContentBorderTopWidth"), 0.1,
              "Mission Control Jobs middle tab content should own the shared border at #{width}px"
            assert_in_delta(-1, failed_geometry.fetch("tabContentMarginTop"), 0.1,
              "Mission Control Jobs middle tab content should collapse the shared border at #{width}px")
            assert failed_geometry.fetch("activeTabCoversSharedEdge"),
              "Mission Control Jobs middle active tab should cover the shared border at #{width}px"
            assert failed_geometry.fetch("activeTabOwnsTabContent"),
              "Mission Control Jobs middle tab should immediately precede its content at #{width}px"
            assert failed_geometry.fetch("tabContentIsSticky"),
              "Mission Control Jobs middle tab content should be sticky at #{width}px"
            assert_equal "inline-size", failed_geometry.fetch("tabContentContain"),
              "Mission Control Jobs middle tab content should use inline-size containment at #{width}px"
            assert_equal 1, failed_geometry.fetch("tabRowCount"),
              "Mission Control Jobs middle tabs should stay on one row at #{width}px"
            assert_operator failed_geometry.fetch("tabContentRadius"), :>, 0,
              "Mission Control Jobs middle tab content should keep its leading corner at #{width}px"
            assert_operator failed_geometry.fetch("tabContentBottom"), :>=, failed_geometry.fetch("rootBottom"),
              "Mission Control Jobs middle tab content should contain its body at #{width}px"
          end
        ensure
          desktop = VIEWPORTS.fetch("desktop")
          page.current_window.resize_to(desktop.fetch("width"), desktop.fetch("height"))
        end

        def assert_job_operations_tabs_single_row
          geometry = page.driver.with_playwright_page do |playwright_page|
            playwright_page.evaluate(<<~JAVASCRIPT)
              () => {
                const tablist = document.querySelector('[aria-label="Job operations sections"] > .overflow-x-auto > [role="tablist"]')
                const tabs = Array.from(tablist.querySelectorAll(':scope > .tab'))
                const activeTab = tablist.querySelector(':scope > .tab-active')
                const tabContent = activeTab.nextElementSibling
                return {
                  rowCount: new Set(tabs.map((tab) => Math.round(tab.getBoundingClientRect().top))).size,
                  activeTabBottom: activeTab.getBoundingClientRect().bottom,
                  tabContentTop: tabContent.getBoundingClientRect().top
                }
              }
            JAVASCRIPT
          end
          assert_equal 1, geometry.fetch("rowCount"), "Mission Control Jobs desktop tabs must stay on one row"
          assert_in_delta geometry.fetch("activeTabBottom"), geometry.fetch("tabContentTop"), 1.5,
            "Mission Control Jobs desktop active tab must connect to tab content"
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
                  const shell = document.querySelector('[data-layout="with-menu"]')
                  const sidebar = shell.querySelector(":scope > aside").getBoundingClientRect()
                  const content = shell.querySelector(":scope > div").getBoundingClientRect()
                  const activeIcon = shell.querySelector('a.menu-active svg').getBoundingClientRect()
                  const footer = document.querySelector("footer.footer")
                  return {
                    documentWidth: document.documentElement.scrollWidth,
                    viewportWidth: window.innerWidth,
                    rootWidth: document.querySelector("[data-maintenance-tasks-root]").getBoundingClientRect().width,
                    sidebarTop: sidebar.top,
                    sidebarBottom: sidebar.bottom,
                    sidebarRight: sidebar.right,
                    contentTop: content.top,
                    contentLeft: content.left,
                    activeIconWidth: activeIcon.width,
                    activeIconHeight: activeIcon.height,
                    footerFlow: getComputedStyle(footer).gridAutoFlow
                  }
                }
              JAVASCRIPT
            end
            assert_operator geometry.fetch("documentWidth"), :<=, geometry.fetch("viewportWidth"),
              "Maintenance Tasks horizontal overflow at #{width}px"
            assert_operator geometry.fetch("rootWidth"), :>, 0,
              "Maintenance Tasks content should be visible at #{width}px"
            assert_in_delta 20, geometry.fetch("activeIconWidth"), 0.5,
              "Maintenance Tasks navigation icon width at #{width}px"
            assert_in_delta 20, geometry.fetch("activeIconHeight"), 0.5,
              "Maintenance Tasks navigation icon height at #{width}px"
            expected_footer_flow = width < 640 ? "row" : "column"
            assert_equal expected_footer_flow, geometry.fetch("footerFlow"),
              "Maintenance Tasks footer layout at #{width}px"
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
          T.must(singleton_class).define_method(:urlsafe_base64, T.must(original_method))
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
  runner = runner.sub("__ADDITIONAL_LOGIN_METHODS__", additional_login_methods.inspect)
  runner = runner.sub("__AVATAR__", avatar.inspect)
  runner = runner.sub("__API__", api.inspect)
  runner = runner.sub("__WEB_PUSH__", web_push.inspect)
  runner = runner.sub("__JOB_OPERATIONS__", job_operations.inspect)
  runner = runner.sub("__MAINTENANCE_TASKS__", maintenance_tasks.inspect)
  disabled_constants = []
  disabled_methods = []
  unless avatar
    disabled_constants << :AVATAR
    disabled_methods << :capture_avatar_scenarios
  end
  unless additional_login_methods.include?("siwe")
    disabled_constants << :ADDITIONAL_LOGIN_METHODS
    disabled_methods.concat(%i[
      capture_siwe_scenarios
      authenticate_with_siwe
      browser_post_json
    ])
  end
  unless web_push
    disabled_constants << :WEB_PUSH
    disabled_methods.concat(%i[capture_enabled_web_push reconnect_web_push_controller install_web_push_stub])
  end
  disabled_constants << :API unless api
  unless job_operations
    disabled_constants << :JOB_OPERATIONS
    disabled_methods.concat(%i[verify_job_operations_geometry assert_job_operations_tabs_single_row])
  end
  unless maintenance_tasks
    disabled_constants << :MAINTENANCE_TASKS
    disabled_methods << :verify_maintenance_tasks_geometry
  end

  unless disabled_constants.empty? && disabled_methods.empty?
    require "prism"
    result = Prism.parse(runner)
    raise "evidence capture runnerをRubyとして解析できません: #{result.errors.map(&:message).join(', ')}" unless result.success?

    contains_disabled_constant = lambda do |node|
      queue = [node]
      found = false
      until queue.empty? || found
        current = queue.shift
        found = current.is_a?(Prism::ConstantReadNode) && disabled_constants.include?(current.name)
        queue.concat(current.compact_child_nodes) unless found
      end
      found
    end
    removals = []
    queue = [result.value]
    until queue.empty?
      node = queue.shift
      remove = (node.is_a?(Prism::DefNode) && disabled_methods.include?(node.name)) ||
        (node.is_a?(Prism::IfNode) && contains_disabled_constant.call(node.predicate))
      if remove
        removals << [node.location.start_line - 1, node.location.end_line - 1]
      else
        queue.concat(node.compact_child_nodes)
      end
    end
    removed_lines = Array.new(runner.lines.length, false)
    removals.each do |start_line, end_line|
      (start_line..end_line).each { |line| removed_lines[line] = true }
    end
    runner = runner.lines.each_with_index.filter_map { |line, index| line unless removed_lines.fetch(index) }.join
  end
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

def configure_sorbet
  create_file "test/sorbet_test.rb", <<~'RUBY', force: true
    # frozen_string_literal: true

    require "test_helper"
    require "open3"

    class SorbetTest < ActiveSupport::TestCase
      TYPED_RUBY_PATTERNS = %w[
        app/controllers/**/*.rb
        app/helpers/**/*.rb
        app/models/**/*.rb
        app/policies/**/*.rb
        app/services/**/*.rb
        app/jobs/**/*.rb
        app/mailers/**/*.rb
        app/validators/**/*.rb
        config/**/*.rb
        lib/**/*.rb
        test/**/*.rb
        db/seeds.rb
      ].freeze

      STRICT_RUBY_PATHS = %w[
        app/services/admin_role_grant.rb
        app/services/avatar_image_policy.rb
        app/services/avatar_upload.rb
        app/services/push_notification_payload.rb
        app/services/push_notifier.rb
        app/services/vapid_configuration.rb
        lib/application_identity.rb
      ].freeze

      APPLICATION_DSL_RBI_SOURCES = {
        "api_credential" => "app/models/api_credential.rb",
        "application_mailer" => "app/mailers/application_mailer.rb",
        "faq" => "app/models/faq.rb",
        "footer_setting" => "app/models/footer_setting.rb",
        "page" => "app/models/page.rb",
        "profile" => "app/models/profile.rb",
        "push_notification_job" => "app/jobs/push_notification_job.rb",
        "push_subscription" => "app/models/push_subscription.rb",
        "siwe_challenge" => "app/models/siwe_challenge.rb",
        "siwe_identity" => "app/models/siwe_identity.rb",
        "user" => "app/models/user.rb",
        "user_role" => "app/models/user_role.rb"
      }.freeze

      test "application and test Ruby files use typed true or stricter" do
        paths = TYPED_RUBY_PATTERNS.flat_map { |pattern| Rails.root.glob(pattern) }.uniq.sort

        assert_predicate paths, :any?
        paths.each do |path|
          assert_match(/\A# typed: (?:true|strict)\n\z/, path.open(&:gets), "#{path.relative_path_from(Rails.root)} must start with # typed: true or stricter")
        end
      end

      test "pure application services use typed strict" do
        expected = STRICT_RUBY_PATHS.select { |path| Rails.root.join(path).exist? }

        assert_predicate expected, :any?
        expected.each do |path|
          assert_equal "# typed: strict\n", Rails.root.join(path).open(&:gets), "#{path} must start with # typed: strict"
        end
      end

      test "Tapioca has no unresolved constants" do
        todo = Rails.root.join("sorbet/rbi/todo.rbi")
        assert_not_predicate todo, :exist?, "Resolve missing constants instead of committing sorbet/rbi/todo.rbi placeholders."
      end

      test "application DSL RBI files exist for supported domain classes" do
        expected = APPLICATION_DSL_RBI_SOURCES.select { |_name, source| Rails.root.join(source).exist? }

        assert_predicate expected, :any?
        expected.each_key do |name|
          assert_path_exists Rails.root.join("sorbet/rbi/dsl/#{name}.rbi")
        end
      end

      test "gem RBI files are up to date" do
        assert_command_succeeds(
          "bin/tapioca", "gems", "--verify",
          remediation: "Run bin/tapioca gems and commit the updated RBI files."
        )
      end

      test "Rails DSL RBI files are up to date" do
        assert_command_succeeds(
          "bin/tapioca", "dsl", "--verify", "--environment=test",
          environment: { "RAILS_ENV" => "test" },
          remediation: "Run RAILS_ENV=test bin/tapioca dsl --environment=test and commit the updated RBI files."
        )
      end

      test "RBI shims do not duplicate generated definitions" do
        assert_command_succeeds(
          "bin/tapioca", "check-shims",
          remediation: "Remove the duplicate definitions reported by bin/tapioca check-shims."
        )
      end

      test "Sorbet type checking succeeds" do
        assert_command_succeeds(
          "bundle", "exec", "srb", "tc",
          remediation: "Run bundle exec srb tc and fix the reported type errors."
        )
      end

      private

      def assert_command_succeeds(*command, environment: {}, remediation:)
        stdout, stderr, status = T.unsafe(Open3).capture3(environment, *command, chdir: Rails.root.to_s)
        output = [stdout, stderr].reject(&:empty?).join("\n")

        assert status.success?, <<~MESSAGE
          #{remediation}

          #{output}
        MESSAGE
      end
    end
  RUBY
end

def configure_application_typechecking
  patterns = %w[
    app/controllers/**/*.rb
    app/helpers/**/*.rb
    app/models/**/*.rb
    app/policies/**/*.rb
    app/services/**/*.rb
    app/jobs/**/*.rb
    app/mailers/**/*.rb
    app/validators/**/*.rb
    config/**/*.rb
    lib/**/*.rb
    test/**/*.rb
    db/seeds.rb
  ]
  paths = patterns.flat_map { |pattern| Dir.glob(pattern) }.uniq.sort
  raise "application typecheckingの対象Ruby fileが見つかりません" if paths.empty?

  strict_paths = %w[
    app/services/admin_role_grant.rb
    app/services/avatar_image_policy.rb
    app/services/avatar_upload.rb
    app/services/push_notification_payload.rb
    app/services/push_notifier.rb
    app/services/vapid_configuration.rb
    lib/application_identity.rb
  ].select { |path| File.exist?(path) }

  paths.each do |path|
    strictness = strict_paths.include?(path) ? "strict" : "true"
    prepend_to_file path, "# typed: #{strictness}\n"
  end
end

def configure_config_typechecking
  prepend_to_file "config/puma.rb", "T.bind(self, Puma::DSL)\n\n"
  prepend_to_file "config/importmap.rb", "T.bind(self, Importmap::Map)\n\n"

  require "prism"
  path = "config/ci.rb"
  source = File.binread(path)
  result = Prism.parse(source)
  raise "#{path}をRubyとして解析できません: #{result.errors.map(&:message).join(', ')}" unless result.success?

  calls = []
  queue = [result.value]
  until queue.empty?
    node = queue.shift
    if node.is_a?(Prism::CallNode) && node.name == :run &&
        node.receiver.is_a?(Prism::ConstantReadNode) && node.receiver.name == :CI &&
        node.block.is_a?(Prism::BlockNode)
      calls << node
    end
    queue.concat(node.compact_child_nodes)
  end
  raise "#{path}のCI.run blockが一意ではありません" unless calls.one?

  call = calls.first
  block = call.block
  raise "#{path}のCI.run blockがdo...end形式ではありません" unless source.byteslice(block.opening_loc.start_offset, block.opening_loc.length) == "do"

  edits = [
    [call.receiver.location.start_offset, call.receiver.location.end_offset, "ActiveSupport::ContinuousIntegration"],
    [block.opening_loc.end_offset, block.opening_loc.end_offset, "\n  T.bind(self, ActiveSupport::ContinuousIntegration)\n"]
  ]
  edits.sort_by { |start_offset, _end_offset, _replacement| -start_offset }.each do |start_offset, end_offset, replacement|
    source = source.byteslice(0, start_offset) + replacement + source.byteslice(end_offset..)
  end
  File.binwrite(path, source)
end

def configure_sorbet_shims
  avatar_bindings = if VALUES.fetch("profile_features").include?("avatar")
    <<~RBI
      module AvatarHelper
        include ActionView::Helpers

        sig do
          params(
            name: String,
            variant: Symbol,
            colors: T::Array[String],
            size: Integer,
            svg_attributes: T.untyped
          ).returns(String)
        end
        def boring_avatar(name, variant:, colors:, size:, **svg_attributes); end
      end

      class Vips::Image
        sig { params(width: Integer, height: Integer, bands: Integer).returns(Vips::Image) }
        def self.black(width, height, bands:); end

        sig { params(images: T::Array[Vips::Image], across: Integer).returns(Vips::Image) }
        def self.arrayjoin(images, across:); end
      end
    RBI
  else
    ""
  end
  maintenance_bindings = if VALUES.fetch("maintenance_tasks") == "enable"
    <<~RBI
      module Admin::MaintenanceTasksHelper
        include ActionView::Helpers
        include MaintenanceTasks::TasksHelper
      end
    RBI
  else
    ""
  end

  create_file "sorbet/rbi/shims/framework_bindings.rbi", <<~RBI, force: true
    # typed: true

    class Rails::Application
      sig { params(name: T.any(String, Symbol), env: T.untyped).returns(T.untyped) }
      def self.config_for(name, env: T.unsafe(nil)); end
    end

    class ActiveRecord::Base
      extend Devise::Models
    end

    class ActiveSupport::TestCase
      include ActiveRecord::TestFixtures
    end

    class ActionDispatch::SystemTestCase
      include GeneratedUrlHelpersModule
      include GeneratedPathHelpersModule
    end

    class ApplicationController
      include ActionPolicy::Controller
      include Devise::Controllers::Helpers

      sig { returns(T.nilable(User)) }
      def current_user; end

      sig { params(options: T.untyped).void }
      def authenticate_user!(options = T.unsafe(nil)); end

      sig { returns(T::Boolean) }
      def user_signed_in?; end

      sig { params(resource: User).void }
      def remember_me(resource); end
    end

    module Warden
      sig { void }
      def self.test_reset!; end
    end

    class DeviseController < ActionController::Base
      include Devise::Controllers::Helpers
      include Devise::Controllers::SignInOut
      include GeneratedUrlHelpersModule
      include GeneratedPathHelpersModule

      sig { returns(T.nilable(User)) }
      def current_user; end

      sig { params(options: T.untyped).void }
      def authenticate_user!(options = T.unsafe(nil)); end

      sig { returns(T::Boolean) }
      def user_signed_in?; end

      sig { params(resource: User).void }
      def remember_me(resource); end
    end

    module ApplicationHelper
      include ActionView::Helpers
    end

    module ApplicationHelper::ApplicationRoutes
      include GeneratedUrlHelpersModule
      include GeneratedPathHelpersModule
    end

    #{avatar_bindings}
    #{maintenance_bindings}

    class User
      include Devise::Models::Authenticatable
    end

    class ActiveStorage::Attached::One
      sig { returns(ActiveStorage::Blob) }
      def blob; end

      sig do
        params(transformations: T.untyped)
          .returns(T.any(ActiveStorage::Variant, ActiveStorage::VariantWithRecord))
      end
      def variant(transformations); end
    end

    class ActionDispatch::IntegrationTest
      sig do
        params(
          type: Symbol,
          with: T.class_of(ApplicationPolicy),
          block: T.proc.void
        ).void
      end
      def assert_have_authorized_scope(type:, with:, &block); end
    end

    module ContentManagementAuthenticationTestSupport
      include Devise::Test::IntegrationHelpers
    end

    class UserPolicy
      extend T::Sig

      sig do
        params(
          block: T.proc
            .bind(UserPolicy)
            .params(relation: User::PrivateRelation)
            .returns(User::PrivateRelation)
        ).void
      end
      def self.relation_scope(&block); end
    end
  RBI

  if VALUES.fetch("profile_features").include?("avatar")
    create_file "sorbet/rbi/shims/boring_avatars.rbi", <<~'RBI', force: true
      # typed: true

      # boring_avatars defines these aliases on BoringAvatars, while its Rails
      # binding signatures resolve the unqualified names in ViewHelper.
      module BoringAvatars::Bindings::Rails::ViewHelper
        RailsAttributeValue = T.type_alias { BoringAvatars::RailsAttributeValue }
        Size = T.type_alias { BoringAvatars::Size }
        Variant = T.type_alias { BoringAvatars::Variant }
      end
    RBI
  end

  create_file "sorbet/rbi/shims/bundler_connection_pool.rbi", <<~'RBI', force: true
    # typed: true

    # Ruby ships Bundler with a vendored connection pool. Tapioca can observe
    # its Process fork hook while compiling FFI or HTTPX, but Bundler has no Gem RBI.
    module Bundler
      class ConnectionPool
        module ForkTracker; end
      end
    end
  RBI
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
  development_databases = {
    "primary" => { "database" => "storage/development.sqlite3" },
    "storage" => { "database" => "storage/development_storage.sqlite3", "migrations_paths" => "db/storage_migrate" }
  }
  if VALUES.fetch("active_job") == "solid_queue"
    development_databases["queue"] = {
      "database" => "storage/development_queue.sqlite3",
      "migrations_paths" => "db/queue_migrate"
    }
  end
  config = {
    "default" => { "adapter" => "sqlite3", "pool" => "<%= ENV.fetch(\"RAILS_MAX_THREADS\", 5) %>", "timeout" => 5000 },
    "development" => development_databases,
    "test" => test_databases,
    "production" => production
  }
  database_yaml = YAML.dump(config, line_width: -1)
    .sub("default:\n", "default: &default\n")
    .gsub(/^  ([a-z]+):\n(?=    (?:adapter|database):)/, "  \\1:\n    <<: *default\n")
  create_file "config/database.yml", database_yaml, force: true
end

def configure_dokploy
  processes = ["web: bin/thrust bin/rails server"]
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
    EXPOSE 80
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
  configure_sorbet
  configure_application_identity
  configure_image_delivery
  install_devise
  install_siwe if VALUES.fetch("additional_login_methods").include?("siwe")
  configure_roles
  configure_content_management
  install_image_cropper if VALUES.fetch("profile_features").include?("avatar")
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
  configure_config_typechecking
  run_checked "bundle exec tapioca init"
  append_to_file "sorbet/tapioca/require.rb", <<~RUBY

    require "action_policy/test_helper"
    require "action_mailer"
    require "mail"
    require "webauthn/fake_client"
  RUBY
  run_checked "bin/tapioca gem action_policy actionmailer mail webauthn"
  append_to_file "sorbet/config", <<~CONFIG
    --suppress-payload-superclass-redefinition-for=Net::IMAP::Literal
    --suppress-payload-superclass-redefinition-for=Net::IMAP::QuotedString
  CONFIG
  run_checked "RAILS_ENV=test bin/rails db:prepare"
  run_checked "RAILS_ENV=test bin/tapioca dsl --environment=test"
  configure_application_typechecking
  configure_sorbet_shims
  remove_file "sorbet/rbi/todo.rbi"
  run_checked "bin/tapioca gems --verify"
  run_checked "RAILS_ENV=test bin/tapioca dsl --verify --environment=test"
  run_checked "bin/tapioca check-shims"
  run_checked "bundle exec srb tc"
  run_checked "bin/rails tailwindcss:build"
  run_checked "bundle binstubs rubocop"
  run_checked "bin/rubocop -a"
end
