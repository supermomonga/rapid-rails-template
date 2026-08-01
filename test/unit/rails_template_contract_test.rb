# frozen_string_literal: true

require_relative "../test_helper"

class RailsTemplateContractTest < Minitest::Test
  TEMPLATE_PATH = File.expand_path("../../src/rapid_rails_template/rails_template.rb", __dir__)
  THEME_VARIABLES = %w[
    color-base-100 color-base-200 color-base-300 color-base-content
    color-primary color-primary-content color-secondary color-secondary-content
    color-accent color-accent-content color-neutral color-neutral-content
    color-info color-info-content color-success color-success-content
    color-warning color-warning-content color-error color-error-content
    radius-selector radius-field radius-box size-selector size-field border depth noise
  ].freeze

  def setup
    @source = File.binread(TEMPLATE_PATH)
  end

  def generated_file_source(path)
    pattern = /^(?<indent>[ \t]*)create_file #{Regexp.escape(path.inspect)}, <<~(?<quote>'?)(?<delimiter>[A-Z]+)\k<quote>, force: true\n(?<body>.*?)^\k<indent>\k<delimiter>$/m
    @source.match(pattern)&.[](:body) || flunk("generated template not found: #{path}")
  end

  def source_between(start_marker, end_marker)
    start_index = @source.index(start_marker) || flunk("source marker not found: #{start_marker}")
    end_index = @source.index(end_marker, start_index + start_marker.length) || flunk("source marker not found: #{end_marker}")
    @source.byteslice(start_index...end_index)
  end

  def class_attributes(template)
    template.scan(/\bclass(?:=|:\s*)"([^"]*)"/).flatten.map(&:split)
  end

  def assert_class_tokens(template, *tokens)
    assert class_attributes(template).any? { |classes| (tokens - classes).empty? },
      "expected one class attribute containing #{tokens.inspect}"
  end

  def test_generates_one_application_identity_and_i18n_boundary
    identity = generated_file_source("lib/application_identity.rb")
    initializer = generated_file_source("config/initializers/application_identity.rb")
    concern = generated_file_source("app/controllers/concerns/localized_request.rb")
    helper = generated_file_source("app/helpers/application_helper.rb")
    layout = generated_file_source("app/views/layouts/application.html.erb")
    header = generated_file_source("app/views/shared/_header.html.erb")
    manifest = generated_file_source("app/views/pwa/manifest.json.erb")

    assert_includes identity, "AVAILABLE_LOCALES = %i[ja en].freeze"
    assert_includes identity, 'environment.fetch(configuration.canonical_origin_env)'
    assert_includes identity, "canonical_origin must be an HTTP(S) origin without path"
    assert_includes identity, "def siwe_statement(locale: default_locale)"
    assert_includes identity, "URI.encode_uri_component(app_name)"
    assert_includes initializer, "Rails.application.routes.default_url_options = identity.default_url_options"
    assert_includes initializer, "action_mailer.default_url_options = identity.default_url_options"
    assert_includes concern, "I18n.with_locale(I18n.default_locale, &action)"
    assert_includes helper, "Rails.configuration.x.application_identity"
    assert_includes layout, '<html lang="<%= I18n.locale %>"'
    assert_includes layout, 'property="og:site_name" content="<%= application_identity.app_name %>"'
    assert_includes header, "link_to application_identity.app_name, root_path"
    assert_includes manifest, "name: identity.app_name"
    assert_includes manifest, "lang: identity.default_locale.to_s"
    refute_match(/I18n\.t\([^)]*locale:\s*:ja/m, @source)
  end

  def test_defines_one_complete_default_light_theme
    assert_equal 1, @source.scan('@plugin "daisyui/theme"').size
    assert_includes @source, 'name: "rapid-rails";'
    assert_includes @source, "default: true;"
    assert_includes @source, "prefersdark: false;"
    assert_includes @source, "color-scheme: light;"
    THEME_VARIABLES.each { |variable| assert_equal 1, @source.scan(/--#{Regexp.escape(variable)}:/).size, variable }
  end

  def test_maps_design_tokens_and_typography_to_the_theme
    %w[#ffffff #f1f5f9 #d6e3ed #3ea8ff #0f83fd #10b981 #f59e0b #f43f5e].each do |color|
      assert_includes @source, color
    end
    assert_includes @source, "--radius-field: 0.5rem;"
    assert_includes @source, "--radius-box: 0.75rem;"
    assert_includes @source, "--depth: 0;"
    assert_includes @source, 'font-family: -apple-system, system-ui, "Hiragino Kaku Gothic ProN", "Hiragino Sans", Meiryo, sans-serif;'
    assert_includes @source, "font-size: 1rem;"
    assert_includes @source, "line-height: 1.8;"
    assert_includes @source, "font-feature-settings: normal;"
    assert_includes @source, "word-break: break-all;"
    assert_includes @source, "overflow-wrap: break-word;"
    assert_includes @source, "font-family: SFMono-Regular, Consolas, Menlo, monospace;"
  end

  def test_default_views_use_daisyui_components_and_semantic_colors
    component_expectations = {
      "app/views/layouts/authentication.html.erb" => %w[hero hero-content card card-body],
      "app/views/layouts/account.html.erb" => %w[menu menu-title],
      "app/views/layouts/admin.html.erb" => %w[menu menu-title],
      "app/views/shared/_header.html.erb" => %w[navbar dropdown menu btn],
      "app/views/shared/_flash.html.erb" => %w[alert],
      "app/views/shared/_footer.html.erb" => %w[footer footer-vertical footer-title link link-hover],
      "app/views/home/index.html.erb" => %w[hero hero-content badge btn card card-body card-title],
      "app/views/accounts/show.html.erb" => %w[card card-body card-title btn],
      "app/views/accounts/edit.html.erb" => %w[card card-body card-title list list-row badge btn],
      "app/views/notifications/show.html.erb" => %w[card card-body card-title card-actions toggle btn alert],
      "app/views/admin/users/index.html.erb" => %w[card card-body table badge btn join join-item],
      "app/views/pages/_page.html.erb" => %w[card card-body],
      "app/views/faqs/index.html.erb" => %w[collapse collapse-arrow collapse-title collapse-content alert],
      "app/views/admin/pages/index.html.erb" => %w[card card-body table btn],
      "app/views/admin/pages/edit.html.erb" => %w[card card-body btn],
      "app/views/admin/faqs/index.html.erb" => %w[card card-body table badge btn],
      "app/views/admin/faqs/_form.html.erb" => %w[alert fieldset fieldset-legend input checkbox btn],
      "app/views/admin/footer_settings/edit.html.erb" => %w[card card-body alert fieldset fieldset-legend input btn],
      "app/views/api_credentials/_form.html.erb" => %w[alert fieldset fieldset-legend input btn],
      "app/views/api_credentials/index.html.erb" => %w[card card-body table join join-item input alert btn],
      "app/views/api_credentials/show.html.erb" => %w[alert fieldset fieldset-legend join join-item input card card-body card-title btn],
      "app/views/api_credentials/new.html.erb" => %w[card card-body],
      "app/views/api_credentials/edit.html.erb" => %w[card card-body],
      "app/views/devise/shared/_error_messages.html.erb" => %w[alert],
      "app/views/devise/shared/_links.html.erb" => %w[divider menu],
      "app/views/devise/sessions/new.html.erb" => %w[fieldset fieldset-legend input checkbox btn],
      "app/views/devise/registrations/new.html.erb" => %w[fieldset fieldset-legend input btn],
      "app/views/devise/registrations/edit.html.erb" => %w[card fieldset fieldset-legend input btn],
      "app/views/devise/passwords/new.html.erb" => %w[fieldset fieldset-legend input btn],
      "app/views/devise/passwords/edit.html.erb" => %w[fieldset fieldset-legend input btn],
      "app/views/sessions/new.html.erb" => %w[btn alert divider]
    }

    view_sources = component_expectations.to_h { |path, _components| [path, generated_file_source(path)] }
    component_expectations.each do |path, components|
      components.each do |component|
        assert class_attributes(view_sources.fetch(path)).any? { |classes| classes.include?(component) },
          "#{path}: #{component}"
      end
    end

    views = ([generated_file_source("app/views/layouts/application.html.erb")] + view_sources.values).join("\n")
    profile_configuration = source_between("def configure_profile", "def configure_api")
    %w[alert fieldset fieldset-legend input file-input card card-body list list-row avatar btn].each do |component|
      assert class_attributes(profile_configuration).any? { |classes| classes.include?(component) }, "profile: #{component}"
    end
    avatar_helper = generated_file_source("app/helpers/avatar_helper.rb")
    views += profile_configuration.sub(avatar_helper, "")
    %w[navbar menu dropdown avatar hero card fieldset input file-input checkbox btn alert footer badge divider list table collapse].each do |component|
      assert class_attributes(views).any? { |classes| classes.include?(component) }, component
    end
    %w[bg-base-100 bg-base-200 border-base-300 text-base-content btn-primary].each { |utility| assert_includes views, utility }
    refute_match(/(?:bg|text|border)-(?:blue|gray|slate|red|green|yellow)-\d+/, views)
    refute_includes views, "dark:"
    refute_match(/#[0-9a-f]{3,8}(?![0-9a-z])/i, views)
  end

  def test_generator_view_overrides_preserve_rails_contracts_and_use_daisyui_components
    paths = %w[
      lib/templates/erb/scaffold/index.html.erb.tt
      lib/templates/erb/scaffold/show.html.erb.tt
      lib/templates/erb/scaffold/new.html.erb.tt
      lib/templates/erb/scaffold/edit.html.erb.tt
      lib/templates/erb/scaffold/_form.html.erb.tt
      lib/templates/erb/scaffold/partial.html.erb.tt
      lib/templates/erb/controller/view.html.erb.tt
    ]
    templates = paths.to_h { |path| [path, generated_file_source(path)] }
    combined = templates.values.join("\n")
    form = templates.fetch("lib/templates/erb/scaffold/_form.html.erb.tt")
    index = templates.fetch("lib/templates/erb/scaffold/index.html.erb.tt")
    show = templates.fetch("lib/templates/erb/scaffold/show.html.erb.tt")
    partial = templates.fetch("lib/templates/erb/scaffold/partial.html.erb.tt")
    controller = templates.fetch("lib/templates/erb/controller/view.html.erb.tt")

    assert_equal paths.sort, @source.scan(/create_file "(lib\/templates\/erb\/[^"]+)"/).flatten.sort
    assert_includes @source, "configure_generator_view_templates\n  configure_rubocop"
    assert_includes form, "<%%= form_with(model: <%= model_resource_name %>"
    assert_includes form, "attributes.each do |attribute|"
    assert_includes form, "attribute.password_digest?"
    assert_includes form, "attribute.attachments?"
    assert_includes form, 'when :textarea, :rich_textarea then "textarea w-full"'
    assert_includes form, 'when :file_field then "file-input w-full"'
    assert_includes form, 'else "input input-rapid w-full"'
    assert_includes form, 'class: "checkbox"'
    assert_class_tokens(form, "alert", "alert-error")
    assert_class_tokens(form, "fieldset")
    assert_class_tokens(form, "fieldset-legend")
    assert_class_tokens(form, "btn", "btn-primary", "btn-rapid")

    assert_class_tokens(index, "table", "table-sm", "table-pin-rows")
    assert_class_tokens(index, "overflow-x-auto")
    assert_includes index, "<%%= dom_id <%= singular_table_name %> %>"
    assert_includes index, "attribute.attachment?"
    assert_includes index, "attribute.attachments?"
    assert_includes index, "model_resource_name(singular_table_name)"
    refute_includes index, "notice"

    assert_class_tokens(show, "card", "card-border")
    assert_includes show, 'method: :delete, class: "btn btn-outline btn-error btn-rapid"'
    assert_class_tokens(partial, "list")
    assert_class_tokens(partial, "list-row")
    assert_includes partial, "<%%= dom_id <%= singular_name %> %>"
    assert_class_tokens(controller, "card", "card-border")
    assert_includes controller, "<%= class_name %>#<%= @action %>"
    assert_includes controller, "Find me in <%= @path %>"

    refute_match(/style\s*=/, combined)
    refute_match(/(?:bg|text|border)-(?:blue|gray|slate|red|green|yellow)-\d+/, combined)
    refute_includes combined, "dark:"
    refute_match(/#[0-9a-f]{3,8}(?![0-9a-z])/i, combined)
    refute_match(/\bmin-h-\d+/, combined)
  end

  def test_devise_fixtures_satisfy_the_generated_unique_email_constraint
    assert_includes @source, 'email: one@example.com'
    assert_includes @source, 'email: two@example.com'
    assert_includes @source, 'Devise::Encryptor.digest(User, "password123")'
  end

  def test_generates_the_pwa_manifest_routes_registration_and_push_handlers
    pwa = source_between("def configure_pwa", "def configure_web_push")
    worker = generated_file_source("app/views/pwa/service-worker.js")
    controller = generated_file_source("app/javascript/controllers/pwa_controller.js")
    layout = generated_file_source("app/views/layouts/application.html.erb")

    assert_includes pwa, 'route \'get "manifest" => "rails/pwa#manifest", as: :pwa_manifest\''
    assert_includes pwa, 'route \'get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker\''
    assert_includes pwa, 'display: "standalone"'
    assert_includes pwa, 'theme_color: "#3ea8ff"'
    assert_includes pwa, 'src: "/icon.png"'
    assert_includes pwa, 'theme_color: "#3ea8ff"'
    defaults = source_between("def configure_default_views", "def configure_web_push")
    assert_includes defaults, '<meta name="theme-color" content="#3ea8ff">'
    assert_includes defaults, 'tag.link rel: "manifest", href: pwa_manifest_path(format: :json)'
    assert_includes defaults, '#{pwa_head.lines.map'
    assert_includes defaults, 'body_data_attributes = body_controllers.empty? ? "" : %( data-controller="#{body_controllers.join(\' \')}")'
    assert_includes controller, 'navigator.serviceWorker.register("/service-worker", { scope: "/" })'
    assert_includes worker, 'self.addEventListener("push"'
    assert_includes worker, 'self.registration.showNotification(payload.title, options)'
    assert_includes worker, 'self.addEventListener("notificationclick"'
    assert_includes worker, 'candidate.origin === self.location.origin'
    assert_includes worker, 'self.clients.openWindow(targetUrl.href)'
  end

  def test_generates_authenticated_web_push_storage_delivery_and_endpoints
    web_push = source_between("def configure_web_push", "def install_solid_components")
    model = generated_file_source("app/models/push_subscription.rb")
    migration = web_push[/create_file migration\.first, <<~RUBY, force: true\n(?<body>.*?)^  RUBY$/m, :body]
    vapid = generated_file_source("app/services/vapid_configuration.rb")
    job = generated_file_source("app/jobs/push_notification_job.rb")
    notifier = generated_file_source("app/services/push_notifier.rb")
    controller = generated_file_source("app/controllers/push_subscriptions_controller.rb")

    assert_equal 'gem "web-push", "~> 3.1" if VALUES.fetch("web_push") == "use"', @source.lines.grep(/gem "web-push"/).first.strip
    assert_includes web_push, 'VAPID_SUBJECT = "https://localhost"'
    assert_includes web_push, 'append_to_file ".gitignore", "\\n/mise.local.toml\\n"'
    assert_includes web_push, 'environment "config.action_controller.cache_store = :memory_store", env: "test"'
    assert_includes migration, 'foreign_key: { on_delete: :cascade }'
    assert_includes migration, 'add_index :push_subscriptions, :browser_id, unique: true'
    assert_includes migration, 'add_index :push_subscriptions, :endpoint, unique: true'
    assert_includes model, 'browser_subscription = lock.find_by(browser_id:'
    assert_includes model, 'endpoint_subscription = lock.find_by(endpoint:'
    assert_includes model, 'subscription.update!(attributes.merge(user:))'
    assert_includes web_push, 'has_many :push_subscriptions, dependent: :destroy'
    assert_includes vapid, 'ENV.fetch("VAPID_PUBLIC_KEY")'
    assert_includes vapid, 'VAPID_SUBJECT must use mailto or https'
    assert_includes job, 'PushSubscription.find_by(id: subscription_id, user_id: expected_user_id)'
    assert_includes job, 'retry_on WebPush::TooManyRequests, WebPush::PushServiceError'
    assert_includes job, 'wait: :polynomially_longer, attempts: 5'
    assert_includes job, 'rescue WebPush::ExpiredSubscription, WebPush::InvalidSubscription'
    %w[open_timeout read_timeout ssl_timeout].each { |timeout| assert_includes job, "#{timeout}: 5" }
    assert_includes notifier, 'path.start_with?("/") && !path.start_with?("//")'
    assert_includes notifier, 'PushNotificationJob.perform_later(subscription.id, user.id, payload, ttl.to_i)'
    assert_includes controller, 'rate_limit to: 5, within: 1.minute, only: :test'
    assert_includes controller, 'head :accepted'
    assert_includes controller, 'status: :service_unavailable'
    assert_includes web_push, 'resource :push_subscription, only: %i[create destroy]'
    assert_includes web_push, 'resource :notification, only: :show'
    assert_includes controller, 'data: { path: notification_path }'
    assert_includes web_push, 'params.expect(push_subscription: %i[browser_id endpoint p256dh auth])'
  end

  def test_solid_queue_uses_the_test_adapter_only_in_test_environment
    solid = source_between("def install_solid_components", "def configure_common_files")

    assert_includes solid, 'environment "config.active_job.queue_adapter = :solid_queue"'
    assert_includes solid, 'environment "config.active_job.queue_adapter = :test", env: "test"'
    assert_includes solid, 'plugin :solid_queue if ENV.fetch(\\"RAILS_ENV\\", \\"development\\") == \\"development\\"'
  end

  def test_installs_maintenance_tasks_through_the_official_generator_and_admin_boundary
    maintenance = source_between("def install_maintenance_tasks", "def configure_common_files")
    route = source_between("def configure_maintenance_tasks_route", "def run_checked")
    controller = generated_file_source("app/controllers/admin/maintenance_tasks_controller.rb")
    policy = generated_file_source("app/policies/maintenance_task_policy.rb")
    initializer = generated_file_source("config/initializers/maintenance_tasks.rb")
    layout = generated_file_source("app/views/layouts/maintenance_tasks/admin.html.erb")
    stylesheet = generated_file_source("app/assets/stylesheets/maintenance_tasks.css")
    refresh = generated_file_source("app/javascript/controllers/maintenance_tasks_refresh_controller.js")
    controller_test = generated_file_source("test/controllers/admin/maintenance_tasks_controller_test.rb")
    after_bundle = @source.byteslice(@source.index("after_bundle do")..)

    assert_includes @source, 'gem "maintenance_tasks", "2.17.0" if VALUES.fetch("maintenance_tasks") == "enable"'
    assert_includes maintenance, 'generate "maintenance_tasks:install"'
    assert_includes route, "Prism.parse(source)"
    assert_includes route, 'actual == \'mount MaintenanceTasks::Engine, at: "/maintenance_tasks"\''
    assert_includes route, 'mount MaintenanceTasks::Engine, at: "/admin/maintenance_tasks", as: :admin_maintenance_tasks'
    assert_includes initializer, 'MaintenanceTasks.parent_controller = "Admin::MaintenanceTasksController"'
    assert_includes initializer, '"triggered_by_type"'
    assert_includes initializer, '"triggered_by_identifier"'
    assert_includes initializer, "SecureRandom.base64(16)"
    assert_includes initializer, "%w[script-src-elem style-src-elem]"
    assert_includes controller, "class MaintenanceTasksController < BaseController"
    assert_includes controller, "include Rails.application.routes.url_helpers"
    assert_includes controller, "helper Rails.application.routes.url_helpers"
    assert_includes controller, "authorize! :maintenance_task, to: :manage?"
    refute_includes controller, "has_role?"
    assert_includes policy, "def manage?"
    assert_includes policy, "admin?"
    assert_includes layout, 'render template: "layouts/admin"'
    assert_includes layout, 'data-controller="maintenance-tasks-refresh"'
    assert_includes layout, "bulma@1.0.4/css/bulma.min.css"
    assert_includes stylesheet, "[data-maintenance-tasks-root]"
    assert_includes stylesheet, '[data-maintenance-tasks-shell="true"]'
    assert_includes stylesheet, "grid-template-columns: 220px minmax(0, 1fr)"
    assert_includes stylesheet, "repeat(auto-fit, minmax(min(20rem, 100%), 1fr))"
    assert_includes refresh, 'this.element.querySelector("[data-refresh]")'
    assert_includes refresh, "window.setTimeout"
    assert_includes refresh, "this.abortController?.abort()"
    assert_includes maintenance, 'create_file "docs/maintenance_tasks.md"'
    assert_includes controller_test, "assert_enqueued_with(job: MaintenanceTasks::TaskJob)"
    assert_includes controller_test, 'assert_equal "succeeded", run.reload.status'
    assert_includes maintenance, "no_collection"
    assert_includes maintenance, "def process"
    refute_match(/create_file "app\/tasks\/maintenance\//, maintenance)
    refute_includes maintenance, '.keep'
    assert_operator after_bundle.index("install_solid_components"), :<,
      after_bundle.index('install_maintenance_tasks if VALUES.fetch("maintenance_tasks") == "enable"')
    assert_operator after_bundle.index('install_maintenance_tasks if VALUES.fetch("maintenance_tasks") == "enable"'), :<,
      after_bundle.index("configure_database")
  end

  def test_generates_web_push_client_state_reconciliation_and_notification_page
    client = generated_file_source("app/javascript/controllers/push_subscription_controller.js")
    notifications_view = generated_file_source("app/views/notifications/show.html.erb")
    notifications_controller = generated_file_source("app/controllers/notifications_controller.rb")
    evidence = source_between("def configure_evidence_capture", "def configure_annotaterb")
    defaults = source_between("def configure_default_views", "def configure_web_push")
    devise = source_between("def configure_devise_views", "def configure_default_views")

    assert_includes client, 'if (permission === "default") permission = await Notification.requestPermission()'
    assert_includes client, 'if (!this.#sameApplicationServerKey(subscription, publicKey))'
    assert_includes client, 'await subscription.unsubscribe()'
    assert_includes client, 'await this.#deleteServerSubscription()'
    assert_includes client, 'await this.#save(subscription)'
    assert_includes client, 'crypto.randomUUID()'
    assert_includes client, 'typeof window.Notification !== "undefined"'
    assert_includes client, 'Boolean(navigator.serviceWorker)'
    assert_includes notifications_view, 't("web_push.page.title")'
    assert_includes notifications_view, 'data-action="change->push-subscription#toggle"'
    assert_includes notifications_view, 'data-action="click->push-subscription#sendTest"'
    assert_includes notifications_view, 'aria-live="polite"'
    assert_includes notifications_controller, 'layout "account"'
    assert_includes defaults, 'link_to notification_path'
    assert_includes defaults, 'controller_path == "notifications"'
    refute_includes defaults, 'web_push_section'
    refute_includes devise, 'accounts/push_notifications'
    assert_includes defaults, 'body_controllers << "push-subscription" if web_push_enabled'
    assert_includes evidence, 'set_evidence_web_push_mode("rotated")'
    assert_includes evidence, 'set_evidence_web_push_mode("default")'
    assert_includes evidence, 'set_evidence_web_push_mode("denied")'
    assert_includes evidence, 'set_evidence_web_push_mode("unsupported")'
  end

  def test_generates_fixed_multi_role_storage_and_action_policy_authorization
    roles = source_between("def configure_roles", "def configure_profile")
    model = generated_file_source("app/models/user_role.rb")
    policy = generated_file_source("app/policies/user_policy.rb")
    users_controller = generated_file_source("app/controllers/admin/users_controller.rb")
    roles_controller = generated_file_source("app/controllers/admin/user_roles_controller.rb")

    assert_includes roles, 'generate "action_policy:install"'
    assert_includes roles, 'generate "model", "UserRole", "user:references", "role:string"'
    assert_includes roles, 't.references :user, null: false, foreign_key: { on_delete: :cascade }'
    assert_includes roles, 'add_index :user_roles, [:user_id, :role], unique: true'
    assert_includes roles, 'add_check_constraint :user_roles, "role IN (\'admin\')", name: "user_roles_role_check"'
    assert_includes model, 'ROLES = { admin: "admin" }.freeze'
    assert_includes model, 'enum :role, ROLES, validate: true'
    assert_includes model, 'validates :role, uniqueness: { scope: :user_id }'
    assert_includes model, 'before_destroy :ensure_admin_remains, if: :admin?'
    assert_includes roles, 'has_many :user_roles, dependent: :destroy'
    assert_includes roles, 'def has_role?(role)'
    assert_includes roles, 'def grant_role!(role)'
    assert_includes roles, 'find_or_create_by!(role: normalized_role)'
    assert_includes roles, 'def revoke_role!(role)'
    assert_includes roles, 'def last_admin?'

    assert_includes roles, 'authorize :user, through: :authorization_user'
    assert_includes roles, 'helper_method :authorization_user'
    assert_includes roles, 'rescue_from ActionPolicy::Unauthorized, with: :render_forbidden'
    assert_includes roles, 'include Pagy::Method'
    assert_includes policy, 'def index?'
    assert_includes policy, 'def manage_roles?'
    assert_includes policy, 'relation_scope do |relation|'
    assert_includes users_controller, 'authorize! User, to: :index?'
    assert_includes users_controller, 'authorized_scope(User.all)'
    assert_includes users_controller, 'pagy(:offset, users, limit: 25)'
    assert_includes roles_controller, 'authorize! @user, to: :manage_roles?'
    assert_includes roles_controller, '@user == authorization_user'
    assert_includes roles_controller, 'head :unprocessable_content'
    assert_includes roles, 'resources :roles, only: %i[create destroy], controller: "user_roles", param: :role'
  end

  def test_generates_admin_role_ui_bootstrap_task_and_local_seed_hook
    roles = source_between("def configure_roles", "def configure_profile")
    view = generated_file_source("app/views/admin/users/index.html.erb")
    task = generated_file_source("lib/tasks/roles.rake")
    local_seed = generated_file_source("db/seeds.local.rb.example")

    assert_class_tokens view, "card", "card-border"
    assert_class_tokens view, "overflow-x-auto"
    assert_class_tokens view, "table", "table-sm", "table-pin-rows"
    assert_class_tokens view, "badge"
    assert_class_tokens view, "btn", "btn-outline", "btn-error"
    assert_class_tokens view, "join"
    assert_class_tokens view, "btn", "join-item"
    assert_includes view, 'admin_user_roles_path(user)'
    assert_includes view, 'admin_user_role_path(user, "admin")'
    assert_includes view, '@pagy.page_url(:previous)'
    assert_includes view, '@pagy.page_url(:next)'
    refute_match(/(?:bg|text|border)-(?:blue|gray|slate|red|green|yellow)-\d+/, view)
    refute_includes view, "dark:"
    refute_match(/#[0-9a-f]{3,8}(?![0-9a-z])/i, view)

    assert_includes task, 'task :grant_admin, [:identifier] => :environment'
    assert_includes task, 'find_by!('
    assert_includes task, 'user.grant_role!(:admin)'
    assert_includes roles, 'Rails.root.join("db/seeds.local.rb")'
    assert_includes roles, 'load local_seeds if local_seeds.file?'
    assert_includes roles, 'append_to_file ".gitignore", "\\n/db/seeds.local.rb\\n"'
    assert_includes local_seed, 'ENV.fetch("#{identifier_environment}")'
    assert_includes local_seed, 'admin.grant_role!(:admin)'
    assert_includes roles, 'create_locale_pair("roles"'
    assert_includes roles, '"last_admin" => "The final administrator cannot delete their account"'
    assert_includes roles, 'I18n.t("admin.user_roles.create.notice")'
    assert_includes roles, 'I18n.t("admin.user_roles.destroy.self_forbidden")'
  end

  def test_role_generation_covers_both_authentication_contexts_and_last_admin_deletion
    roles = source_between("def configure_roles", "def configure_profile")
    devise_registration = generated_file_source("app/controllers/users/registrations_controller.rb")
    defaults = source_between("def configure_default_views", "def configure_web_push")

    assert_includes roles, 'authorization_user = devise ? "current_user" : "Current.user"'
    assert_includes roles, 'authentication_callback = devise ? "    before_action :authenticate_user!\\n" : ""'
    assert_includes roles, 'configure_devise_registration_route'
    assert_includes @source, 'devise_for :users, controllers: { registrations: "users/registrations" }'
    assert_includes devise_registration, 'if resource.last_admin?'
    assert_includes devise_registration, 'I18n.t("accounts.destroy.last_admin")'
    assert_includes defaults, 'if user.last_admin?'
    assert_includes defaults, 'I18n.t("accounts.destroy.last_admin")'
    assert_match(/install_wallet_siwe\n  configure_roles/, @source)
  end

  def test_role_tests_cover_storage_policy_controllers_and_task
    model_test = generated_file_source("test/models/user_role_test.rb")
    policy_test = generated_file_source("test/policies/user_policy_test.rb")
    users_controller_test = generated_file_source("test/controllers/admin/users_controller_test.rb")
    roles_controller_test = generated_file_source("test/controllers/admin/user_roles_controller_test.rb")
    task_test = generated_file_source("test/tasks/roles_task_test.rb")

    assert_includes model_test, 'assert_not invalid.valid?'
    assert_includes model_test, 'assert_no_difference("UserRole.count") { user.grant_role!(:admin) }'
    assert_includes model_test, 'UserRole.insert_all!'
    assert_includes model_test, 'assert_raises(ActiveRecord::NotNullViolation)'
    assert_includes model_test, 'assert_raises(ActiveRecord::RecordNotDestroyed)'
    assert_includes model_test, 'assert_not user.destroy'
    assert_includes policy_test, 'apply(:index?)'
    assert_includes policy_test, 'apply_scope(User.all, type: :active_record_relation)'
    assert_includes users_controller_test, 'assert_have_authorized_scope(type: :active_record_relation, with: UserPolicy)'
    assert_includes users_controller_test, 'assert_response :forbidden'
    assert_includes users_controller_test, 'create_additional_users(25)'
    assert_includes users_controller_test, 'I18n.t("admin.users.pagination")'
    assert_includes roles_controller_test, 'assert_no_difference("UserRole.count")'
    assert_includes roles_controller_test, 'assert_response :unprocessable_content'
    assert_includes @source, 'test "refuses deletion of the last admin account"'
    assert_includes task_test, 'assert_no_difference("User.count")'
    assert_includes task_test, '@task.reenable'
    assert_includes task_test, 'load Rails.root.join("db/seeds.rb")'
    assert_includes task_test, 'File.write(local_seeds, \'ENV["ROLE_LOCAL_SEED_LOADED"] = "yes"\\n\')'
    assert_includes @source, 'require "action_policy/test_helper"'
    assert_includes @source, 'include ActionPolicy::TestHelper'
  end

  def test_generated_form_controls_and_cards_keep_design_system_dimensions_and_borders
    @source.scan(/class: "input[^"]*"/).each do |input_class|
      assert_includes input_class, "input-rapid"
      refute_includes input_class, "min-h-11"
    end

    @source.scan(/class="[^"]*card-border[^"]*"/).each do |card_class|
      assert card_class.include?("border-base-300") || card_class.include?("border-error"), card_class
    end

    input_utility = @source[/@utility input-rapid \{.*?^    \}/m]
    refute_nil input_utility
    assert_includes input_utility, "--input-color: var(--color-base-300)"
    assert_includes input_utility, "--input-color: var(--color-primary)"
    assert_includes input_utility, "font-size: 1rem"

    helper_button_classes = @source.scan(/class: "([^"]*\bbtn\b[^"]*)"/).flatten
    html_button_classes = @source.scan(/class="([^"]*\bbtn\b[^"]*)"/).flatten
    assert_operator helper_button_classes.length + html_button_classes.length, :>, 0
    button_classes = helper_button_classes + html_button_classes
    button_classes.each { |button_class| refute_includes button_class, "min-h-11" }
    button_classes.select { |classes| classes.split.include?("btn-primary") }.each do |button_class|
      assert_includes button_class, "btn-rapid"
    end

    button_utility = @source[/@utility btn-rapid \{.*?^    \}/m]
    refute_nil button_utility
    assert_includes button_utility, "font-size: 1rem"
    assert_includes button_utility, "font-weight: 700"
    assert_operator @source.scan("btn btn-primary btn-outline btn-rapid").length, :>=, 2
  end

  def test_wallet_sign_in_uses_the_stimulus_lifecycle_for_turbo_navigation
    assert_includes @source, 'app/javascript/controllers/siwe_sign_in_controller.js'
    assert_includes @source, 'import { Controller } from "@hotwired/stimulus"'
    assert_includes @source, 'data-controller="siwe-sign-in"'
    assert_includes @source, 'data-action="click->siwe-sign-in#signIn"'
    assert_includes @source, 'data-siwe-sign-in-target="error"'
    refute_includes @source, 'app/javascript/siwe_sign_in.js'
    refute_includes @source, 'import \\"siwe_sign_in\\"'
  end

  def test_wallet_account_settings_own_identity_and_account_deletion
    profile = generated_file_source("app/views/accounts/show.html.erb")
    settings = generated_file_source("app/views/accounts/edit.html.erb")

    refute_includes profile, "Current.user.wallet_address"
    refute_includes profile, ">ID<"
    assert_includes settings, "Current.user.wallet_address"
    assert_includes settings, 'button_to t("accounts.edit.delete"), account_path, method: :delete'
    assert_includes settings, "btn btn-outline btn-error btn-rapid"
    assert_includes @source, 'notice: I18n.t("accounts.destroy.notice")'
    assert_includes @source, '"notice" => "Your account was deleted."'
  end

  def test_profile_generation_is_conditional_and_uses_selected_features
    controller = generated_file_source("app/controllers/profiles_controller.rb")
    avatar_helper = generated_file_source("app/helpers/avatar_helper.rb")
    avatar_helper_test = generated_file_source("test/helpers/avatar_helper_test.rb")
    profile_configuration = source_between("def configure_profile", "def configure_api")

    assert_includes @source, 'configure_profile if VALUES.fetch("profile_features").any?'
    refute_includes @source, 'rails_command "active_storage:install"'
    assert_includes @source, 't.references :user, null: false, foreign_key: true, index: { unique: true }'
    assert_includes @source, 'has_one :profile, dependent: :destroy'
    assert_includes @source, 'after_create :create_profile!'
    assert_includes @source, 'gem "haikunator" if (VALUES.fetch("profile_features") & %w[screen_name display_name]).any?'
    assert_includes @source, 'gem "boring_avatars", "~> 0.1.0", require: "boring_avatars/bindings/rails" if VALUES.fetch("profile_features").include?("avatar")'
    assert_includes profile_configuration, 't.string :screen_name, null: false'
    assert_includes profile_configuration, 't.string :display_name, null: false'
    assert_includes profile_configuration, 't.index :screen_name, unique: true'
    assert_includes profile_configuration, 't.index :display_name, unique: true'
    assert_includes profile_configuration, 'has_one_attached :avatar'
    assert_includes profile_configuration, 'validates :screen_name, presence: true, uniqueness: true, format:'
    assert_includes profile_configuration, 'validates :display_name, presence: true, uniqueness: true'
    assert_includes profile_configuration, '[a-z0-9_]+'
    assert_includes profile_configuration, 'before_validation :assign_generated_names, on: :create'
    assert_includes profile_configuration, 'candidate = Haikunator.haikunate(9999, "_")'
    assert_includes profile_configuration, 'next if self.class.exists?(screen_name: candidate)'
    assert_includes profile_configuration, 'next if self.class.exists?(display_name: candidate.camelize)'
    assert_includes profile_configuration, 'self.display_name = screen_name.camelize if display_name.blank?'
    assert_includes profile_configuration, 'required: true'
    assert_includes controller, 'params.expect(profile: ['
    assert_includes controller, 'I18n.t("profiles.update.notice")'
    assert_includes profile_configuration, '<fieldset class="fieldset min-w-0 grid-cols-1">'
    assert_includes profile_configuration, 'form.file_field :avatar_upload, class: "file-input min-w-0 w-full", accept: "image/jpeg,image/png,image/webp"'
    assert_includes profile_configuration, '<p class="label"><span class="min-w-0 whitespace-normal"><%= t("profiles.avatar_hint") %></span></p>'
    assert_includes @source, 'route "resource :profile, only: %i[show edit update]"'
    assert_includes profile_configuration, 'delete "profile/avatar", to: "profiles#destroy_avatar", as: :profile_avatar'
    assert_includes profile_configuration, "def destroy_avatar"
    assert_includes profile_configuration, ".profile.avatar.purge if"
    assert_includes profile_configuration, 'I18n.t("profiles.avatar.destroy.notice")'
    assert_includes profile_configuration, '"notice" => "Your avatar image was deleted."'
    assert_includes avatar_helper, "BORING_AVATAR_COLORS = %w[#3ea8ff #0f83fd #10b981 #f59e0b #f43f5e].freeze"
    assert_includes avatar_helper, "profile.user_id.to_s"
    assert_includes avatar_helper, "variant: :marble"
    assert_includes avatar_helper, "AVATAR_VARIANTS = { 40 => :header_avatar, 64 => :profile_avatar }.freeze"
    assert_includes avatar_helper, "image_tag profile.avatar.variant(variant)"
    assert_includes avatar_helper, "width: size, height: size"
    assert_includes profile_configuration, "attachment.variant :header_avatar, resize_to_fill: [40, 40]"
    assert_includes profile_configuration, "attachment.variant :profile_avatar, resize_to_fill: [64, 64]"
    assert_includes profile_configuration, "validates :avatar_upload, avatar_upload: true"
    assert_includes profile_configuration, "self.avatar = avatar_upload"
    assert_includes profile_configuration, "MAX_BYTES = 5 * 1024 * 1024"
    assert_includes profile_configuration, "MAX_DIMENSION = 4096"
    assert_includes profile_configuration, "Marcel::MimeType.for"
    assert_includes profile_configuration, 'Vips::Image.new_from_file(path, access: :sequential, fail_on: :truncated)'
    assert_includes avatar_helper_test, "profile.user_id.to_s"
    assert_includes avatar_helper_test, "normalize_boring_avatar_ids"
    refute_includes profile_configuration, "boring_avatar_seed"
    assert_includes @source, 'assert_equal user.profile.screen_name.camelize, user.profile.display_name'
  end

  def test_configures_explicit_rails_and_imgproxy_image_delivery_boundaries
    delivery = source_between("def configure_image_delivery", "def install_action_text")
    configuration = generated_file_source("lib/image_delivery_configuration.rb")
    adapter = generated_file_source("lib/imgproxy/active_storage_url_adapter.rb")
    initializer = generated_file_source("config/initializers/imgproxy.rb")
    action_text_test = generated_file_source("test/controllers/pages_controller_test.rb")

    assert_includes @source, 'gem "imgproxy-rails", "~> 0.3.0" if VALUES.fetch("image_delivery") == "imgproxy"'
    assert_includes delivery, "config.active_storage.variant_processor = :vips"
    assert_includes delivery, "config.active_storage.track_variants = true"
    assert_includes delivery, "rails_storage_redirect"
    assert_includes delivery, "imgproxy_active_storage"
    assert_includes configuration, 'environment.fetch("IMGPROXY_ENDPOINT")'
    assert_includes configuration, 'environment.fetch("IMGPROXY_KEY")'
    assert_includes configuration, 'environment.fetch("IMGPROXY_SALT")'
    assert_includes configuration, 'application_identity.canonical_origin'
    assert_includes configuration, "NON_PUBLIC_IPV4_NETWORKS"
    assert_includes configuration, "GLOBAL_IPV6_NETWORK"
    assert_includes configuration, "addresses.all? { |address| public_address?(address) }"
    assert_includes adapter, "rails_storage_proxy_path(image)"
    assert_includes initializer, "config.url_adapters.clear!"
    assert_includes initializer, "Imgproxy::ActiveStorageUrlAdapter"
    assert_includes action_text_test, "keeps Action Text image attachments separate from the avatar policy"
    assert_includes delivery, 'assert_not_includes url, "/unsafe/"'
    refute_includes delivery, 'ENV.fetch("IMGPROXY_ENDPOINT",'
  end

  def test_installs_action_text_and_configures_lexxy_before_daisyui
    after_bundle = @source.byteslice(@source.index("after_bundle do")..)
    content = generated_file_source("app/views/layouts/action_text/contents/_content.html.erb")
    application_layout = generated_file_source("app/views/layouts/application.html.erb")

    assert_includes @source, 'gem "lexxy", "~> 0.9.21"'
    assert_includes @source, 'generate "action_text:install"'
    assert_includes @source, 'pin "lexxy", to: "lexxy.js"'
    assert_includes @source, 'pin "@rails/activestorage", to: "activestorage.esm.js"'
    assert_includes @source, 'import "lexxy"'
    assert_includes application_layout, 'stylesheet_link_tag "lexxy"'
    assert_class_tokens content, "lexxy-content"
    assert_operator after_bundle.index("install_action_text"), :<, after_bundle.index("configure_lexxy")
    assert_operator after_bundle.index("configure_lexxy"), :<, after_bundle.index("install_daisyui")
  end

  def test_stores_active_storage_files_in_a_dedicated_sqlite_database
    after_bundle = @source.byteslice(@source.index("after_bundle do")..)
    storage = generated_file_source("config/storage.yml")
    initializer = generated_file_source("config/initializers/active_storage_db.rb")
    storage_test = generated_file_source("test/models/active_storage_db_test.rb")
    install = source_between("def install_active_storage_db", "def replace_active_storage_service")
    service_configuration = source_between("def configure_active_storage_db", "def configure_lexxy")
    database_configuration = source_between("def configure_database", "def configure_dokploy")

    assert_includes @source, 'gem "active_storage_db"'
    assert_includes install, 'run_checked "bin/rails active_storage_db:install:migrations"'
    assert_includes install, 'db/migrate/*_create_active_storage_db_files.active_storage_db.rb'
    assert_includes install, 'FileUtils.mv(installed_migrations.first, File.join("db/storage_migrate"'
    assert_includes storage, "db:\n      service: DB"
    assert_includes initializer, "ActiveStorageDB::ApplicationRecord.connects_to database: { writing: :storage, reading: :storage }"
    assert_includes service_configuration, '%w[development test production].each'
    assert_includes service_configuration, 'mount ActiveStorageDB::Engine => "/active_storage_db"'
    assert_includes database_configuration, '"storage/development_storage.sqlite3"'
    assert_includes database_configuration, '"storage/test_storage.sqlite3"'
    assert_includes database_configuration, '"storage/production_storage.sqlite3"'
    assert_includes database_configuration, "STORAGE_DATABASE_PATH"
    assert_includes database_configuration, '"db/storage_migrate"'
    assert_includes storage_test, "ActiveStorage::Blob.create_and_upload!"
    assert_includes storage_test, 'assert_equal "storage", ActiveStorageDB::ApplicationRecord.connection_db_config.name'
    assert_includes storage_test, "assert_equal contents, blob.download"
    assert_includes storage_test, "blob.purge"
    assert_operator after_bundle.index("install_action_text"), :<, after_bundle.index("install_active_storage_db")
    assert_operator after_bundle.index("install_active_storage_db"), :<, after_bundle.index("configure_lexxy")
    assert_operator after_bundle.index("install_solid_components"), :<, after_bundle.index("configure_database")
    assert_operator after_bundle.index("configure_database"), :<, after_bundle.index("configure_active_storage_db")
    assert_operator after_bundle.index("configure_active_storage_db"), :<, after_bundle.index('run_checked "bin/rails db:prepare"')
  end

  def test_dokploy_replicates_the_active_storage_database
    dokploy = source_between("def configure_dokploy", "after_bundle do")

    assert_includes dokploy, '${STORAGE_DATABASE_PATH}'
    assert_includes dokploy, '${LITESTREAM_STORAGE_REPLICA_URL}'
  end

  def test_generates_fixed_pages_faqs_footer_settings_and_admin_management
    page_model = generated_file_source("app/models/page.rb")
    faq_model = generated_file_source("app/models/faq.rb")
    footer_setting_model = generated_file_source("app/models/footer_setting.rb")
    pages_controller = generated_file_source("app/controllers/pages_controller.rb")
    admin_pages_controller = generated_file_source("app/controllers/admin/pages_controller.rb")
    admin_faqs_controller = generated_file_source("app/controllers/admin/faqs_controller.rb")
    footer = generated_file_source("app/views/shared/_footer.html.erb")
    faq_index = generated_file_source("app/views/faqs/index.html.erb")

    assert_includes page_model, "has_rich_text :content, store_if_blank: false"
    assert_includes @source, '"transaction-law" => "content_management.pages.transaction_law"'
    assert_includes faq_model, "has_rich_text :answer"
    assert_includes faq_model, "where(published: true).order(:position, :id)"
    assert_includes footer_setting_model, "uri.is_a?(URI::HTTPS)"
    assert_includes footer_setting_model, "uri.host.present?"
    assert_includes footer_setting_model, "uri.userinfo.nil?"
    assert_includes pages_controller, "TEMPLATES.fetch(@page.slug)"
    assert_includes admin_pages_controller, "params.expect(page: [:content])"
    refute_includes admin_pages_controller, "params.expect(page: [:content, :slug])"
    assert_includes admin_faqs_controller, "authorize!"
    assert_includes admin_faqs_controller, "params.expect(faq: [:question, :answer, :position, :published])"
    assert_includes admin_faqs_controller, 'I18n.t("admin.faqs.update.notice")'
    assert_includes @source, 'get "/transaction-law", to: "pages#show"'
    assert_includes @source, 'resource :footer_setting, path: "footer-setting", only: %i[edit update]'
    assert_class_tokens faq_index, "collapse", "collapse-arrow"
    assert_includes faq_index, "faq.answer"
    assert_class_tokens footer, "footer", "footer-vertical", "sm:footer-horizontal"
    assert_equal 4, class_attributes(footer).count { |classes| classes.include?("footer-title") }
    assert_equal 9, footer.scan('class: "link link-hover"').size
    assert_includes footer, "external_links_configured"
    assert_includes footer, 'target: "_blank", rel: "noopener noreferrer"'
    refute_includes footer, "<aside"
  end

  def test_boring_avatar_palette_matches_the_rapid_rails_theme
    helper = generated_file_source("app/helpers/avatar_helper.rb")
    palette = helper[/BORING_AVATAR_COLORS = %w\[(.*?)\]/, 1].split

    assert_equal %w[#3ea8ff #0f83fd #10b981 #f59e0b #f43f5e], palette
    palette.each { |color| assert_match(/--color-[^:]+: #{Regexp.escape(color)};/, @source) }
  end

  def test_api_credentials_use_digest_authentication_owner_scopes_and_one_time_secret_views
    model = generated_file_source("app/models/api_credential.rb")
    api_controller = generated_file_source("app/controllers/api/api_controller.rb")
    api_credentials_controller = generated_file_source("app/controllers/api/api_credentials_controller.rb")
    web_controller = generated_file_source("app/controllers/api_credentials_controller.rb")
    index = generated_file_source("app/views/api_credentials/index.html.erb")
    show = generated_file_source("app/views/api_credentials/show.html.erb")
    clipboard_controller = generated_file_source("app/javascript/controllers/clipboard_controller.js")

    assert_includes model, "Digest::SHA256.hexdigest(value)"
    assert_includes model, "ActiveSupport::SecurityUtils.secure_compare"
    assert_includes model, "def revoke_api_secret!"
    assert_includes @source, 'remove_file "test/fixtures/api_credentials.yml"'
    refute_match(/t\.string :api_secret(?:,|\n)/, @source)
    assert_includes api_controller, "authenticate_with_http_token"
    assert_includes api_controller, 'token.to_s.split(".", 2)'
    assert_includes api_controller, "credential.update!(last_used_at: Time.current)"
    refute_includes api_controller, "credential.touch"
    assert_includes api_credentials_controller, "current_api_user.api_credentials"
    assert_includes api_credentials_controller, "params.expect(api_credential: [:name])"
    assert_includes web_controller, "account_user.api_credentials.find(params.expect(:id))"
    assert_includes show, 't("api_credentials.secret_once")'
    assert_includes show, 'input type="text" value="<%= @api_secret %>" readonly'.b
    assert_includes show, 'input type="text" value="<%= @api_credential.api_key %>" readonly'.b
    assert_includes index, 'input type="text" value="<%= credential.api_key %>" readonly'.b
    assert_includes index, "t('api_credentials.api_key_label', name: credential.name)"
    assert_includes index, 'class="join w-80" data-controller="clipboard"'.b
    assert_includes index, 'data-action="clipboard#copy"'
    assert_equal 2, show.scan('data-controller="clipboard"').length
    assert_equal 2, show.scan('class="join w-full"').length
    refute_includes show, "Bearer token"
    assert_includes clipboard_controller, 'static targets = ["source", "button"]'
    assert_includes clipboard_controller, "await navigator.clipboard.writeText(this.sourceTarget.value)"
    assert_includes clipboard_controller, "this.buttonTarget.textContent = this.copiedValue"
    assert_includes @source, 'd="M17.25 6.75 22.5 12l-5.25 5.25m-10.5 0L1.5 12l5.25-5.25m7.5-3-4.5 16.5"'
    assert_includes @source, "namespace :api do"
    assert_includes @source, "resources :api_credentials, only: %i[index show create update destroy]"
    assert_includes @source, 'configure_api if VALUES.fetch("api") == "enable"'
    refute_includes @source, "account_navigation_items << <<~ERB"
  end

  def test_default_page_integration_uses_the_generated_role_api
    assert_includes @source, "user.grant_role!(:admin)"
    refute_includes @source, "user.add_role(:admin)"
  end

  def test_prepares_the_database_after_generators_and_before_verification_commands
    after_bundle = @source.byteslice(@source.index("after_bundle do")..)

    assert_operator after_bundle.index("configure_database"),
      :<, after_bundle.index('run_checked "bin/rails db:prepare"')
    assert_operator after_bundle.index("configure_active_storage_db"),
      :<, after_bundle.index('run_checked "bin/rails db:prepare"')
    assert_operator after_bundle.index('configure_dokploy if VALUES.fetch("deployment") == "dokploy"'),
      :<, after_bundle.index('run_checked "bin/rails db:prepare"')
    assert_operator after_bundle.index('run_checked "bin/rails db:prepare"'),
      :<, after_bundle.index('run_checked "bin/rails tailwindcss:build"')
  end

  def test_installs_annotaterb_and_checks_annotations_in_the_regular_test_suite
    annotation_test = generated_file_source("test/annotations_test.rb")
    after_bundle = @source.byteslice(@source.index("after_bundle do")..)
    development_gems = source_between("gem_group :development do", "gem_group :test do")

    assert_includes development_gems, 'gem "annotaterb"'
    assert_includes @source, 'generate "annotate_rb:install"'
    assert_includes after_bundle, "configure_annotaterb"
    assert_operator after_bundle.index("configure_annotaterb"),
      :<, after_bundle.index('run_checked "bin/rails db:prepare"')
    assert_operator after_bundle.index('run_checked "bin/rails db:prepare"'),
      :<, after_bundle.index('run_checked "bundle binstubs annotaterb"')
    assert_operator after_bundle.index('run_checked "bundle binstubs annotaterb"'),
      :<, after_bundle.index('run_checked "bin/annotaterb models"')
    assert_includes annotation_test, '{ "RAILS_ENV" => "test" }'
    assert_includes annotation_test, 'Rails.root.join("bin/annotaterb").to_s'
    assert_includes annotation_test, '"models"'
    assert_includes annotation_test, '"--frozen"'
    assert_includes annotation_test, "assert status.success?"
    assert_includes annotation_test, "Run bin/annotaterb models"
  end

  def test_generates_deterministic_playwright_evidence_capture
    evidence = source_between("def configure_evidence_capture", "def configure_annotaterb").force_encoding(Encoding::UTF_8)
    common_files = source_between("def configure_common_files", "def configure_evidence_capture").force_encoding(Encoding::UTF_8)

    assert_includes @source, 'Playwright::COMPATIBLE_PLAYWRIGHT_VERSION.strip'
    assert_includes @source, 'npm install --save-dev playwright@#{playwright_version}'
    assert_includes common_files, 'playwright_cli_executable_path: Rails.root.join("node_modules/.bin/playwright").to_s'
    assert_includes evidence, 'task capture: :environment do'
    assert_includes evidence, 'raise "evidence:captureはRAILS_ENV=testでのみ実行できます"'
    assert_includes evidence, "ensure\n          cleanup_succeeded = rebuild_test_database.call"
    assert_includes evidence, 'raise "test databaseの後始末に失敗しました" unless cleanup_succeeded'
    assert_includes evidence, 'VIEWPORTS = {'
    assert_includes evidence, '"desktop" => { "width" => 1400, "height" => 900 }'
    assert_includes evidence, '"mobile" => { "width" => 390, "height" => 844 }'
    assert_includes evidence, 'playwright_page.screenshot(path: path.to_s, fullPage: true, animations: "disabled")'
    assert_includes evidence, 'integration.post "/session"'
    assert_includes evidence, 'playwright_page.context.add_cookies'
    assert_includes evidence, 'fill_in User.human_attribute_name(:email), with: @user.email'
    assert_includes evidence, '"api-credential-secret"'
    assert_includes evidence, "def with_deterministic_secure_random"
    assert_includes evidence, "singleton_class.define_method(:urlsafe_base64, original_method)"
    assert_includes evidence, '"navigation-authenticated-open"'
    assert_includes evidence, '"about"'
    assert_includes evidence, '"faq"'
    assert_includes evidence, '"admin-page-edit"'
    assert_includes evidence, '"admin-faq-edit"'
    assert_includes evidence, '"admin-footer-setting"'
    assert_includes evidence, '"web-push-enabled"'
    assert_includes evidence, "def install_web_push_stub"
    assert_includes evidence, 'Object.defineProperty(window, "Notification"'
    assert_includes evidence, 'Object.defineProperty(navigator, "serviceWorker"'
    assert_includes evidence, 'async requestPermission()'
    assert_includes evidence, 'permissionRequests += 1'
    assert_includes evidence, 'find(\'[data-push-subscription-target="testButton"]\').click'
    assert_includes evidence, 'csrf.content = "evidence-csrf-token"'
    assert_includes evidence, 'vapid_key = WebPush.generate_key'
    assert_includes evidence, 'assert_selector "lexxy-editor"'
    assert_includes evidence, "def verify_footer_geometry"
    assert_includes evidence, '320 => "row"'
    assert_includes evidence, '640 => "column"'
    assert_includes evidence, 'assert_operator geometry.fetch("documentWidth"), :<=, geometry.fetch("viewportWidth")'
    assert_includes evidence, "def verify_admin_layout_geometry"
    assert_includes evidence, "[320, 640, 960, 961].each"
    assert_includes evidence, 'visit admin_pages_path'
    assert_includes evidence, '"admin layout should use one column at #{width}px"'
    assert_includes evidence, '"admin layout should use two columns at #{width}px"'
    assert_includes evidence, "def assert_admin_navigation_active"
    assert_includes evidence, "def assert_account_navigation_scope"
    assert_includes evidence, 'translate("navigation.account_menu")'
    assert_includes evidence, 'translate("navigation.admin_menu")'
    assert_includes evidence, 'runner = runner.sub("__AUTHENTICATION__", authentication.inspect)'
    assert_includes evidence, 'runner = runner.sub("__WEB_PUSH__", web_push.inspect)'
    assert_includes evidence, 'runner = runner.sub("__MAINTENANCE_TASKS__", maintenance_tasks.inspect)'
    assert_includes evidence, '"admin-maintenance-tasks"'
    assert_includes evidence, '"admin-maintenance-tasks-navigation-open"'
    assert_includes evidence, "def verify_maintenance_tasks_geometry"
    assert_includes evidence, "[320, 390, 640, 960, 961].each"
    assert_includes evidence, 'visit admin_maintenance_tasks_path'
    assert_includes evidence, 'meta[name="csp-nonce"]'
    refute_includes evidence, "runner.sub!"
    assert_includes @source, "configure_common_files\n  configure_evidence_capture"
  end

  def test_default_views_follow_the_design_background_breakpoint_and_component_sizing_contracts
    assert_includes @source, 'body class="min-h-screen bg-base-100'
    assert_includes @source, 'main class="flex-1 bg-base-200"'
    assert_includes @source, 'min-[961px]:grid-cols-[220px_minmax(0,1fr)]'
    assert_match(/class="[^"]*\bhidden\b[^"]*\bmin-\[961px\]:flex\b/, @source)
    assert_includes @source, 'min-[961px]:hidden'
    assert_includes @source, 'inline-flex min-h-11 items-center text-lg font-bold text-primary'
    assert_includes @source, '--color-neutral: rgba(0, 0, 0, 0.55)'
    assert_operator @source.scan("text-neutral").length, :>=, 10
    refute_includes @source, "text-base-content/55"

    heading_classes = @source.scan(/<h[1-6][^>]*class="([^"]*)"/).flatten
    assert_operator heading_classes.length, :>, 0
    heading_classes.each { |heading_class| assert_includes heading_class, "leading-[1.5]" }
  end

  def test_default_views_use_component_parts_instead_of_reimplementing_them
    header = generated_file_source("app/views/shared/_header.html.erb")
    footer = generated_file_source("app/views/shared/_footer.html.erb")
    account_layout = generated_file_source("app/views/layouts/account.html.erb")
    admin_layout = generated_file_source("app/views/layouts/admin.html.erb")
    admin_navigation = source_between(
      "  admin_navigation_items = <<~ERB",
      "  account_navigation_for_layout = account_navigation_items.lines"
    )
    authentication_layout = generated_file_source("app/views/layouts/authentication.html.erb")
    home = generated_file_source("app/views/home/index.html.erb")
    shared_links = generated_file_source("app/views/devise/shared/_links.html.erb")
    login = generated_file_source("app/views/devise/sessions/new.html.erb")
    account_navigation = source_between(
      "  account_navigation_items = <<~ERB",
      "  admin_navigation_items = <<~ERB"
    )

    assert_class_tokens header, "navbar", "mx-auto", "w-full", "max-w-6xl", "px-5"
    assert_class_tokens header, "dropdown", "dropdown-end", "dropdown-hover"
    assert_class_tokens header, "menu", "menu-sm", "dropdown-content"
    assert_class_tokens header, "btn", "btn-ghost"
    assert_class_tokens @source, "avatar"
    refute class_attributes(@source).any? { |classes| classes.include?("avatar-placeholder") }
    mobile_menu_classes = class_attributes(header).find { |classes| classes.include?("dropdown-content") }
    refute_nil mobile_menu_classes
    refute mobile_menu_classes.any? { |token| token.match?(/\Ap(?:[trblxy])?-/) }, mobile_menu_classes.inspect
    assert_class_tokens footer, "footer", "mx-auto", "w-full", "max-w-6xl", "px-5"
    assert_class_tokens footer, "footer", "footer-vertical", "sm:footer-horizontal"
    assert_equal 4, class_attributes(footer).count { |classes| classes.include?("footer-title") }
    assert_includes footer, 'class: "link link-hover"'
    refute_includes footer, "<aside"
    refute_includes footer, "Rails 8.1 / Tailwind CSS 4 / daisyUI 5"

    assert_class_tokens account_layout, "menu"
    assert_class_tokens account_layout, "menu-title"
    assert_class_tokens account_layout, "mx-auto", "w-full", "max-w-6xl", "px-5"
    refute_includes account_layout, "max-w-5xl"
    assert_class_tokens admin_layout, "menu"
    assert_class_tokens admin_layout, "menu-title"
    assert_class_tokens admin_layout, "mx-auto", "w-full", "max-w-6xl", "px-5"
    assert_includes admin_layout, 'data-layout="admin"'
    assert_includes admin_layout, 'min-[961px]:grid-cols-[220px_minmax(0,1fr)]'
    assert_includes admin_layout, "t('navigation.admin_menu')"
    assert_includes admin_layout, 't("navigation.admin")'
    assert_includes @source, 'layout "admin"'
    assert_includes account_navigation, '"menu-active" if current_page?'
    refute_includes account_navigation, '"bg-base-content text-base-100" if current_page?'
    refute_includes account_navigation, "min-h-11"
    refute_includes account_navigation, "ホームへ戻る".b
    refute_includes account_navigation, "root_path"
    assert_equal 5, account_navigation.scan('<svg xmlns="http://www.w3.org/2000/svg" class="size-5"').size
    assert_equal 5, account_navigation.scan('aria-hidden="true" data-slot="icon"').size
    assert_includes account_navigation, "profile_path"
    assert_includes account_navigation, 't("navigation.dashboard")'
    assert_includes account_navigation, 'M17.982 18.725A7.488 7.488 0 0 0 12 15.75'
    assert_includes account_navigation, 'M9.594 3.94c.09-.542.56-.94 1.11-.94'
    assert_includes account_navigation, 'link_to notification_path'
    assert_includes account_navigation, 't("navigation.notifications")'
    refute_includes account_navigation, 'M9 12.75 11.25 15 15 9.75'
    refute_includes account_navigation, 'allowed_to?(:index?, User)'
    refute_includes account_navigation, 'admin_users_path'
    refute_includes account_navigation, "admin_pages_path"
    refute_includes account_navigation, "admin_faqs_path"
    refute_includes account_navigation, "edit_admin_footer_setting_path"
    assert_equal 5, admin_navigation.scan('<svg xmlns="http://www.w3.org/2000/svg" class="size-5"').size
    assert_equal 5, admin_navigation.scan('aria-hidden="true" data-slot="icon"').size
    assert_includes admin_navigation, '"menu-active" if controller_path.in?(%w[admin/users admin/user_roles])'
    assert_includes admin_navigation, '"menu-active" if controller_path == "admin/pages"'
    assert_includes admin_navigation, '"menu-active" if controller_path == "admin/faqs"'
    assert_includes admin_navigation, '"menu-active" if controller_path == "admin/footer_settings"'
    assert_includes admin_navigation, '"menu-active" if controller_path.start_with?("maintenance_tasks/")'
    assert_includes @source, 'controller_path.start_with?("admin/") || controller_path.start_with?("maintenance_tasks/")'
    assert_includes header, 't("navigation.admin")'
    refute_includes @source, '<li class="menu-title"><span>管理</span></li>'.b
    assert_includes header, 'data: { turbo_method: :delete }'
    assert_includes @source, 'M3.75 6.75h16.5M3.75 12h16.5m-16.5 5.25h16.5'
    assert_includes @source, 't("common.menu")'
    refute_includes header, "min-h-11 items-center gap"

    assert_class_tokens authentication_layout, "hero"
    assert_class_tokens authentication_layout, "hero-content"
    assert_class_tokens home, "hero"
    assert_class_tokens home, "hero-content"
    assert_class_tokens shared_links, "divider"
    assert_class_tokens shared_links, "menu", "menu-sm"
    refute_includes shared_links, "border-t border-base-300"
    refute_includes shared_links, "min-h-11"
    refute_includes shared_links, "link link-primary"
    refute_match(/link_to[^\n]*\bclass:/, shared_links)

    assert_class_tokens login, "fieldset"
    assert_class_tokens login, "fieldset-legend"
    assert_class_tokens login, "input", "input-rapid"
    assert_class_tokens login, "checkbox"
    assert_class_tokens login, "btn", "btn-block", "btn-rapid"
  end

  def test_wallet_guest_navigation_uses_real_line_breaks
    guest_navigation = source_between(
      "  guest_desktop_navigation = if devise",
      "  profile_identity = if display_name_enabled"
    )

    assert_equal 4, guest_navigation.scan("<<~ERB").size
    refute_includes guest_navigation, "\\\\n'"
  end
end
