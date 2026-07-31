# frozen_string_literal: true

require "json"
require "yaml"
require "digest"

CONFIG_PATH = ENV.fetch("RAPID_RAILS_TEMPLATE_CONFIG")
PLAN = JSON.parse(File.read(CONFIG_PATH), freeze: true)
VALUES = PLAN.fetch("configuration").fetch("values")
EXPECTED_KEYS = %w[pwa web_push active_job solid_cache account_authentication profile_features api action_cable mail deployment].freeze
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
gem "prism"

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

def run_checked(command)
  raise "コマンドが失敗しました: #{command}" unless run(command)
end

def install_action_text
  generate "action_text:install"
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

def configure_roles
  devise = VALUES.fetch("account_authentication") == "devise"
  identifier_attribute = devise ? "email" : "wallet_address"
  identifier_label = devise ? "メールアドレス" : "Wallet address"
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

          errors.add(:base, I18n.t("roles.errors.last_admin", locale: :ja))
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
          redirect_to admin_users_path, notice: I18n.t("admin.user_roles.create.notice", locale: :ja), status: :see_other
        rescue KeyError, ActiveRecord::RecordInvalid
          head :unprocessable_content
        end

        def destroy
          authorize! @user, to: :manage_roles?
          if @user == authorization_user
            redirect_to admin_users_path, alert: I18n.t("admin.user_roles.destroy.self_forbidden", locale: :ja), status: :see_other
            return
          end

          @user.revoke_role!(role_param)
          redirect_to admin_users_path, notice: I18n.t("admin.user_roles.destroy.notice", locale: :ja), status: :see_other
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
    <% content_for :title, "ユーザー管理 | Rapid Rails" %>
    <div class="space-y-6">
      <header>
        <p class="text-sm font-semibold text-primary">Administration</p>
        <h1 class="mt-1 text-2xl font-bold leading-[1.5]">ユーザー管理</h1>
        <p class="mt-2 text-sm text-neutral">固定roleをユーザーへ付与または解除します。</p>
      </header>

      <section class="card card-border border-base-300 bg-base-100 shadow-none">
        <div class="card-body">
          <div class="overflow-x-auto">
            <table class="table table-sm table-pin-rows">
              <thead>
                <tr>
                  <th scope="col">ID</th>
                  <th scope="col">#{identifier_label}</th>
                  <th scope="col">Role</th>
                  <th scope="col"><span class="sr-only">操作</span></th>
                </tr>
              </thead>
              <tbody>
                <% @users.each do |user| %>
                  <tr>
                    <td><%= user.id %></td>
                    <td class="break-all"><%= user.#{identifier_attribute} %></td>
                    <td>
                      <% if user.has_role?(:admin) %>
                        <span class="badge">管理者</span>
                      <% else %>
                        <span class="text-sm text-neutral">なし</span>
                      <% end %>
                    </td>
                    <td class="text-right">
                      <% if user.has_role?(:admin) %>
                        <% if user == authorization_user %>
                          <button type="button" class="btn btn-disabled btn-rapid" disabled>自分自身は解除不可</button>
                        <% else %>
                          <%= button_to "管理者を解除", admin_user_role_path(user, "admin"), method: :delete, class: "btn btn-outline btn-error btn-rapid", data: { turbo_confirm: "管理者roleを解除しますか？" } %>
                        <% end %>
                      <% else %>
                        <%= button_to "管理者にする", admin_user_roles_path(user), params: { role: "admin" }, class: "btn btn-rapid" %>
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
        <nav aria-label="ユーザー一覧のページング">
          <div class="join">
            <% if (previous_url = @pagy.page_url(:previous)) %>
              <%= link_to "前へ", previous_url, class: "btn join-item" %>
            <% else %>
              <span class="btn btn-disabled join-item" role="link" aria-disabled="true">前へ</span>
            <% end %>
            <span class="btn btn-active join-item" aria-current="page"><%= @pagy.page %> / <%= @pagy.last %></span>
            <% if (next_url = @pagy.page_url(:next)) %>
              <%= link_to "次へ", next_url, class: "btn join-item" %>
            <% else %>
              <span class="btn btn-disabled join-item" role="link" aria-disabled="true">次へ</span>
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

  create_file "config/locales/roles.ja.yml", <<~YAML, force: true
    ja:
      roles:
        errors:
          last_admin: 最後の管理者roleは解除できません
      admin:
        user_roles:
          create:
            notice: 管理者roleを付与しました
          destroy:
            notice: 管理者roleを解除しました
            self_forbidden: 自分自身の管理者roleは解除できません
      accounts:
        destroy:
          last_admin: 最後の管理者はアカウントを削除できません
  YAML

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
            get session_nonce_url
            nonce = response.parsed_body.fetch("nonce")
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
        assert_select '[data-layout="admin"] nav[aria-label="管理メニュー"]', count: 1
        assert_select '[data-layout="admin"] nav[aria-label="管理メニュー"] li.menu-title', text: "管理画面", count: 1
        assert_select '[data-layout="admin"] nav[aria-label="アカウントメニュー"]', count: 0
        assert_select '[data-layout="admin"] a.menu-active[href=?]', admin_users_path, text: "ユーザー管理", count: 1
        assert_select 'header li.menu-title', text: "管理画面", count: 1
        assert_select 'header a[href=?]', account_path, count: 0
        assert_select "table.table.table-sm.table-pin-rows"
        assert_select ".badge", text: "管理者", minimum: 1
        assert_select ".join", count: 0
      end


      test "paginates the admin list" do
        create_additional_users(25)
        sign_in_as(@admin, #{devise ? "nil" : "@admin_key"})

        get admin_users_url

        assert_response :success
        assert_select 'nav[aria-label="ユーザー一覧のページング"] .join', count: 1
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
              redirect_to edit_user_registration_path, alert: I18n.t("accounts.destroy.last_admin", locale: :ja), status: :see_other
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
  app_name = PLAN.fetch("app_name")
  page_titles = {
    "about" => "#{app_name}について",
    "corp" => "運営会社",
    "manual" => "使い方",
    "terms" => "利用規約",
    "privacy" => "プライバシーポリシー",
    "transaction-law" => "特商法表記"
  }.freeze
  page_title_entries = page_titles.map { |slug, title| "    #{slug.inspect} => #{title.inspect}" }.join(",\n")
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
      TITLES = {
    #{page_title_entries}
      }.freeze

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

            errors.add(attribute, "はuserinfoを含まないHTTPS URLを指定してください")
          rescue URI::InvalidURIError
            errors.add(attribute, "はuserinfoを含まないHTTPS URLを指定してください")
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
              notice: I18n.t("admin.pages.update.notice", locale: :ja),
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
              notice: I18n.t("admin.faqs.create.notice", locale: :ja),
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
              notice: I18n.t("admin.faqs.update.notice", locale: :ja),
              status: :see_other
          else
            render :edit, status: :unprocessable_content
          end
        end

        def destroy
          authorize! @faq, to: :destroy?
          @faq.destroy!
          redirect_to admin_faqs_path,
            notice: I18n.t("admin.faqs.destroy.notice", locale: :ja),
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
              notice: I18n.t("admin.footer_settings.update.notice", locale: :ja),
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
  create_file "config/locales/content_management.ja.yml", <<~YAML, force: true
    ja:
      admin:
        pages:
          update:
            notice: 固定ページを更新しました
        faqs:
          create:
            notice: FAQを作成しました
          update:
            notice: FAQを更新しました
          destroy:
            notice: FAQを削除しました
        footer_settings:
          update:
            notice: 外部リンクを更新しました
  YAML

  create_file "test/fixtures/pages.yml", <<~YAML, force: true
    about:
      slug: about
      title: #{page_titles.fetch("about").inspect}
    corp:
      slug: corp
      title: #{page_titles.fetch("corp").inspect}
    manual:
      slug: manual
      title: #{page_titles.fetch("manual").inspect}
    terms:
      slug: terms
      title: #{page_titles.fetch("terms").inspect}
    privacy:
      slug: privacy
      title: #{page_titles.fetch("privacy").inspect}
    transaction_law:
      slug: transaction-law
      title: #{page_titles.fetch("transaction-law").inspect}
  YAML
  create_file "test/fixtures/faqs.yml", "# FAQs are created explicitly by tests.\n", force: true
  create_file "test/fixtures/footer_settings.yml", <<~YAML, force: true
    default:
      key: default
  YAML

  create_file "app/views/pages/_page.html.erb", <<~ERB, force: true
    <% content_for :title, [@page.title, #{app_name.inspect}].join(" | ") %>
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
  create_file "app/views/pages/about.html.erb", "<%= render \"pages/page\", section: \"About\" %>\n", force: true
  create_file "app/views/pages/corp.html.erb", "<%= render \"pages/page\", section: \"Company\" %>\n", force: true
  create_file "app/views/pages/manual.html.erb", "<%= render \"pages/page\", section: \"Guides\" %>\n", force: true
  create_file "app/views/pages/terms.html.erb", "<%= render \"pages/page\", section: \"Legal\" %>\n", force: true
  create_file "app/views/pages/privacy.html.erb", "<%= render \"pages/page\", section: \"Legal\" %>\n", force: true
  create_file "app/views/pages/transaction-law.html.erb", "<%= render \"pages/page\", section: \"Legal\" %>\n", force: true

  create_file "app/views/faqs/index.html.erb", <<~ERB, force: true
    <% content_for :title, ["よくある質問", #{app_name.inspect}].join(" | ") %>
    <div class="mx-auto w-full max-w-[820px] space-y-6 px-5 py-10 md:py-14">
      <header>
        <p class="text-sm font-semibold text-primary">Guides</p>
        <h1 class="mt-1 text-2xl font-bold leading-[1.5]">よくある質問</h1>
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
        <div class="alert"><span>現在、公開中のよくある質問はありません。</span></div>
      <% end %>
    </div>
  ERB

  create_file "app/views/admin/pages/index.html.erb", <<~ERB, force: true
    <% content_for :title, ["固定ページ管理", #{app_name.inspect}].join(" | ") %>
    <div class="space-y-6">
      <header>
        <p class="text-sm font-semibold text-primary">Administration</p>
        <h1 class="mt-1 text-2xl font-bold leading-[1.5]">固定ページ管理</h1>
      </header>
      <section class="card card-border border-base-300 bg-base-100 shadow-none">
        <div class="card-body">
          <div class="overflow-x-auto">
            <table class="table">
              <thead><tr><th scope="col">ページ</th><th scope="col">URL</th><th scope="col"><span class="sr-only">操作</span></th></tr></thead>
              <tbody>
                <% @pages.each do |page| %>
                  <tr>
                    <td><%= page.title %></td>
                    <td><code>/<%= page.slug %></code></td>
                    <td class="text-right"><%= link_to "編集", edit_admin_page_path(page), class: "btn btn-rapid" %></td>
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
    <% content_for :title, [@page.title, "固定ページ管理", #{app_name.inspect}].join(" | ") %>
    <div class="max-w-[820px] space-y-6">
      <header>
        <p class="text-sm font-semibold text-primary">Administration</p>
        <h1 class="mt-1 text-2xl font-bold leading-[1.5]"><%= @page.title %></h1>
        <p class="mt-2 text-sm text-neutral">固定ページの本文を編集します。</p>
      </header>
      <section class="card card-border border-base-300 bg-base-100 shadow-none">
        <div class="card-body">
          <%= form_with model: [:admin, @page], class: "space-y-5" do |form| %>
            <fieldset class="fieldset">
              <legend class="fieldset-legend"><%= form.label :content, "本文" %></legend>
              <%= form.rich_text_area :content %>
            </fieldset>
            <div class="card-actions justify-end">
              <%= link_to "戻る", admin_pages_path, class: "btn btn-ghost btn-rapid" %>
              <%= form.submit "更新", class: "btn btn-rapid" %>
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
        <legend class="fieldset-legend"><%= form.label :question, "質問" %></legend>
        <%= form.text_field :question, class: "input input-rapid w-full", required: true %>
      </fieldset>
      <fieldset class="fieldset">
        <legend class="fieldset-legend"><%= form.label :answer, "回答" %></legend>
        <%= form.rich_text_area :answer %>
      </fieldset>
      <fieldset class="fieldset">
        <legend class="fieldset-legend"><%= form.label :position, "表示順" %></legend>
        <%= form.number_field :position, class: "input input-rapid w-full", min: 0, required: true %>
      </fieldset>
      <fieldset class="fieldset">
        <legend class="fieldset-legend">公開設定</legend>
        <label class="label cursor-pointer justify-start gap-3">
          <%= form.checkbox :published, class: "checkbox" %>
          <span>公開する</span>
        </label>
      </fieldset>
      <div class="card-actions justify-end">
        <%= link_to "戻る", admin_faqs_path, class: "btn btn-ghost btn-rapid" %>
        <%= form.submit(faq.persisted? ? "更新" : "作成", class: "btn btn-rapid") %>
      </div>
    <% end %>
  ERB

  create_file "app/views/admin/faqs/index.html.erb", <<~ERB, force: true
    <% content_for :title, ["FAQ管理", #{app_name.inspect}].join(" | ") %>
    <div class="space-y-6">
      <header class="flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
        <div>
          <p class="text-sm font-semibold text-primary">Administration</p>
          <h1 class="mt-1 text-2xl font-bold leading-[1.5]">FAQ管理</h1>
        </div>
        <%= link_to "FAQを追加", new_admin_faq_path, class: "btn btn-rapid" %>
      </header>
      <section class="card card-border border-base-300 bg-base-100 shadow-none">
        <div class="card-body">
          <% if @faqs.any? %>
            <div class="overflow-x-auto">
              <table class="table">
                <thead><tr><th scope="col">表示順</th><th scope="col">質問</th><th scope="col">状態</th><th scope="col"><span class="sr-only">操作</span></th></tr></thead>
                <tbody>
                  <% @faqs.each do |faq| %>
                    <tr>
                      <td><%= faq.position %></td>
                      <td><%= faq.question %></td>
                      <td><span class="badge"><%= faq.published? ? "公開" : "非公開" %></span></td>
                      <td>
                        <div class="flex justify-end gap-2">
                          <%= link_to "編集", edit_admin_faq_path(faq), class: "btn btn-rapid" %>
                          <%= button_to "削除", admin_faq_path(faq), method: :delete, class: "btn btn-outline btn-error btn-rapid", data: { turbo_confirm: "FAQを削除しますか？" } %>
                        </div>
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>
          <% else %>
            <div class="alert"><span>FAQはまだ登録されていません。</span></div>
          <% end %>
        </div>
      </section>
    </div>
  ERB

  create_file "app/views/admin/faqs/new.html.erb", <<~ERB, force: true
    <% content_for :title, ["FAQを追加", #{app_name.inspect}].join(" | ") %>
    <div class="max-w-[820px] space-y-6">
      <header><p class="text-sm font-semibold text-primary">Administration</p><h1 class="mt-1 text-2xl font-bold leading-[1.5]">FAQを追加</h1></header>
      <section class="card card-border border-base-300 bg-base-100 shadow-none"><div class="card-body"><%= render "form", faq: @faq %></div></section>
    </div>
  ERB

  create_file "app/views/admin/faqs/edit.html.erb", <<~ERB, force: true
    <% content_for :title, ["FAQを編集", #{app_name.inspect}].join(" | ") %>
    <div class="max-w-[820px] space-y-6">
      <header><p class="text-sm font-semibold text-primary">Administration</p><h1 class="mt-1 text-2xl font-bold leading-[1.5]">FAQを編集</h1></header>
      <section class="card card-border border-base-300 bg-base-100 shadow-none"><div class="card-body"><%= render "form", faq: @faq %></div></section>
    </div>
  ERB

  create_file "app/views/admin/footer_settings/edit.html.erb", <<~ERB, force: true
    <% content_for :title, ["外部リンク設定", #{app_name.inspect}].join(" | ") %>
    <div class="max-w-[820px] space-y-6">
      <header>
        <p class="text-sm font-semibold text-primary">Administration</p>
        <h1 class="mt-1 text-2xl font-bold leading-[1.5]">外部リンク設定</h1>
        <p class="mt-2 text-sm text-neutral">空欄のリンクはfooterに表示されません。</p>
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
            <div class="card-actions justify-end"><%= form.submit "更新", class: "btn btn-rapid" %></div>
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
            get session_nonce_url
            nonce = response.parsed_body.fetch("nonce")
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
          corp_url => ["corp", "運営会社"],
          manual_url => ["manual", "使い方"],
          terms_url => ["terms", "利用規約"],
          privacy_url => ["privacy", "プライバシーポリシー"],
          transaction_law_url => ["transaction-law", "特商法表記"]
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

      test "hides unset external links and renders configured links safely" do
        get about_url

        assert_select "footer .footer-title", text: "Links", count: 0
        assert_select "footer .footer-title", count: 3

        footer_settings(:default).update!(
          x_url: "https://social.example/x",
          github_url: "https://code.example/repository"
        )
        get about_url

        assert_select "footer .footer-title", text: "Links", count: 1
        assert_select 'footer a[href="https://social.example/x"][target="_blank"][rel="noopener noreferrer"]', text: "X(Twitter)", count: 1
        assert_select 'footer a[href="https://code.example/repository"][target="_blank"][rel="noopener noreferrer"]', text: "GitHub", count: 1
      end

      test "footer uses the generated application name and fixed internal routes" do
        get about_url

        assert_select 'footer.footer.footer-vertical[class~="sm:footer-horizontal"]'
        assert_select "footer .footer-title", text: "About", count: 1
        assert_select "footer a[href=?]", about_path, text: #{("#{app_name}について").inspect}, count: 1
        assert_select "footer a[href=?]", corp_path, text: "運営会社", count: 1
        assert_select "footer a[href=?]", manual_path, text: "使い方", count: 1
        assert_select "footer a[href=?]", faq_path, text: "よくある質問", count: 1
        assert_select "footer a[href=?]", terms_path, text: "利用規約", count: 1
        assert_select "footer a[href=?]", privacy_path, text: "プライバシーポリシー", count: 1
        assert_select "footer a[href=?]", transaction_law_path, text: "特商法表記", count: 1
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
        assert_select ".alert", text: "現在、公開中のよくある質問はありません。", count: 1
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
        assert_select '[data-layout="admin"] nav[aria-label="管理メニュー"]', count: 1
        assert_select '[data-layout="admin"] a.menu-active[href=?]', admin_pages_path, text: "固定ページ管理", count: 1
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
        assert_select '[data-layout="admin"] nav[aria-label="管理メニュー"]', count: 1
        assert_select '[data-layout="admin"] a.menu-active[href=?]', admin_faqs_path, text: "FAQ管理", count: 1
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
        assert_select '[data-layout="admin"] nav[aria-label="管理メニュー"]', count: 1
        assert_select '[data-layout="admin"] a.menu-active[href=?]', edit_admin_footer_setting_path, text: "外部リンク設定", count: 1

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
  app_name = PLAN.fetch("app_name")
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
  admin_navigation_items = <<~ERB
      <li>
        <%= link_to admin_users_path, class: ("menu-active" if controller_path.in?(%w[admin/users admin/user_roles])), aria: { current: ("page" if controller_path.in?(%w[admin/users admin/user_roles])) } do %>
          <svg xmlns="http://www.w3.org/2000/svg" class="size-5" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" aria-hidden="true" data-slot="icon">
            <path stroke-linecap="round" stroke-linejoin="round" d="M9 12.75 11.25 15 15 9.75m6-3c0 7.142-3.75 12-9 13.5C6.75 18.75 3 13.892 3 6.75c3.75 0 7.5-1.5 9-4.5 1.5 3 5.25 4.5 9 4.5Z" />
          </svg>
          ユーザー管理
        <% end %>
      </li>
      <li>
        <%= link_to admin_pages_path, class: ("menu-active" if controller_path == "admin/pages"), aria: { current: ("page" if controller_path == "admin/pages") } do %>
          <svg xmlns="http://www.w3.org/2000/svg" class="size-5" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" aria-hidden="true" data-slot="icon">
            <path stroke-linecap="round" stroke-linejoin="round" d="M19.5 14.25v-2.625a3.375 3.375 0 0 0-3.375-3.375h-1.5A1.125 1.125 0 0 1 13.5 7.125v-1.5A3.375 3.375 0 0 0 10.125 2.25H8.25m0 12.75h7.5m-7.5 3h4.5M10.5 2.25H5.625c-.621 0-1.125.504-1.125 1.125v17.25c0 .621.504 1.125 1.125 1.125h12.75c.621 0 1.125-.504 1.125-1.125v-8.25a10.5 10.5 0 0 0-9-10.125Z" />
          </svg>
          固定ページ管理
        <% end %>
      </li>
      <li>
        <%= link_to admin_faqs_path, class: ("menu-active" if controller_path == "admin/faqs"), aria: { current: ("page" if controller_path == "admin/faqs") } do %>
          <svg xmlns="http://www.w3.org/2000/svg" class="size-5" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" aria-hidden="true" data-slot="icon">
            <path stroke-linecap="round" stroke-linejoin="round" d="M8.625 9.75a3.375 3.375 0 1 1 5.775 2.387c-.938.938-1.9 1.424-1.9 2.613M12 18h.008v.008H12V18Zm9-6a9 9 0 1 1-18 0 9 9 0 0 1 18 0Z" />
          </svg>
          FAQ管理
        <% end %>
      </li>
      <li>
        <%= link_to edit_admin_footer_setting_path, class: ("menu-active" if controller_path == "admin/footer_settings"), aria: { current: ("page" if controller_path == "admin/footer_settings") } do %>
          <svg xmlns="http://www.w3.org/2000/svg" class="size-5" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" aria-hidden="true" data-slot="icon">
            <path stroke-linecap="round" stroke-linejoin="round" d="M13.19 8.688a4.5 4.5 0 0 1 1.242 7.244l-4.5 4.5a4.5 4.5 0 0 1-6.364-6.364l1.757-1.757m13.35-.622 1.757-1.757a4.5 4.5 0 0 0-6.364-6.364l-4.5 4.5a4.5 4.5 0 0 0 1.242 7.244" />
          </svg>
          外部リンク設定
        <% end %>
      </li>
  ERB
  account_navigation_for_layout = account_navigation_items.lines.map { |line| "                #{line}" }.join
  account_navigation_for_dropdown = account_navigation_items.lines.map { |line| "          #{line}" }.join
  admin_navigation_for_layout = admin_navigation_items.lines.map { |line| "                #{line}" }.join
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
          if user.last_admin?
            redirect_to edit_account_path, alert: I18n.t("accounts.destroy.last_admin", locale: :ja), status: :see_other
            return
          end

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
        <%= stylesheet_link_tag "lexxy", "data-turbo-track": "reload" %>
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

  create_file "app/views/shared/_admin_navigation.html.erb", admin_navigation_items, force: true
  create_file "app/views/layouts/admin.html.erb", <<~ERB, force: true
    <% content_for :content do %>
      <div class="mx-auto grid w-full max-w-6xl gap-6 px-5 py-8 min-[961px]:grid-cols-[220px_minmax(0,1fr)] min-[961px]:py-12" data-layout="admin">
        <aside class="h-fit">
          <nav aria-label="管理メニュー">
            <ul class="menu w-full rounded-box bg-base-100">
              <li class="menu-title"><span>管理画面</span></li>
    #{admin_navigation_for_layout}          </ul>
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
    #{profile_identity.lines.map { |line| "            #{line}" }.join}            <% if controller_path.start_with?("admin/") %>
                <li class="menu-title"><span>管理画面</span></li>
                <%= render "shared/admin_navigation" %>
              <% else %>
    #{account_navigation_for_dropdown}            <% end %>
              <li class="border-t border-base-300"><%= link_to "ログアウト", #{logout_path}, data: { turbo_method: :delete } %></li>
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
    <% external_links_configured = footer_setting.x_url.present? || footer_setting.github_url.present? %>
    <div class="border-t border-base-300 bg-base-100">
      <footer class="footer footer-vertical mx-auto w-full max-w-6xl px-5 py-8 text-sm sm:footer-horizontal">
        <nav>
          <h2 class="footer-title leading-[1.5]">About</h2>
          <%= link_to #{("#{app_name}について").inspect}, about_path, class: "link link-hover" %>
          <%= link_to "運営会社", corp_path, class: "link link-hover" %>
        </nav>
        <nav>
          <h2 class="footer-title leading-[1.5]">Guides</h2>
          <%= link_to "使い方", manual_path, class: "link link-hover" %>
          <%= link_to "よくある質問", faq_path, class: "link link-hover" %>
        </nav>
        <% if external_links_configured %>
          <nav>
            <h2 class="footer-title leading-[1.5]">Links</h2>
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
          <%= link_to "利用規約", terms_path, class: "link link-hover" %>
          <%= link_to "プライバシーポリシー", privacy_path, class: "link link-hover" %>
          <%= link_to "特商法表記", transaction_law_path, class: "link link-hover" %>
        </nav>
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
    #{generated_profile_assertion}#{profile_setup}      user.add_role(:admin)
          sign_in user
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
          assert_select 'nav[aria-label="管理メニュー"]', count: 0
          assert_select 'header li.menu-title', text: "管理画面", count: 0
          assert_select 'header a[href=?]', admin_users_path, count: 0
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
      require "eth" if AUTHENTICATION == "siwe"
      VIEWPORTS = {
        "desktop" => { "width" => 1400, "height" => 900 },
        "mobile" => { "width" => 390, "height" => 844 }
      }.freeze
      PRIVATE_KEY = "1".rjust(64, "0")
      PASSWORD = "password123"

      test "captures every generated page and key visual state" do
        @output_directory = Pathname(ENV.fetch("EVIDENCE_OUTPUT_DIR")).expand_path
        raise "EVIDENCE_OUTPUT_DIR must be an existing empty directory" unless @output_directory.directory? && @output_directory.children.empty?

        @captures = []
        VIEWPORTS.each do |viewport_name, viewport|
          page.current_window.resize_to(viewport.fetch("width"), viewport.fetch("height"))
          prepare_guest_data
          verify_footer_geometry if viewport_name == "desktop"
          capture_guest_pages(viewport_name)
          authenticate
          prepare_authenticated_data
          verify_admin_layout_geometry if viewport_name == "desktop"
          capture_authenticated_pages(viewport_name)
          Capybara.reset_sessions!
        end

        File.write(
          @output_directory.join("captures.json"),
          JSON.pretty_generate(
            "authentication" => AUTHENTICATION,
            "viewports" => VIEWPORTS,
            "captures" => @captures
          ) + "\n"
        )
      end

      private
        def devise?
          AUTHENTICATION == "devise"
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
          capture_page("home-guest", "ホーム（未ログイン）", root_path, "迷わず始められる", viewport)
          capture_page("about", "アプリについて", about_path, Page::TITLES.fetch("about"), viewport)
          assert_selector ".lexxy-content", text: "管理画面から更新したAction Text本文"
          capture_faq_page(viewport)
          login_path = devise? ? new_user_session_path : new_session_path
          login_heading = devise? ? "ログイン" : "ウォレットでログイン"
          capture_page("login", login_heading, login_path, login_heading, viewport)

          if devise?
            capture_page("registration", "アカウント作成", new_user_registration_path, "アカウント作成", viewport)
            capture_page("password-reset-request", "パスワード再設定", new_user_password_path, "パスワード再設定", viewport)
            reset_token = @user.send_reset_password_instructions
            capture_page(
              "password-reset-edit",
              "新しいパスワード",
              edit_user_password_path(reset_password_token: reset_token),
              "新しいパスワード",
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
            fill_in "メールアドレス", with: @user.email
            fill_in "パスワード", with: PASSWORD
            click_button "ログイン"
            assert_current_path root_path
          else
            authenticate_wallet_siwe
          end
        end

        def authenticate_wallet_siwe
          visit root_path
          browser_uri = URI(page.current_url)
          integration = ActionDispatch::Integration::Session.new(Rails.application)
          integration.host! browser_uri.host + (browser_uri.port == 80 ? "" : ":#{browser_uri.port}")
          integration.get "/session/nonce"
          assert_equal 200, integration.response.status

          key = Eth::Key.new(priv: PRIVATE_KEY)
          nonce = integration.response.parsed_body.fetch("nonce")
          origin = "#{browser_uri.scheme}://#{browser_uri.host}:#{browser_uri.port}"
          message = Siwe::Message.new(
            domain: browser_uri.host + (browser_uri.port == 80 ? "" : ":#{browser_uri.port}"),
            address: key.address.to_s,
            uri: origin,
            chain_id: 1,
            nonce: nonce,
            issued_at: Time.zone.parse("2026-01-01 00:00:00 UTC").iso8601,
            statement: "Sign in to Rapid Rails"
          ).prepare_message
          integration.post "/session", params: { message: message, signature: key.personal_sign(message) }, as: :json
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
          @user.grant_role!(:admin)
          identifier = devise? ? { email: "member@example.com", password: PASSWORD, password_confirmation: PASSWORD } :
            { wallet_address: "0x2222222222222222222222222222222222222222" }
          User.find_or_create_by!(identifier.slice(devise? ? :email : :wallet_address)) do |user|
            identifier.each { |name, value| user.public_send("#{name}=", value) }
          end
        end

        def capture_authenticated_pages(viewport)
          capture_page("home-authenticated", "ホーム（ログイン済み）", root_path, "迷わず始められる", viewport)
          capture_page("account", "マイページ", account_path, "マイページ", viewport)
          assert_account_navigation_scope
          capture_page("profile", "プロフィール", profile_path, "プロフィール", viewport)
          capture_page("profile-edit", "プロフィール編集", edit_profile_path, "プロフィール編集", viewport)
          account_settings_path = devise? ? edit_user_registration_path : edit_account_path
          capture_page("account-settings", "アカウント設定", account_settings_path, "アカウント設定", viewport)

          @user.api_credentials.destroy_all
          capture_page("api-credentials-empty", "APIキー一覧（空）", api_credentials_path, "APIキーの管理", viewport)
          capture_page("api-credential-new", "APIキー作成", new_api_credential_path, "APIキーを作成", viewport)
          fill_in "名前", with: "Evidence CLI"
          with_deterministic_secure_random do
            find('input[type="submit"]').click
          end
          assert_text "ApiSecretはこの画面で一度だけ表示されます。"
          capture_current_page("api-credential-secret", "APIキー詳細（初回secret）", viewport)
          credential = @user.api_credentials.find_by!(name: "Evidence CLI")
          capture_page("api-credential-show", "APIキー詳細", api_credential_path(credential), "Evidence CLI", viewport)
          capture_page("api-credential-edit", "APIキー編集", edit_api_credential_path(credential), "APIキーを編集", viewport)
          capture_page("api-credentials-populated", "APIキー一覧（登録済み）", api_credentials_path, "APIキーの管理", viewport)
          capture_page("admin-users", "ユーザー管理", admin_users_path, "ユーザー管理", viewport)
          assert_admin_navigation_active("ユーザー管理")
          capture_page(
            "admin-page-edit",
            "固定ページ編集",
            edit_admin_page_path(Page.find_by!(slug: "about")),
            Page::TITLES.fetch("about"),
            viewport
          )
          assert_admin_navigation_active("固定ページ管理")
          assert_selector "lexxy-editor"
          capture_page(
            "admin-faq-edit",
            "FAQ編集",
            edit_admin_faq_path(@evidence_faq),
            "FAQを編集",
            viewport
          )
          assert_admin_navigation_active("FAQ管理")
          assert_selector "lexxy-editor"
          capture_page(
            "admin-footer-setting",
            "外部リンク設定",
            edit_admin_footer_setting_path,
            "外部リンク設定",
            viewport
          )
          assert_admin_navigation_active("外部リンク設定")

          return unless viewport == "mobile"

          visit root_path
          find("header details.dropdown > summary", visible: :visible).click
          capture_current_page("navigation-authenticated-open", "モバイルメニュー（ログイン済み）", viewport)
        end

        def capture_page(identifier, title, path, heading, viewport)
          visit path
          assert_equal 200, page.status_code
          assert_selector "h1", text: heading
          capture_current_page(identifier, title, viewport)
        end

        def assert_admin_navigation_active(label)
          assert_selector '[data-layout="admin"] nav[aria-label="管理メニュー"]'
          assert_selector '[data-layout="admin"] nav[aria-label="管理メニュー"] li.menu-title', text: "管理画面", count: 1
          assert_no_selector '[data-layout="admin"] nav[aria-label="アカウントメニュー"]'
          assert_selector '[data-layout="admin"] a.menu-active[aria-current="page"]', text: label, count: 1
          assert_selector 'header li.menu-title', text: "管理画面", count: 1, visible: :all
          assert_no_selector %(header a[href="\#{account_path}"]), visible: :all
        end

        def assert_account_navigation_scope
          assert_selector '[data-layout="account"] nav[aria-label="アカウントメニュー"]'
          assert_no_selector '[data-layout="account"] nav[aria-label="管理メニュー"]'
          assert_no_selector 'header li.menu-title', text: "管理画面", visible: :all
          assert_no_selector %(header a[href="\#{admin_users_path}"]), visible: :all
        end

        def capture_faq_page(viewport)
          visit faq_path
          assert_equal 200, page.status_code
          assert_selector "h1", text: "よくある質問"
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
            playwright_page.add_style_tag(content: <<~CSS)
              *, *::before, *::after {
                animation: none !important;
                caret-color: transparent !important;
                scroll-behavior: auto !important;
                transition: none !important;
              }
            CSS
            playwright_page.evaluate("() => document.fonts.ready")
            playwright_page.screenshot(path: path.to_s, fullPage: true, animations: "disabled")
          end
          @captures << { "id" => identifier, "title" => title, "viewport" => viewport, "path" => filename }
        end
    end
  RUBY
  runner = runner.sub("__AUTHENTICATION__", authentication.inspect)
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

        begin
          raise "test databaseの再構築に失敗しました" unless rebuild_test_database.call

          system(
            { "RAILS_ENV" => "test", "EVIDENCE_OUTPUT_DIR" => output_directory.to_s },
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
  install_action_text
  configure_lexxy
  install_daisyui
  configure_generator_view_templates
  configure_rubocop
  configure_common_files
  configure_evidence_capture
  configure_annotaterb
  VALUES.fetch("account_authentication") == "devise" ? install_devise : install_wallet_siwe
  configure_roles
  configure_content_management
  configure_profile if VALUES.fetch("profile_features").any?
  configure_api if VALUES.fetch("api") == "enable"
  configure_default_views
  configure_web_push if VALUES.fetch("web_push") == "use"
  install_solid_components
  configure_dokploy if VALUES.fetch("deployment") == "dokploy"
  run_checked "bin/rails db:prepare"
  run_checked "bundle binstubs annotaterb"
  run_checked "bin/annotaterb models"
  run_checked "bin/rails tailwindcss:build"
  run_checked "bundle binstubs rubocop"
  run_checked "bin/rubocop -a"
end
