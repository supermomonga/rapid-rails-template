# frozen_string_literal: true

require "json"
require "yaml"
require "digest"

CONFIG_PATH = ENV.fetch("RAPID_RAILS_TEMPLATE_CONFIG")
PLAN = JSON.parse(File.read(CONFIG_PATH), freeze: true)
VALUES = PLAN.fetch("configuration").fetch("values")
EXPECTED_KEYS = %w[pwa web_push active_job solid_cache account_authentication profile_features api action_cable mail action_text deployment].freeze
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
gem "haikunator" if (VALUES.fetch("profile_features") & %w[screen_name display_name]).any?
gem "boring_avatars", "~> 0.1.0", require: "boring_avatars/bindings/rails" if VALUES.fetch("profile_features").include?("avatar")
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
  generate "devise:views", "-v", "sessions", "registrations", "passwords"
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
        return head :unauthorized unless message.uri == request.base_url && message.chain_id.to_i.positive?
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
  create_file "config/locales/ja.yml", <<~YAML, force: true
    ja:
      accounts:
        destroy:
          notice: アカウントを削除しました
  YAML

  create_file "app/javascript/controllers/siwe_sign_in_controller.js", <<~JAVASCRIPT
    import { Controller } from "@hotwired/stimulus"

    export default class extends Controller {
      static targets = ["error"]

      async signIn() {
        this.errorTarget.classList.add("hidden")
        this.errorTarget.textContent = ""

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
  account_navigation_count = 2 + (VALUES.fetch("profile_features").any? ? 1 : 0) + (VALUES.fetch("api") == "enable" ? 1 : 0)
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

        get account_url
        assert_response :success
        assert_select '[data-layout="account"].mx-auto.w-full.max-w-6xl.px-5', count: 1
        assert_select 'nav[aria-label="アカウントメニュー"] > .menu > li > a', count: #{account_navigation_count}
        assert_select 'nav[aria-label="アカウントメニュー"] > .menu > li > a > svg.size-5[aria-hidden="true"][data-slot="icon"]', count: #{account_navigation_count}
        assert_select 'nav[aria-label="アカウントメニュー"] a[href=?]', root_path, count: 0
        assert_select '.badge', text: 'ID', count: 0

        get edit_account_url
        assert_response :success
        assert_select 'nav[aria-label="アカウントメニュー"] a.menu-active[aria-current="page"][href=?]', edit_account_path, count: 1
        assert_select '.list .badge', text: 'ID', count: 1
        assert_select '.list p.font-semibold', text: key.address.to_s.downcase, count: 1
        assert_select '.card-actions form[action=?][method="post"]', account_path, count: 1 do
          assert_select 'input[name="_method"][value="delete"]', count: 1
          assert_select 'button.btn.btn-error[data-turbo-confirm]', text: 'アカウントを削除', count: 1
        end

        assert_difference(['User.count', 'Session.count'], -1) do
          delete account_url
        end
        assert_redirected_to root_url
        follow_redirect!
        assert_select '.alert.alert-success', text: 'アカウントを削除しました', count: 1
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
  model_lines << "  has_one_attached :avatar" if avatar_enabled
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
  create_file "app/models/profile.rb", <<~RUBY, force: true
    class Profile < ApplicationRecord
    #{model_lines.join("\n")}
    #{generated_name_methods}
    end
  RUBY

  inject_into_class "app/models/user.rb", "User", <<~RUBY
      has_one :profile, dependent: :destroy
      after_create :create_profile!

  RUBY

  profile_owner = devise ? "current_user" : "Current.user"
  authentication = devise ? "  before_action :authenticate_user!\n" : ""
  permitted_features = features.map { |feature| ":#{feature}" }.join(", ")
  destroy_avatar_action = if avatar_enabled
    <<~RUBY

        def destroy_avatar
          #{profile_owner}.profile.avatar.purge if #{profile_owner}.profile.avatar.attached?
          redirect_to profile_path, notice: I18n.t("profiles.avatar.destroy.notice", locale: :ja), status: :see_other
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
          redirect_to profile_path, notice: I18n.t("profiles.update.notice", locale: :ja), status: :see_other
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

  locale_path = "config/locales/ja.yml"
  locale = File.exist?(locale_path) ? YAML.safe_load_file(locale_path) : {}
  locale["ja"] ||= {}
  locale["ja"]["profiles"] = { "update" => { "notice" => "プロフィールを更新しました" } }
  if avatar_enabled
    locale["ja"]["profiles"]["avatar"] = { "destroy" => { "notice" => "アバター画像を削除しました" } }
  end
  create_file locale_path, YAML.dump(locale, line_width: -1), force: true

  if avatar_enabled
    create_file "app/helpers/avatar_helper.rb", <<~RUBY, force: true
      module AvatarHelper
        BORING_AVATAR_COLORS = %w[#3ea8ff #0f83fd #10b981 #f59e0b #f43f5e].freeze

        def profile_avatar(profile, size:, alt:)
          if profile.avatar.attached?
            image_tag profile.avatar, alt: alt, class: "object-cover"
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

    create_file "test/helpers/avatar_helper_test.rb", <<~RUBY, force: true
      require "test_helper"
      require "stringio"

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
          profile.avatar.attach(io: StringIO.new("avatar"), filename: "avatar.png", content_type: "image/png")

          rendered = profile_avatar(profile, size: 64, alt: "現在のアバター")

          assert_includes rendered, "<img"
          assert_not_includes rendered, "<svg"
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
        assert_includes profile.errors[:screen_name], "is invalid"
      end

      test "screen_name is required and unique" do
        profile = profiles(:two)
        profile.screen_name = nil

        assert_not profile.valid?
        assert_includes profile.errors[:screen_name], "can't be blank"

        profile.screen_name = profiles(:one).screen_name

        assert_not profile.valid?
        assert_includes profile.errors[:screen_name], "has already been taken"
      end
    RUBY
  end
  if features.include?("display_name")
    profile_tests << <<~RUBY
      test "display_name is required and unique" do
        profile = profiles(:two)
        profile.display_name = nil

        assert_not profile.valid?
        assert_includes profile.errors[:display_name], "can't be blank"

        profile.display_name = profiles(:one).display_name

        assert_not profile.valid?
        assert_includes profile.errors[:display_name], "has already been taken"
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
  create_file "test/models/profile_test.rb", <<~RUBY, force: true
    require "test_helper"

    class ProfileTest < ActiveSupport::TestCase
    #{profile_tests.join("\n")}end
  RUBY

  form_fields = []
  if features.include?("screen_name")
    form_fields << <<~ERB
      <fieldset class="fieldset">
        <legend class="fieldset-legend"><%= form.label :screen_name, "スクリーンネーム" %></legend>
        <%= form.text_field :screen_name, class: "input input-rapid w-full", pattern: "[a-z0-9_]+", autocomplete: "username", required: true %>
        <p class="label">小文字の英数字とアンダースコアが使えます。</p>
      </fieldset>
    ERB
  end
  if features.include?("display_name")
    form_fields << <<~ERB
      <fieldset class="fieldset">
        <legend class="fieldset-legend"><%= form.label :display_name, "表示名" %></legend>
        <%= form.text_field :display_name, class: "input input-rapid w-full", autocomplete: "name", required: true %>
      </fieldset>
    ERB
  end
  if avatar_enabled
    form_fields << <<~ERB
      <fieldset class="fieldset">
        <legend class="fieldset-legend"><%= form.label :avatar, "アバター画像" %></legend>
        <%= form.file_field :avatar, class: "file-input w-full", accept: "image/*" %>
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
        <%= link_to "キャンセル", profile_path, class: "btn btn-ghost btn-rapid" %>
        <%= form.submit "保存", class: "btn btn-primary btn-rapid" %>
      </div>
    <% end %>
  ERB

  profile_rows = []
  if avatar_enabled
    profile_rows << <<~ERB
      <li class="list-row">
        <span class="text-sm text-neutral">アバター</span>
        <div class="avatar">
          <div class="w-16 rounded-full">
            <%= profile_avatar(@profile, size: 64, alt: "現在のアバター") %>
          </div>
        </div>
      </li>
    ERB
  end
  if features.include?("display_name")
    profile_rows << <<~ERB
      <li class="list-row">
        <span class="text-sm text-neutral">表示名</span>
        <strong><%= @profile.display_name.presence || "未設定" %></strong>
      </li>
    ERB
  end
  if features.include?("screen_name")
    profile_rows << <<~ERB
      <li class="list-row">
        <span class="text-sm text-neutral">スクリーンネーム</span>
        <strong><%= @profile.screen_name.present? ? "@\#{@profile.screen_name}" : "未設定" %></strong>
      </li>
    ERB
  end
  profile_rows = profile_rows.join("\n").lines.map { |line| "        #{line}" }.join
  avatar_delete_section = if avatar_enabled
    <<~ERB

      <% if @profile.avatar.attached? %>
        <section class="card card-border border-error bg-base-100 shadow-none">
          <div class="card-body">
            <h2 class="card-title text-base leading-[1.5]">アバター画像の削除</h2>
            <p class="text-sm text-neutral">設定済みの画像を削除し、IDから生成したアバターへ戻します。</p>
            <div class="card-actions justify-start">
              <%= button_to "設定済み画像を削除", profile_avatar_path, method: :delete, class: "btn btn-outline btn-error btn-rapid", data: { turbo_confirm: "設定済みのアバター画像を削除しますか？" } %>
            </div>
          </div>
        </section>
      <% end %>
    ERB
  else
    ""
  end
  create_file "app/views/profiles/show.html.erb", <<~ERB, force: true
    <% content_for :title, "プロフィール | Rapid Rails" %>
    <div class="space-y-6">
      <header>
        <p class="text-sm font-semibold text-primary">Profile</p>
        <h1 class="mt-1 text-2xl font-bold leading-[1.5]">プロフィール</h1>
      </header>

      <section class="card card-border border-base-300 bg-base-100 shadow-none">
        <div class="card-body">
          <ul class="list">
    #{profile_rows}      </ul>
          <div class="card-actions justify-end">
            <%= link_to "プロフィールを編集", edit_profile_path, class: "btn btn-primary btn-outline btn-rapid" %>
          </div>
        </div>
      </section>
    </div>
  ERB

  create_file "app/views/profiles/edit.html.erb", <<~ERB, force: true
    <% content_for :title, "プロフィール編集 | Rapid Rails" %>
    <div class="space-y-6">
      <header>
        <p class="text-sm font-semibold text-primary">Profile</p>
        <h1 class="mt-1 text-2xl font-bold leading-[1.5]">プロフィール編集</h1>
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

      async copy() {
        await navigator.clipboard.writeText(this.sourceTarget.value)
        this.buttonTarget.textContent = "コピーしました"
      }
    }
  JAVASCRIPT

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
        <legend class="fieldset-legend text-sm font-semibold leading-[1.5]"><%= form.label :name, "名前" %></legend>
        <%= form.text_field :name, required: true, autocomplete: "off", class: "input input-rapid w-full" %>
        <p class="label">利用用途が分かる名前を入力してください。</p>
      </fieldset>
      <div class="flex flex-col gap-3 sm:flex-row">
        <%= form.submit class: "btn btn-primary btn-rapid" %>
        <%= link_to "キャンセル", api_credential.persisted? ? api_credential_path(api_credential) : api_credentials_path, class: "btn btn-outline btn-rapid" %>
      </div>
    <% end %>
  ERB

  create_file "app/views/api_credentials/index.html.erb", <<~ERB, force: true
    <% content_for :title, "APIキーの管理 | Rapid Rails" %>
    <div class="space-y-6">
      <header class="flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
        <div>
          <p class="text-sm font-semibold text-primary">API credentials</p>
          <h1 class="mt-1 text-2xl font-bold leading-[1.5]">APIキーの管理</h1>
          <p class="mt-2 text-sm text-neutral">アプリケーションからAPIへ接続するためのcredentialを管理します。</p>
        </div>
        <%= link_to "APIキーを作成", new_api_credential_path, class: "btn btn-primary btn-rapid" %>
      </header>

      <section class="card card-border border-base-300 bg-base-100 shadow-none">
        <div class="card-body p-5 sm:p-6">
          <% if @api_credentials.any? %>
            <div class="overflow-x-auto">
              <table class="table">
                <thead><tr><th>名前</th><th>API key</th><th>最終利用</th><th></th></tr></thead>
                <tbody>
                  <% @api_credentials.each do |credential| %>
                    <tr>
                      <td class="font-semibold"><%= credential.name %></td>
                      <td>
                        <div class="join w-80" data-controller="clipboard">
                          <input type="text" value="<%= credential.api_key %>" readonly autocomplete="off" aria-label="<%= credential.name %>のAPI key" class="input join-item min-w-0 flex-1 font-mono" data-clipboard-target="source">
                          <button type="button" class="btn join-item" data-clipboard-target="button" data-action="clipboard#copy">コピー</button>
                        </div>
                      </td>
                      <td><%= credential.last_used_at ? l(credential.last_used_at, format: :short) : "未使用" %></td>
                      <td><%= link_to "詳細", api_credential_path(credential), class: "btn btn-outline btn-sm" %></td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>
          <% else %>
            <div class="alert alert-info alert-soft" role="status"><span>APIキーはまだありません。</span></div>
          <% end %>
        </div>
      </section>
    </div>
  ERB

  create_file "app/views/api_credentials/show.html.erb", <<~ERB, force: true
    <% content_for :title, "APIキー詳細 | Rapid Rails" %>
    <div class="space-y-6">
      <header>
        <p class="text-sm font-semibold text-primary">API credential</p>
        <h1 class="mt-1 text-2xl font-bold leading-[1.5]"><%= @api_credential.name %></h1>
      </header>

      <% if @api_secret.present? %>
        <div class="alert alert-warning alert-vertical grid-cols-1 justify-items-stretch" role="status">
          <p class="font-bold">ApiSecretはこの画面で一度だけ表示されます。</p>
          <fieldset class="fieldset w-full" data-controller="clipboard">
            <legend class="fieldset-legend">API Secret</legend>
            <div class="join w-full">
              <input type="text" value="<%= @api_secret %>" readonly autocomplete="off" aria-label="API Secret" class="input join-item min-w-0 flex-1 font-mono" data-clipboard-target="source">
              <button type="button" class="btn join-item" data-clipboard-target="button" data-action="clipboard#copy">コピー</button>
            </div>
          </fieldset>
        </div>
      <% end %>

      <section class="card card-border border-base-300 bg-base-100 shadow-none">
        <div class="card-body p-5 sm:p-6">
          <h2 class="card-title text-base leading-[1.5]">Credential情報</h2>
          <div class="mt-3 grid gap-4">
            <fieldset class="fieldset w-full" data-controller="clipboard">
              <legend class="fieldset-legend">API key</legend>
              <div class="join w-full">
                <input type="text" value="<%= @api_credential.api_key %>" readonly autocomplete="off" aria-label="API key" class="input join-item min-w-0 flex-1 font-mono" data-clipboard-target="source">
                <button type="button" class="btn join-item" data-clipboard-target="button" data-action="clipboard#copy">コピー</button>
              </div>
            </fieldset>
            <dl>
            <div><dt class="text-sm text-neutral">最終利用</dt><dd><%= @api_credential.last_used_at ? l(@api_credential.last_used_at, format: :short) : "未使用" %></dd></div>
            </dl>
          </div>
          <div class="card-actions mt-4 justify-start">
            <%= link_to "編集", edit_api_credential_path(@api_credential), class: "btn btn-outline btn-rapid" %>
            <%= button_to "ApiSecretを再発行", revoke_api_credential_path(@api_credential), method: :patch, class: "btn btn-warning btn-outline btn-rapid", data: { turbo_confirm: "現在のApiSecretは無効になります。再発行しますか？" } %>
            <%= button_to "削除", api_credential_path(@api_credential), method: :delete, class: "btn btn-error btn-outline btn-rapid", data: { turbo_confirm: "このAPIキーを削除しますか？" } %>
          </div>
        </div>
      </section>
      <%= link_to "APIキー一覧へ", api_credentials_path, class: "btn btn-outline btn-rapid" %>
    </div>
  ERB

  create_file "app/views/api_credentials/new.html.erb", <<~ERB, force: true
    <% content_for :title, "APIキーを作成 | Rapid Rails" %>
    <div class="space-y-6">
      <header><p class="text-sm font-semibold text-primary">New credential</p><h1 class="mt-1 text-2xl font-bold leading-[1.5]">APIキーを作成</h1></header>
      <section class="card card-border border-base-300 bg-base-100 shadow-none"><div class="card-body p-5 sm:p-6"><%= render "form", api_credential: @api_credential %></div></section>
    </div>
  ERB

  create_file "app/views/api_credentials/edit.html.erb", <<~ERB, force: true
    <% content_for :title, "APIキーを編集 | Rapid Rails" %>
    <div class="space-y-6">
      <header><p class="text-sm font-semibold text-primary">Edit credential</p><h1 class="mt-1 text-2xl font-bold leading-[1.5]">APIキーを編集</h1></header>
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
            get session_nonce_url
            nonce = response.parsed_body.fetch("nonce")
            key = Eth::Key.new
            message = Siwe::Message.new(
              domain: "www.example.com",
              address: key.address.to_s,
              uri: "http://www.example.com",
              chain_id: 1,
              nonce: nonce,
              issued_at: Time.current.iso8601,
              statement: "Sign in to www.example.com"
            ).prepare_message
            post session_url, params: { message: message, signature: key.personal_sign(message) }, as: :json
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
        assert_select 'button[data-action="clipboard#copy"]', text: "コピー", count: 2
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
        assert_select 'table.table input[aria-label="BatchのAPI key"][readonly][value=?]', credential.api_key, count: 1
        assert_select 'table.table button[data-action="clipboard#copy"]', text: "コピー", count: 1

        assert_difference("ApiCredential.count", -1) do
          delete api_credential_url(credential)
        end
        assert_redirected_to api_credentials_url
      end
    end
  RUBY
end

def configure_devise_views
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
        <li><%= link_to "ログイン画面へ", new_session_path(resource_name) %></li>
      <% end %>
      <% if devise_mapping.registerable? && controller_name != "registrations" %>
        <li><%= link_to "アカウントを作成", new_registration_path(resource_name) %></li>
      <% end %>
      <% if devise_mapping.recoverable? && controller_name != "passwords" && controller_name != "registrations" %>
        <li><%= link_to "パスワードをお忘れですか？", new_password_path(resource_name) %></li>
      <% end %>
    </ul>
  ERB

  create_file "app/views/devise/sessions/new.html.erb", <<~ERB, force: true
    <% content_for :title, "ログイン | Rapid Rails" %>
    <header class="mb-8">
      <p class="text-sm font-semibold text-primary">Welcome back</p>
      <h1 class="mt-2 text-2xl font-bold leading-[1.5]">ログイン</h1>
      <p class="mt-2 text-sm text-neutral">登録済みのメールアドレスとパスワードを入力してください。</p>
    </header>

    <%= form_for(resource, as: resource_name, url: session_path(resource_name), html: { class: "space-y-5" }) do |f| %>
      <fieldset class="fieldset">
        <legend class="fieldset-legend text-sm font-semibold leading-[1.5]"><%= f.label :email, "メールアドレス" %></legend>
        <%= f.email_field :email, autofocus: true, autocomplete: "email", required: true, class: "input input-rapid w-full" %>
      </fieldset>
      <fieldset class="fieldset">
        <legend class="fieldset-legend text-sm font-semibold leading-[1.5]"><%= f.label :password, "パスワード" %></legend>
        <%= f.password_field :password, autocomplete: "current-password", required: true, class: "input input-rapid w-full" %>
      </fieldset>
      <% if devise_mapping.rememberable? %>
        <label class="label cursor-pointer justify-start gap-3 text-base-content">
          <%= f.check_box :remember_me, class: "checkbox checkbox-sm" %>
          <span>ログイン状態を保持する</span>
        </label>
      <% end %>
      <%= f.submit "ログイン", class: "btn btn-primary btn-block btn-rapid hover:border-secondary hover:bg-secondary" %>
    <% end %>

    <%= render "devise/shared/links" %>
  ERB

  create_file "app/views/devise/registrations/new.html.erb", <<~ERB, force: true
    <% content_for :title, "アカウント作成 | Rapid Rails" %>
    <header class="mb-8">
      <p class="text-sm font-semibold text-primary">Get started</p>
      <h1 class="mt-2 text-2xl font-bold leading-[1.5]">アカウント作成</h1>
      <p class="mt-2 text-sm text-neutral">開発を始めるためのアカウントを作成します。</p>
    </header>

    <%= form_for(resource, as: resource_name, url: registration_path(resource_name), html: { class: "space-y-5" }) do |f| %>
      <%= render "devise/shared/error_messages", resource: resource %>
      <fieldset class="fieldset">
        <legend class="fieldset-legend text-sm font-semibold leading-[1.5]"><%= f.label :email, "メールアドレス" %></legend>
        <%= f.email_field :email, autofocus: true, autocomplete: "email", required: true, class: "input input-rapid w-full" %>
      </fieldset>
      <fieldset class="fieldset">
        <legend class="fieldset-legend text-sm font-semibold leading-[1.5]"><%= f.label :password, "パスワード" %></legend>
        <%= f.password_field :password, autocomplete: "new-password", required: true, class: "input input-rapid w-full" %>
        <% if @minimum_password_length %>
          <p class="label text-sm text-neutral"><%= @minimum_password_length %>文字以上で入力してください。</p>
        <% end %>
      </fieldset>
      <fieldset class="fieldset">
        <legend class="fieldset-legend text-sm font-semibold leading-[1.5]"><%= f.label :password_confirmation, "パスワード（確認）" %></legend>
        <%= f.password_field :password_confirmation, autocomplete: "new-password", required: true, class: "input input-rapid w-full" %>
      </fieldset>
      <%= f.submit "アカウントを作成", class: "btn btn-primary btn-block btn-rapid hover:border-secondary hover:bg-secondary" %>
    <% end %>

    <%= render "devise/shared/links" %>
  ERB

  create_file "app/views/devise/registrations/edit.html.erb", <<~ERB, force: true
    <% content_for :title, "アカウント設定 | Rapid Rails" %>
    <div class="space-y-6">
      <header>
        <p class="text-sm font-semibold text-primary">Account settings</p>
        <h1 class="mt-2 text-2xl font-bold leading-[1.5]">アカウント設定</h1>
      </header>

      <section class="card card-border border-base-300 bg-base-100 shadow-none">
        <div class="card-body p-5 sm:p-6">
          <%= form_for(resource, as: resource_name, url: registration_path(resource_name), html: { method: :put, class: "space-y-5" }) do |f| %>
            <%= render "devise/shared/error_messages", resource: resource %>
            <fieldset class="fieldset">
              <legend class="fieldset-legend text-sm font-semibold leading-[1.5]"><%= f.label :email, "メールアドレス" %></legend>
              <%= f.email_field :email, autofocus: true, autocomplete: "email", required: true, class: "input input-rapid w-full" %>
            </fieldset>
            <fieldset class="fieldset">
              <legend class="fieldset-legend text-sm font-semibold leading-[1.5]"><%= f.label :password, "新しいパスワード" %></legend>
              <%= f.password_field :password, autocomplete: "new-password", class: "input input-rapid w-full" %>
              <p class="label text-sm text-neutral">変更しない場合は空欄にしてください。</p>
            </fieldset>
            <fieldset class="fieldset">
              <legend class="fieldset-legend text-sm font-semibold leading-[1.5]"><%= f.label :password_confirmation, "新しいパスワード（確認）" %></legend>
              <%= f.password_field :password_confirmation, autocomplete: "new-password", class: "input input-rapid w-full" %>
            </fieldset>
            <fieldset class="fieldset">
              <legend class="fieldset-legend text-sm font-semibold leading-[1.5]"><%= f.label :current_password, "現在のパスワード" %></legend>
              <%= f.password_field :current_password, autocomplete: "current-password", required: true, class: "input input-rapid w-full" %>
            </fieldset>
            <%= f.submit "設定を更新", class: "btn btn-primary btn-block btn-rapid hover:border-secondary hover:bg-secondary" %>
          <% end %>
        </div>
      </section>

      <section class="card card-border border-error bg-base-100 shadow-none">
        <div class="card-body p-5 sm:p-6">
          <h2 class="card-title text-base leading-[1.5]">アカウントの削除</h2>
          <p class="text-sm text-neutral">この操作は取り消せません。</p>
          <div class="card-actions mt-2 justify-start">
            <%= button_to "アカウントを削除", registration_path(resource_name), method: :delete, class: "btn btn-outline btn-error btn-rapid", data: { turbo_confirm: "本当に削除しますか？" } %>
          </div>
        </div>
      </section>
    </div>
  ERB

  create_file "app/views/devise/passwords/new.html.erb", <<~ERB, force: true
    <% content_for :title, "パスワード再設定 | Rapid Rails" %>
    <header class="mb-8">
      <p class="text-sm font-semibold text-primary">Password reset</p>
      <h1 class="mt-2 text-2xl font-bold leading-[1.5]">パスワード再設定</h1>
      <p class="mt-2 text-sm text-neutral">再設定用リンクをメールで送信します。</p>
    </header>

    <%= form_for(resource, as: resource_name, url: password_path(resource_name), html: { method: :post, class: "space-y-5" }) do |f| %>
      <%= render "devise/shared/error_messages", resource: resource %>
      <fieldset class="fieldset">
        <legend class="fieldset-legend text-sm font-semibold leading-[1.5]"><%= f.label :email, "メールアドレス" %></legend>
        <%= f.email_field :email, autofocus: true, autocomplete: "email", required: true, class: "input input-rapid w-full" %>
      </fieldset>
      <%= f.submit "再設定メールを送信", class: "btn btn-primary btn-block btn-rapid hover:border-secondary hover:bg-secondary" %>
    <% end %>

    <%= render "devise/shared/links" %>
  ERB

  create_file "app/views/devise/passwords/edit.html.erb", <<~ERB, force: true
    <% content_for :title, "新しいパスワード | Rapid Rails" %>
    <header class="mb-8">
      <p class="text-sm font-semibold text-primary">Choose a password</p>
      <h1 class="mt-2 text-2xl font-bold leading-[1.5]">新しいパスワード</h1>
    </header>

    <%= form_for(resource, as: resource_name, url: password_path(resource_name), html: { method: :put, class: "space-y-5" }) do |f| %>
      <%= render "devise/shared/error_messages", resource: resource %>
      <%= f.hidden_field :reset_password_token %>
      <fieldset class="fieldset">
        <legend class="fieldset-legend text-sm font-semibold leading-[1.5]"><%= f.label :password, "新しいパスワード" %></legend>
        <%= f.password_field :password, autofocus: true, autocomplete: "new-password", required: true, class: "input input-rapid w-full" %>
      </fieldset>
      <fieldset class="fieldset">
        <legend class="fieldset-legend text-sm font-semibold leading-[1.5]"><%= f.label :password_confirmation, "新しいパスワード（確認）" %></legend>
        <%= f.password_field :password_confirmation, autocomplete: "new-password", required: true, class: "input input-rapid w-full" %>
      </fieldset>
      <%= f.submit "パスワードを変更", class: "btn btn-primary btn-block btn-rapid hover:border-secondary hover:bg-secondary" %>
    <% end %>

    <%= render "devise/shared/links" %>
  ERB
end

def configure_default_views
  devise = VALUES.fetch("account_authentication") == "devise"
  api_enabled = VALUES.fetch("api") == "enable"
  profile_features = VALUES.fetch("profile_features")
  profile_enabled = profile_features.any?
  avatar_enabled = profile_features.include?("avatar")
  screen_name_enabled = profile_features.include?("screen_name")
  display_name_enabled = profile_features.include?("display_name")
  account_navigation_count = 2 + (profile_enabled ? 1 : 0) + (api_enabled ? 1 : 0)
  account_page_description = if profile_enabled
    "プロフィールとアプリケーションの状態を確認できます。"
  else
    "アプリケーションの状態を確認できます。"
  end
  account_page_action = if profile_enabled
    "サイドメニューからプロフィールや利用設定を管理できます。"
  else
    "サイドメニューから利用設定を管理できます。"
  end
  home_action = if devise
    '<%= link_to "無料で始める", new_user_registration_path, class: "btn btn-primary btn-rapid px-6 hover:border-secondary hover:bg-secondary" %>'
  else
    '<%= link_to "ウォレットで始める", new_session_path, class: "btn btn-primary btn-rapid px-6 hover:border-secondary hover:bg-secondary" %>'
  end
  account_navigation_items = <<~ERB
    <li>
      <%= link_to account_path, class: ("menu-active" if current_page?(account_path)), aria: { current: ("page" if current_page?(account_path)) } do %>
        <svg xmlns="http://www.w3.org/2000/svg" class="size-5" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" aria-hidden="true" data-slot="icon">
          <path stroke-linecap="round" stroke-linejoin="round" d="m2.25 12 8.954-8.955a1.125 1.125 0 0 1 1.591 0L21.75 12M4.5 9.75v10.125c0 .621.504 1.125 1.125 1.125H9.75v-4.875c0-.621.504-1.125 1.125-1.125h2.25c.621 0 1.125.504 1.125 1.125V21h4.125c.621 0 1.125-.504 1.125-1.125V9.75" />
        </svg>
        マイページ
      <% end %>
    </li>
  ERB
  if profile_enabled
    account_navigation_items += <<~ERB
      <li>
        <%= link_to profile_path, class: ("menu-active" if controller_path == "profiles"), aria: { current: ("page" if controller_path == "profiles") } do %>
          <svg xmlns="http://www.w3.org/2000/svg" class="size-5" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" aria-hidden="true" data-slot="icon">
            <path stroke-linecap="round" stroke-linejoin="round" d="M17.982 18.725A7.488 7.488 0 0 0 12 15.75a7.488 7.488 0 0 0-5.982 2.975m11.963 0a9 9 0 1 0-11.963 0m11.963 0A8.966 8.966 0 0 1 12 21a8.966 8.966 0 0 1-5.982-2.275M15 9.75a3 3 0 1 1-6 0 3 3 0 0 1 6 0Z" />
          </svg>
          プロフィール
        <% end %>
      </li>
    ERB
  end
  account_settings_path = devise ? "edit_user_registration_path" : "edit_account_path"
  account_navigation_items += <<~ERB
    <li>
      <%= link_to #{account_settings_path}, class: ("menu-active" if current_page?(#{account_settings_path})), aria: { current: ("page" if current_page?(#{account_settings_path})) } do %>
        <svg xmlns="http://www.w3.org/2000/svg" class="size-5" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" aria-hidden="true" data-slot="icon">
          <path stroke-linecap="round" stroke-linejoin="round" d="M9.594 3.94c.09-.542.56-.94 1.11-.94h2.593c.55 0 1.02.398 1.11.94l.213 1.281c.063.374.313.686.645.87.074.04.147.083.22.127.325.196.72.257 1.075.124l1.217-.456a1.125 1.125 0 0 1 1.37.49l1.296 2.247a1.125 1.125 0 0 1-.26 1.431l-1.003.827c-.293.241-.438.613-.43.992a7.723 7.723 0 0 1 0 .255c-.008.378.137.75.43.991l1.004.827c.424.35.534.955.26 1.43l-1.298 2.247a1.125 1.125 0 0 1-1.369.491l-1.217-.456c-.355-.133-.75-.072-1.076.124a6.47 6.47 0 0 1-.22.128c-.331.183-.581.495-.644.869l-.213 1.281c-.09.543-.56.94-1.11.94h-2.594c-.55 0-1.019-.398-1.11-.94l-.213-1.281c-.062-.374-.312-.686-.644-.87a6.52 6.52 0 0 1-.22-.127c-.325-.196-.72-.257-1.076-.124l-1.217.456a1.125 1.125 0 0 1-1.369-.49l-1.297-2.247a1.125 1.125 0 0 1 .26-1.431l1.004-.827c.292-.24.437-.613.43-.991a6.932 6.932 0 0 1 0-.255c.007-.38-.138-.751-.43-.992l-1.004-.827a1.125 1.125 0 0 1-.26-1.43l1.297-2.247a1.125 1.125 0 0 1 1.37-.491l1.216.456c.356.133.751.072 1.076-.124.072-.044.146-.086.22-.128.332-.183.582-.495.644-.869l.214-1.28Z" />
          <path stroke-linecap="round" stroke-linejoin="round" d="M15 12a3 3 0 1 1-6 0 3 3 0 0 1 6 0Z" />
        </svg>
        アカウント設定
      <% end %>
    </li>
  ERB
  if api_enabled
    account_navigation_items += <<~ERB
      <li>
        <%= link_to api_credentials_path, class: ("menu-active" if controller_path == "api_credentials"), aria: { current: ("page" if controller_path == "api_credentials") } do %>
          <svg xmlns="http://www.w3.org/2000/svg" class="size-5" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" aria-hidden="true" data-slot="icon">
            <path stroke-linecap="round" stroke-linejoin="round" d="M17.25 6.75 22.5 12l-5.25 5.25m-10.5 0L1.5 12l5.25-5.25m7.5-3-4.5 16.5" />
          </svg>
          APIキーの管理
        <% end %>
      </li>
    ERB
  end
  account_navigation_for_layout = account_navigation_items.lines.map { |line| "                #{line}" }.join
  account_navigation_for_dropdown = account_navigation_items.lines.map { |line| "          #{line}" }.join
  signed_in_condition = devise ? "user_signed_in?" : "authenticated?"
  profile_owner = devise ? "current_user.profile" : "Current.user.profile"
  logout_path = devise ? "destroy_user_session_path" : "session_path"
  guest_desktop_navigation = if devise
    <<~ERB
      <%= link_to "ログイン", new_user_session_path, class: "btn btn-ghost btn-rapid" %>
      <%= link_to "アカウント作成", new_user_registration_path, class: "btn btn-primary btn-outline btn-rapid" %>
    ERB
  else
    <<~ERB
      <%= link_to "ログイン", new_session_path, class: "btn btn-ghost btn-rapid" %>
    ERB
  end
  guest_mobile_navigation = if devise
    <<~ERB
      <li><%= link_to "ログイン", new_user_session_path %></li>
      <li><%= link_to "アカウント作成", new_user_registration_path %></li>
    ERB
  else
    <<~ERB
      <li><%= link_to "ログイン", new_session_path %></li>
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
      <summary class="btn btn-circle btn-ghost" aria-label="アカウントメニューを開く">
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
        <span>MENU</span>
      </summary>
    ERB
  end
  layout_method = if devise
    'devise_controller? ? (controller_name == "registrations" && %w[edit update].include?(action_name) ? "account" : "authentication") : "application"'
  else
    'controller_path == "sessions" ? "authentication" : "application"'
  end
  wallet_script = devise ? "" : "    <script src=\"/vendor/web3-4.16.0.min.js\" defer></script>\n"

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
          user.destroy!
          cookies.delete(:session_id)
          Current.session = nil
          redirect_to root_path, notice: I18n.t("accounts.destroy.notice", locale: :ja), status: :see_other
        end
      end
    RUBY
  end
  create_file "app/controllers/accounts_controller.rb", accounts_controller, force: true

  route 'root "home#index"'
  route devise ? "resource :account, only: :show" : "resource :account, only: %i[show edit destroy]"

  create_file "app/views/layouts/application.html.erb", <<~ERB, force: true
    <!DOCTYPE html>
    <html lang="ja" data-theme="rapid-rails">
      <head>
        <title><%= content_for(:title) || "Rapid Rails" %></title>
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <%= csrf_meta_tags %>
        <%= csp_meta_tag %>
        <%= yield :head %>
        <%= stylesheet_link_tag "tailwind", "data-turbo-track": "reload" %>
        <%= stylesheet_link_tag :app, "data-turbo-track": "reload" %>
    #{wallet_script}    <%= javascript_importmap_tags %>
      </head>
      <body class="min-h-screen bg-base-100 text-base-content antialiased" data-layout="application">
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
          <nav aria-label="アカウントメニュー">
            <ul class="menu w-full rounded-box bg-base-100">
              <li class="menu-title"><span>マイページ</span></li>
    #{account_navigation_for_layout}          </ul>
          </nav>
        </aside>
        <div class="min-w-0"><%= yield %></div>
      </div>
    <% end %>
    <%= render template: "layouts/application" %>
  ERB

  create_file "app/views/shared/_header.html.erb", <<~ERB, force: true
    <header class="border-b border-base-300 bg-base-100">
      <nav class="navbar mx-auto w-full max-w-6xl px-5" aria-label="メインナビゲーション">
        <div class="navbar-start">
          <%= link_to "Rapid Rails", root_path, class: "inline-flex min-h-11 items-center text-lg font-bold text-primary" %>
        </div>
        <% if #{signed_in_condition} %>
          <div class="navbar-end">
            <details class="dropdown dropdown-end dropdown-hover">
    #{account_menu_trigger.lines.map { |line| "          #{line}" }.join}          <ul class="menu menu-sm dropdown-content z-10 mt-3 w-72 rounded-box bg-base-100 shadow-elevation-2">
    #{profile_identity.lines.map { |line| "            #{line}" }.join}#{account_navigation_for_dropdown}            <li class="border-t border-base-300"><%= link_to "ログアウト", #{logout_path}, data: { turbo_method: :delete } %></li>
              </ul>
            </details>
          </div>
        <% else %>
          <div class="navbar-end hidden items-center gap-1 min-[961px]:flex">
    #{guest_desktop_navigation.lines.map { |line| "        #{line}" }.join}      </div>
          <div class="navbar-end min-[961px]:hidden">
            <details class="dropdown dropdown-end">
              <summary class="btn btn-ghost">メニュー</summary>
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
    <div class="border-t border-base-300 bg-base-100">
      <footer class="footer footer-vertical mx-auto w-full max-w-6xl px-5 py-8 text-sm sm:footer-horizontal">
        <aside><p class="font-semibold text-base-content">Rapid Rails</p></aside>
      </footer>
    </div>
  ERB

  create_file "app/views/home/index.html.erb", <<~ERB, force: true
    <% content_for :title, "Rapid Rails | Build with clarity" %>
    <div class="mx-auto w-full max-w-[820px] space-y-8 px-5 py-10 md:py-14">
      <section class="hero rounded-box border border-base-300 bg-base-100">
        <div class="hero-content w-full max-w-none flex-col items-start gap-6 p-6 sm:p-8 md:p-10">
          <span class="badge badge-outline">Rails application template</span>
          <div>
            <h1 class="text-[1.75rem] font-bold leading-[1.5] min-[961px]:text-[2.4rem]">迷わず始められる、<br class="hidden sm:block">モダンなRails開発環境。</h1>
            <p class="mt-5 max-w-2xl text-neutral">Rails 8.1の標準を活かしながら、認証、UI、テスト、デプロイまでを再現可能な構成で整えます。</p>
          </div>
          <div class="flex flex-col gap-3 sm:flex-row">
            #{home_action}
            <%= link_to "構成を見る", "#features", class: "btn btn-primary btn-outline btn-rapid px-6" %>
          </div>
        </div>
      </section>

      <section id="features" aria-labelledby="features-title">
        <div class="mb-5">
          <p class="text-sm font-semibold text-primary">Starter kit</p>
          <h2 id="features-title" class="mt-1 text-xl font-bold leading-[1.5]">最初から揃う開発基盤</h2>
        </div>
        <div class="grid gap-4 min-[961px]:grid-cols-3">
          <% [["01", "Rails native", "Generator APIを中心に、安全な初期構成を生成します。"], ["02", "Readable UI", "daisyUIとsemantic colorで、読みやすい画面を用意します。"], ["03", "Production ready", "SQLiteとLitestreamを前提に、運用経路まで設計します。"]].each do |number, title, description| %>
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
    <% content_for :title, "マイページ | Rapid Rails" %>
    <div class="space-y-6">
      <header>
        <p class="text-sm font-semibold text-primary">Account</p>
        <h1 class="mt-1 text-2xl font-bold leading-[1.5]">マイページ</h1>
        <p class="mt-2 text-sm text-neutral">#{account_page_description}</p>
      </header>

      <section class="card card-border border-base-300 bg-base-100 shadow-none">
        <div class="card-body p-5 sm:p-6">
          <h2 class="card-title text-base leading-[1.5]">次のステップ</h2>
          <p class="text-sm text-neutral">#{account_page_action}</p>
          <div class="card-actions mt-2 justify-end">
            <%= link_to "ホームへ戻る", root_path, class: "btn btn-primary btn-outline btn-rapid" %>
          </div>
        </div>
      </section>
    </div>
  ERB

  unless devise
    create_file "app/views/accounts/edit.html.erb", <<~ERB, force: true
      <% content_for :title, "アカウント設定 | Rapid Rails" %>
      <div class="space-y-6">
        <header>
          <p class="text-sm font-semibold text-primary">Account settings</p>
          <h1 class="mt-2 text-2xl font-bold leading-[1.5]">アカウント設定</h1>
        </header>

        <section class="card card-border border-base-300 bg-base-100 shadow-none">
          <div class="card-body p-5 sm:p-6">
            <h2 class="card-title text-base leading-[1.5]">アカウント情報</h2>
            <ul class="list mt-3">
              <li class="list-row px-0">
                <span class="badge badge-outline">ID</span>
                <div class="list-col-grow min-w-0">
                  <p class="text-xs text-neutral">Wallet address</p>
                  <p class="mt-1 break-all font-semibold"><%= Current.user.wallet_address %></p>
                </div>
              </li>
            </ul>
          </div>
        </section>

        <section class="card card-border border-error bg-base-100 shadow-none">
          <div class="card-body p-5 sm:p-6">
            <h2 class="card-title text-base leading-[1.5]">アカウントの削除</h2>
            <p class="text-sm text-neutral">この操作は取り消せません。このアカウントのすべてのセッションも削除されます。</p>
            <div class="card-actions mt-2 justify-start">
              <%= button_to "アカウントを削除", account_path, method: :delete, class: "btn btn-outline btn-error btn-rapid", data: { turbo_confirm: "本当に削除しますか？" } %>
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
      <% content_for :title, "ウォレットでログイン | Rapid Rails" %>
      <div data-controller="siwe-sign-in">
        <header class="mb-8">
          <p class="text-sm font-semibold text-primary">Sign in with Ethereum</p>
          <h1 class="mt-2 text-2xl font-bold leading-[1.5]">ウォレットでログイン</h1>
          <p class="mt-2 text-sm text-neutral">EVM互換ウォレットで署名し、アカウントを安全に確認します。</p>
        </header>
        <button type="button" class="btn btn-primary btn-block btn-rapid hover:border-secondary hover:bg-secondary" data-action="click->siwe-sign-in#signIn">ウォレットを接続</button>
        <p class="alert alert-error mt-5 hidden" data-siwe-sign-in-target="error" role="alert"></p>
        <div class="divider"></div>
        <div class="alert alert-info alert-soft text-sm" role="note"><span>署名要求に秘密鍵や送金は必要ありません。</span></div>
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
      assert_select 'header details.dropdown.dropdown-end.dropdown-hover > summary.btn.btn-ghost', text: 'MENU', count: 1 do
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
        assert_select 'form[action=?] input.file-input[name="profile[avatar]"][accept="image/*"]', profile_path, count: 1
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
      assert_select 'a[href=?]', edit_profile_path, text: 'プロフィールを編集', count: 1
      #{avatar_enabled ? "assert_select '.list .avatar svg[width=\"64\"][height=\"64\"]', count: 1\n      assert_select '.avatar-placeholder', count: 0" : ""}

      get edit_profile_url
      assert_response :success
      #{form_assertions.join}#{update_assertion}
      #{if avatar_enabled
          <<~RUBY
            user.profile.avatar.attach(io: StringIO.new("avatar"), filename: "avatar.png", content_type: "image/png")
            get edit_profile_url
            assert_select 'form[action=?][method="post"]', profile_avatar_path, count: 1 do
              assert_select 'input[name="_method"][value="delete"]', count: 1
              assert_select 'button.btn.btn-outline.btn-error[data-turbo-confirm]', text: '設定済み画像を削除', count: 1
            end

            delete profile_avatar_url
            assert_redirected_to profile_url
            assert_not user.profile.reload.avatar.attached?
            follow_redirect!
            assert_select '.alert.alert-success', text: 'アバター画像を削除しました', count: 1
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
          assert_select 'nav.navbar.mx-auto.w-full.max-w-6xl.px-5[aria-label="メインナビゲーション"]'
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
    #{generated_profile_assertion}#{profile_setup}      sign_in user
          get account_url
          assert_response :success
          assert_select '[data-layout="account"].mx-auto.w-full.max-w-6xl.px-5', count: 1
    #{profile_trigger_assertion}
          assert_select 'header ul.menu.dropdown-content > li > a', count: #{account_navigation_count + 1}
    #{profile_identity_assertion}      assert_select 'header ul.menu.dropdown-content a[data-turbo-method="delete"][href=?]', destroy_user_session_path, count: 1
          assert_select 'nav[aria-label="アカウントメニュー"] > .menu > li.menu-title', text: 'マイページ', count: 1
          assert_select 'nav[aria-label="アカウントメニュー"] > .menu > li > a', count: #{account_navigation_count}
          assert_select 'nav[aria-label="アカウントメニュー"] > .menu > li > a > svg.size-5[aria-hidden="true"][data-slot="icon"]', count: #{account_navigation_count}
          assert_select 'nav[aria-label="アカウントメニュー"] a[href=?]', root_path, count: 0
          assert_select 'nav[aria-label="アカウントメニュー"] a.menu-active[aria-current="page"][href=?]', account_path, count: 1
          assert_select 'nav[aria-label="アカウントメニュー"] a.menu-active', count: 1
          assert_select 'nav[aria-label="アカウントメニュー"] a.menu-active[class="menu-active"]', count: 1
          assert_select 'nav[aria-label="アカウントメニュー"] > .menu > li > a[class]', count: 1
          assert_select 'nav[aria-label="アカウントメニュー"] > .menu > li > a.min-h-11', count: 0
          assert_select '.card > .card-body', count: 1

    #{profile_page_assertions}

          get edit_user_registration_url
          assert_response :success
          assert_select '[data-layout="account"].mx-auto.w-full.max-w-6xl.px-5', count: 1
          assert_select 'nav[aria-label="アカウントメニュー"] > .menu > li > a', count: #{account_navigation_count}
          assert_select 'nav[aria-label="アカウントメニュー"] > .menu > li > a > svg.size-5[aria-hidden="true"][data-slot="icon"]', count: #{account_navigation_count}
          assert_select 'nav[aria-label="アカウントメニュー"] a[href=?]', root_path, count: 0
          assert_select 'nav[aria-label="アカウントメニュー"] a.menu-active[aria-current="page"][href=?]', edit_user_registration_path, count: 1
          assert_select 'nav[aria-label="アカウントメニュー"] a.menu-active', count: 1
          assert_select 'nav[aria-label="アカウントメニュー"] a.menu-active[class="menu-active"]', count: 1
          assert_select 'nav[aria-label="アカウントメニュー"] > .menu > li > a[class]', count: 1
          assert_select 'nav[aria-label="アカウントメニュー"] > .menu > li > a.min-h-11', count: 0
          assert_select '.card .fieldset', minimum: 1
          assert_select '.card-actions .btn.btn-error', count: 1
        end
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
          assert_select 'nav.navbar.mx-auto.w-full.max-w-6xl.px-5[aria-label="メインナビゲーション"]'
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
      end
    RUBY
  end
  create_file "test/integration/default_pages_test.rb", default_pages_test, force: true
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
    RUN SECRET_KEY_BASE_DUMMY=1 bundle exec rails assets:precompile && rm -rf node_modules

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
  install_daisyui
  configure_rubocop
  configure_common_files
  VALUES.fetch("account_authentication") == "devise" ? install_devise : install_wallet_siwe
  rails_command "active_storage:install" if VALUES.fetch("profile_features").include?("avatar")
  configure_profile if VALUES.fetch("profile_features").any?
  configure_api if VALUES.fetch("api") == "enable"
  configure_default_views
  configure_web_push if VALUES.fetch("web_push") == "use"
  install_solid_components
  configure_dokploy if VALUES.fetch("deployment") == "dokploy"
  run_checked "bin/rails db:prepare"
  run_checked "bin/rails tailwindcss:build"
  run_checked "bundle binstubs rubocop"
  run_checked "bin/rubocop -a"
end
