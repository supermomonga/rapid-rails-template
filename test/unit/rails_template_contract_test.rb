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

  def assert_source_order(template, *snippets)
    indexes = snippets.map { |snippet| template.index(snippet) || flunk("source snippet not found: #{snippet}") }
    assert_equal indexes.sort, indexes, "expected source order: #{snippets.join(' -> ')}"
  end

  def test_generates_one_application_identity_and_i18n_boundary
    identity = generated_file_source("lib/application_identity.rb")
    initializer = generated_file_source("config/initializers/application_identity.rb")
    concern = generated_file_source("app/controllers/concerns/localized_request.rb")
    helper = generated_file_source("app/helpers/application_helper.rb")
    helper_test = generated_file_source("test/helpers/application_helper_test.rb")
    layout = generated_file_source("app/views/layouts/application.html.erb")
    header = generated_file_source("app/views/shared/_header.html.erb")
    manifest = generated_file_source("app/views/pwa/manifest.json.erb")

    assert_includes identity, "AVAILABLE_LOCALES = %i[ja en].freeze"
    assert_includes identity, "canonical_origin_env = configuration[:canonical_origin_env]"
    assert_includes identity, "environment.fetch(canonical_origin_env)"
    assert_includes identity, "canonical_origin must be an HTTP(S) origin without path"
    assert_includes identity, "def siwe_statement(locale: default_locale)"
    assert_includes identity, "URI.encode_uri_component(app_name)"
    assert_includes initializer, "Rails.application.routes.default_url_options = identity.default_url_options"
    assert_includes initializer, "action_mailer.default_url_options = identity.default_url_options"
    assert_includes concern, "I18n.with_locale(I18n.default_locale, &action)"
    assert_includes helper, "Rails.configuration.x.application_identity"
    assert_includes helper, "class Tab < T::Struct"
    assert_includes helper, "const :is_active, T.nilable(T.proc.returns(T::Boolean)), default: nil"
    assert_includes helper, "module ApplicationRoutes"
    assert_includes helper, "Rails.application.routes.url_helpers.extend(ApplicationRoutes)"
    assert_includes helper, "returns(ApplicationRoutes)"
    assert_includes helper, "options: Object).returns(String)"
    assert_includes helper, "block: T.proc.returns(String)"
    refute_includes helper, "T.untyped"
    assert_includes helper, "def pagination(pagy, aria_label:)"
    assert_includes helper_test, 'require "pagy/classes/request"'
    assert_includes helper, "params(pagy: Pagy::Offset, aria_label: String)"
    assert_includes helper, "pagy.data_hash(data_keys: [:series])"
    assert_includes helper, "pagy.page_url(item)"
    assert_includes helper, "ACTION_BUTTON_CLASSES = {"
    assert_includes helper, 'primary: "btn btn-primary"'
    assert_includes helper, 'secondary: "btn"'
    assert_includes helper, 'quiet: "btn btn-outline"'
    assert_includes helper, 'warning: "btn btn-outline btn-warning"'
    assert_includes helper, 'destructive: "btn btn-outline btn-error"'
    assert_includes helper, 'destructive_confirm: "btn btn-error"'
    assert_includes helper, "private_constant :ACTION_BUTTON_CLASSES"
    assert_includes helper, "sig { params(role: Symbol).returns(String) }"
    assert_includes helper, "def action_button_classes(role)"
    assert_includes helper, 'Kernel.raise ArgumentError, "unsupported action button role: #{role.inspect}"'
    assert_includes helper, "def pagination_item_classes(active: false, disabled: false, square: false)"
    assert_includes helper, '"btn join-item"'
    assert_includes helper, '"btn-active": active'
    assert_includes helper, '"btn-disabled": disabled'
    assert_includes helper, '"btn-square": square'
    assert_includes helper, "def with_pagination(aria_label:, summary: nil, &block)"
    assert_includes helper, 'Kernel.raise ArgumentError, "pagination aria label must not be empty"'
    assert_includes helper, 'class: "flex w-max min-w-full items-center justify-end gap-3"'
    assert_includes helper, 'tag.nav(inner, class: "overflow-x-auto", aria: { label: aria_label })'
    assert_includes helper, "with_pagination(aria_label:) { safe_join(items) }"
    {
      primary: "btn btn-primary",
      secondary: "btn",
      quiet: "btn btn-outline",
      warning: "btn btn-outline btn-warning",
      destructive: "btn btn-outline btn-error",
      destructive_confirm: "btn btn-error"
    }.each do |role, classes|
      assert_includes helper_test, %(#{role}: "#{classes}")
    end
    assert_includes helper_test, "assert_equal classes, action_button_classes(role)"
    assert_includes helper_test, "assert_raises(ArgumentError) { action_button_classes(:unknown) }"
    assert_includes helper_test, 'with_pagination(aria_label: "Records pagination", summary: "2 / 8")'
    assert_includes helper_test, "pagination_item_classes(active: true)"
    assert_includes helper_test, "pagination_item_classes(disabled: true, square: true)"
    assert_includes helper_test, 'assert_includes inner.at_css(".join > .btn-disabled")["class"].split, "btn-square"'
    assert_includes helper, 'aria: { hidden: true }'
    assert_equal 1, helper.scan("def application_routes").size
    assert_includes helper, "def with_modal(id:, title:, close_label:, description: nil, actions: nil, dialog_data: {}, &block)"
    assert_includes helper, "dialog_data: T::Hash[Symbol, Object]"
    assert_includes helper, 'tag.dialog(safe_join([box, backdrop]), id:, class: "modal", data: dialog_data, aria:)'
    assert_includes helper, "def with_tab(tabs:, size: nil, &block)"
    assert_includes helper, "request.path.start_with?(path)"
    assert_includes helper, "predicate.call"
    assert_includes helper, "tab_content = capture(&block)"
    assert_includes helper, '"z-10": active'
    assert_includes helper, 'class: class_names("tabs tabs-lift min-w-max"'
    assert_includes helper, 'class: "tab-content sticky left-0 max-w-[100cqw] [contain:inline-size] bg-base-100 border-base-300 p-3"'
    assert_includes @source, '<div class="min-w-0 [container-type:inline-size]">'
    assert_includes helper, 'tag.div(tablist, class: "overflow-x-auto")'
    assert_includes layout, '<html lang="<%= I18n.locale %>"'
    assert_includes layout, 'property="og:site_name" content="<%= application_identity.app_name %>"'
    assert_includes header, "link_to application_identity.app_name, application_routes.root_path"
    assert_includes manifest, "name: identity.app_name"
    assert_includes manifest, "lang: identity.default_locale.to_s"
    refute_match(/I18n\.t\([^)]*locale:\s*:ja/m, @source)
  end

  def test_commits_the_verified_and_formatted_application_as_init
    after_bundle = @source.byteslice(@source.index("after_bundle do")..)
    add = 'run_checked "git add -A"'
    commit = 'run_checked \'git commit -m "init"\''

    assert_equal 1, after_bundle.scan(add).size
    assert_equal 1, after_bundle.scan(commit).size
    assert_operator after_bundle.index('run_checked "bin/rubocop -a"'), :<, after_bundle.index(add)
    assert_operator after_bundle.index(add), :<, after_bundle.index(commit)
  end

  def test_generates_one_shared_mise_local_file_before_feature_configuration
    body = generated_file_source("mise.local.toml").lines.map { |line| line.delete_prefix("    ") }.join
    web_push = source_between("def configure_web_push", "def install_solid_components")
    kamal = source_between("def configure_kamal", "after_bundle do")
    after_bundle = @source.byteslice(@source.index("after_bundle do")..)

    assert_equal <<~TOML, body
      [env]
      # CLOUDFLARE_INITIAL_API_TOKEN = ""
      # OP_SERVICE_ACCOUNT_TOKEN = ""
    TOML
    assert_equal 1, @source.scan('create_file "mise.local.toml"').size
    assert_equal 1, @source.scan('append_to_file ".gitignore", "\\n/mise.local.toml\\n"').size
    assert_includes web_push, 'append_to_file "mise.local.toml", <<~TOML'
    assert_includes web_push, 'VAPID_PUBLIC_KEY = #{key.public_key.inspect}'
    refute_includes web_push, 'create_file "mise.local.toml"'
    refute_includes kamal, 'append_to_file ".gitignore", "\n/mise.local.toml\n"'
    assert_operator after_bundle.index("configure_mise_local"), :<, after_bundle.index("configure_web_push")
  end

  def test_requires_the_shared_modal_helper_for_native_dialog_modals
    helper = generated_file_source("app/helpers/application_helper.rb")
    helper_test = generated_file_source("test/helpers/application_helper_test.rb")
    profile_configuration = source_between("def configure_profile", "def configure_api")
    agents = File.binread(File.expand_path("../../AGENTS.md", __dir__))

    assert_includes helper, 'id.match?(/\A[a-z][a-z0-9_-]*\z/)'
    assert_includes helper, 'tag.h2(title, id: title_id'
    assert_includes helper, 'tag.form(method: "dialog", class: "modal-backdrop")'
    assert_includes helper, 'aria = { labelledby: title_id }'
    assert_includes helper, 'aria[:describedby] = description_id if description.present?'
    assert_includes helper_test, "renders one accessible native dialog from captured body and actions"
    assert_includes helper_test, "assert_equal 1, capture_count"
    assert_includes helper_test, "omits optional modal description and actions"
    assert_includes helper_test, "rejects invalid modal identifiers and empty labels"
    assert_includes profile_configuration, "with_modal("
    assert_includes profile_configuration, 'dialog_data: { image_crop_target: "dialog", action: "close->image-crop#close" }'
    refute_includes profile_configuration, '<dialog'
    refute_includes profile_configuration, 'class="modal-box"'
    refute_includes profile_configuration, 'class="modal-action"'
    refute_includes profile_configuration, 'class="modal-backdrop"'
    assert_includes agents, "ApplicationHelper#with_modal"
  end

  def test_requires_the_shared_tab_helper_for_tabbed_content
    helper = generated_file_source("app/helpers/application_helper.rb")
    helper_test = generated_file_source("test/helpers/application_helper_test.rb")
    account_tabs = generated_file_source("app/views/layouts/account_settings.html.erb")
    job_tabs = generated_file_source("app/views/layouts/mission_control/jobs/_navigation.html.erb")
    agents = File.binread(File.expand_path("../../AGENTS.md", __dir__))

    assert_includes helper, "longest_path_length"
    assert_includes helper, "active tabs must have one longest path"
    assert_includes helper_test, "selects the longest matching path"
    assert_includes helper_test, "uses an explicit lambda instead of path matching"
    assert_includes helper_test, "adds an optional daisyUI size modifier"
    assert_includes helper_test, '.overflow-x-auto > .tabs.tabs-lift.min-w-max'
    assert_includes helper_test, 'assert_includes fragment.at_css(".tab-active")["class"].split, "z-10"'
    assert_includes helper_test, 'assert_includes fragment.at_css("[role=tabpanel]")["class"].split, "sticky"'
    assert_includes helper_test, 'assert_includes fragment.at_css("[role=tabpanel]")["class"].split, "max-w-[100cqw]"'
    assert_includes helper_test, 'assert_includes fragment.at_css("[role=tabpanel]")["class"].split, "[contain:inline-size]"'
    assert_includes account_tabs, "with_tab(tabs:"
    assert_includes job_tabs, "with_tab(tabs:)"
    refute_includes job_tabs, "size:"
    refute_includes account_tabs, "tab-content"
    refute_includes job_tabs, "tab-content"
    assert_includes agents, "ApplicationHelper#with_tab"
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
    assert_includes @source, "@layer utilities {"
    assert_includes @source, ":where(.card-border) {"
    assert_includes @source, "border-color: var(--color-base-300);"
    assert_includes @source,
      ".btn-outline:not(:is(.btn-neutral, .btn-primary, .btn-secondary, .btn-accent, .btn-info, .btn-success, .btn-warning, .btn-error)) {"
    assert_includes @source, "--btn-border: var(--color-base-300);"
    standard_cards = class_attributes(@source).select { |classes| classes.include?("card-border") }
    refute_empty standard_cards
    standard_cards.each do |classes|
      assert_includes classes, "card"
      assert_includes classes, "bg-base-100"
      refute_includes classes, "border-base-300"
      refute_includes classes, "shadow-none"
    end
    assert standard_cards.any? { |classes| classes.include?("border-error") }
    assert_includes @source, 'font-family: -apple-system, system-ui, "Hiragino Kaku Gothic ProN", "Hiragino Sans", Meiryo, sans-serif;'
    assert_includes @source, "font-size: 1rem;"
    assert_includes @source, "line-height: 1.8;"
    assert_includes @source, "font-feature-settings: normal;"
    assert_includes @source, "word-break: break-all;"
    assert_includes @source, "overflow-wrap: break-word;"
    assert_includes @source, "font-family: SFMono-Regular, Consolas, Menlo, monospace;"
  end

  def test_semantic_alerts_use_the_soft_style
    semantic_alerts = class_attributes(@source).select do |classes|
      classes.include?("alert") && (classes & %w[alert-info alert-success alert-warning alert-error]).any?
    end
    notification_popover = generated_file_source("app/javascript/controllers/notification_popover_controller.js")
    web_push = generated_file_source("app/javascript/controllers/push_subscription_controller.js")
    web_push_view = generated_file_source("app/views/web_push_settings/show.html.erb")
    mission_control_flash = generated_file_source("app/views/layouts/mission_control/jobs/_flash.html.erb")
    agents = File.binread(File.expand_path("../../AGENTS.md", __dir__)).force_encoding(Encoding::UTF_8)
    stack = File.binread(File.expand_path("../../docs/stack.md", __dir__)).force_encoding(Encoding::UTF_8)

    refute_empty semantic_alerts
    semantic_alerts.each do |classes|
      assert_includes classes, "alert-soft", "expected #{classes.inspect} to use alert-soft"
      refute_includes classes, "alert-outline", "expected #{classes.inspect} not to use alert-outline"
    end
    assert_includes mission_control_flash,
      'class="alert alert-soft <%= name.to_sym == :notice ? "alert-success" : "alert-error" %>"'
    assert_includes notification_popover, 'classList.add("alert-error", "alert-soft")'
    assert_includes web_push,
      'classList.remove("hidden", "alert-info", "alert-success", "alert-warning", "alert-error")'
    assert_includes web_push, 'state === "success" || state === "on" ? "alert-success"'
    assert_includes web_push, 'state === "denied" || state === "unsupported" ? "alert-warning"'
    assert_includes web_push, 'state === "error" ? "alert-error" : "alert-info"'
    assert_includes web_push, "classList.add(alertClass)"
    refute_includes web_push, '"alert-soft"'
    assert_class_tokens web_push_view, "alert", "alert-info", "alert-soft", "hidden"
    [mission_control_flash, notification_popover, web_push, web_push_view].each do |source|
      refute_includes source, "alert-outline"
    end
    assert_includes agents, "`alert-info`、`alert-success`、`alert-warning`、`alert-error`のいずれかを使用する場合は、常に`alert-soft`"
    assert_includes stack, "`alert-info`、`alert-success`、`alert-warning`、`alert-error`のいずれかを使用する場合に`alert-soft`を必須"
  end

  def test_default_outline_buttons_use_a_quiet_border_without_overriding_semantic_colors
    agents = File.binread(File.expand_path("../../AGENTS.md", __dir__)).force_encoding(Encoding::UTF_8)
    stack = File.binread(File.expand_path("../../docs/stack.md", __dir__)).force_encoding(Encoding::UTF_8)

    assert_includes @source,
      ".btn-outline:not(:is(.btn-neutral, .btn-primary, .btn-secondary, .btn-accent, .btn-info, .btn-success, .btn-warning, .btn-error)) {"
    assert_includes @source, "--btn-border: var(--color-base-300);"
    assert_includes agents, "色modifierを持たない`btn-outline`"
    assert_includes agents, "各semantic colorのborderを維持"
    assert_includes stack, "色modifierを持たない`btn-outline`"
    assert_includes stack, "各semantic colorのborderを維持"
  end

  def test_default_views_use_daisyui_components_and_semantic_colors
    component_expectations = {
      "app/views/layouts/authentication.html.erb" => %w[hero hero-content card card-border bg-base-100 card-body],
      "app/views/layouts/_account_shell.html.erb" => %w[menu menu-title],
      "app/views/layouts/admin.html.erb" => %w[menu menu-title],
      "app/views/shared/_header.html.erb" => %w[navbar dropdown menu btn],
      "app/views/shared/_flash.html.erb" => %w[alert],
      "app/views/shared/_footer.html.erb" => %w[footer footer-vertical footer-title link link-hover],
      "app/views/home/index.html.erb" => %w[hero hero-content badge btn card card-border bg-base-100 card-body card-title],
      "app/views/accounts/show.html.erb" => %w[card card-border bg-base-100 card-body card-title btn],
      "app/views/account/siwe_identities/index.html.erb" => %w[list list-row badge btn alert],
      "app/views/account/siwe_identities/new.html.erb" => %w[btn alert],
      "app/views/account/siwe_identities/show.html.erb" => %w[btn alert],
      "app/views/account/siwe_identities/edit.html.erb" => %w[fieldset fieldset-legend input btn alert],
      "app/views/web_push_settings/show.html.erb" => %w[card card-border bg-base-100 card-body card-title card-actions toggle btn alert],
      "app/views/notifications/index.html.erb" => %w[card card-border bg-base-100 card-body list],
      "app/views/notifications/_popover.html.erb" => %w[list btn],
      "app/views/admin/notifications/index.html.erb" => %w[card card-border bg-base-100 card-body table badge btn],
      "app/views/admin/notifications/_form.html.erb" => %w[alert fieldset fieldset-legend label select input checkbox btn],
      "app/views/admin/overview/show.html.erb" => %w[card card-border bg-base-100 card-body stats stat stat-title stat-value],
      "app/views/admin/users/index.html.erb" => %w[card card-border bg-base-100 card-body table avatar link badge],
      "app/views/admin/users/show.html.erb" => %w[card card-border bg-base-100 card-body card-title list list-row avatar badge btn],
      "app/views/admin/users/edit.html.erb" => %w[card card-border bg-base-100 card-body],
      "app/views/pages/_page.html.erb" => %w[card card-border bg-base-100 card-body],
      "app/views/faqs/index.html.erb" => %w[collapse collapse-arrow collapse-title collapse-content alert],
      "app/views/admin/pages/index.html.erb" => %w[card card-border bg-base-100 card-body table btn],
      "app/views/admin/pages/edit.html.erb" => %w[card card-border bg-base-100 card-body btn],
      "app/views/admin/faqs/index.html.erb" => %w[card card-border bg-base-100 card-body table badge btn],
      "app/views/admin/faqs/_form.html.erb" => %w[alert fieldset fieldset-legend input checkbox btn],
      "app/views/admin/footer_settings/edit.html.erb" => %w[card card-border bg-base-100 card-body alert fieldset fieldset-legend input btn],
      "app/views/api_credentials/_form.html.erb" => %w[alert fieldset fieldset-legend input btn],
      "app/views/api_credentials/index.html.erb" => %w[card card-border bg-base-100 card-body table join join-item input alert btn],
      "app/views/api_credentials/show.html.erb" => %w[alert fieldset fieldset-legend join join-item input card card-border bg-base-100 card-body card-title btn],
      "app/views/api_credentials/new.html.erb" => %w[card card-border bg-base-100 card-body],
      "app/views/api_credentials/edit.html.erb" => %w[card card-border bg-base-100 card-body],
      "app/views/profiles/_avatar_delete.html.erb" => %w[card card-border bg-base-100 card-body card-title card-actions btn],
      "app/views/users/passkey_sessions/new.html.erb" => %w[checkbox btn alert],
      "app/views/users/passkey_registrations/new.html.erb" => %w[btn alert],
      "app/views/account/passkeys/index.html.erb" => %w[list list-row btn badge],
      "app/views/account/passkeys/new.html.erb" => %w[btn alert],
      "app/views/account/passkeys/edit.html.erb" => %w[fieldset fieldset-legend input btn],
      "app/views/account/passkeys/show.html.erb" => %w[btn alert],
      "app/views/accounts/delete.html.erb" => %w[card card-body btn alert]
    }

    view_sources = component_expectations.to_h { |path, _components| [path, generated_file_source(path)] }
    component_expectations.each do |path, components|
      components.each do |component|
        source = view_sources.fetch(path)
        uses_component = class_attributes(source).any? { |classes| classes.include?(component) }
        uses_component ||= component == "btn" && source.include?("action_button_classes(")
        assert uses_component,
          "#{path}: #{component}"
      end
    end

    views = ([generated_file_source("app/views/layouts/application.html.erb")] + view_sources.values).join("\n")
    devise_views = source_between("def configure_devise_views", "def configure_in_app_notifications")
    account_settings_layout = generated_file_source("app/views/layouts/account_settings.html.erb")
    assert_includes account_settings_layout, "with_tab(tabs:"
    assert_includes @source, "path: account_passkeys_path"
    assert_includes @source, "path: account_siwe_identities_path"
    refute_includes account_settings_layout, "tab-content"
    profile_configuration = source_between("def configure_profile", "def configure_api")
    %w[alert fieldset fieldset-legend input file-input card card-body list list-row avatar btn].each do |component|
      uses_component = class_attributes(profile_configuration).any? { |classes| classes.include?(component) }
      uses_component ||= component == "btn" && profile_configuration.include?("action_button_classes(")
      assert uses_component, "profile: #{component}"
    end
    avatar_helper = generated_file_source("app/helpers/avatar_helper.rb")
    views += profile_configuration.sub(avatar_helper, "")
    %w[navbar menu dropdown avatar hero card fieldset input file-input checkbox btn alert footer badge list table collapse].each do |component|
      assert class_attributes(views).any? { |classes| classes.include?(component) }, component
    end
    assert_equal 2, devise_views.scan('<div class="divider"><%= t("authentication.or") %></div>').size
    %w[bg-base-100 bg-base-200 border-base-300 text-base-content].each { |utility| assert_includes views, utility }
    assert_includes views, "action_button_classes(:primary)"
    refute_match(/(?:bg|text|border)-(?:blue|gray|slate|red|green|yellow)-\d+/, views)
    refute_includes views, "dark:"
    refute_match(/#[0-9a-f]{3,8}(?![0-9a-z])/i, views)
  end

  def test_generator_overrides_paginate_scaffolds_and_preserve_rails_view_contracts
    paths = %w[
      lib/templates/rails/scaffold_controller/controller.rb.tt
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
    new_view = templates.fetch("lib/templates/erb/scaffold/new.html.erb.tt")
    edit = templates.fetch("lib/templates/erb/scaffold/edit.html.erb.tt")
    partial = templates.fetch("lib/templates/erb/scaffold/partial.html.erb.tt")
    scaffold_controller = templates.fetch("lib/templates/rails/scaffold_controller/controller.rb.tt")
    controller_view = templates.fetch("lib/templates/erb/controller/view.html.erb.tt")

    assert_equal paths.sort, @source.scan(/create_file "(lib\/templates\/[^"]+)"/).flatten.sort
    assert_includes @source, "configure_generator_templates\n  configure_rubocop"
    assert_includes scaffold_controller, "<% module_namespacing do -%>"
    assert_includes scaffold_controller, "before_action :set_<%= singular_table_name %>"
    assert_includes scaffold_controller, '@pagy, @<%= plural_table_name %> = pagy(:offset, <%= orm_class.all(class_name) %>.order(:id), limit: 25)'
    assert_includes scaffold_controller, '<%= orm_class.build(class_name, "#{singular_table_name}_params") %>'
    assert_includes scaffold_controller, '<%= orm_class.find(class_name, "params.expect(:id)") %>'
    assert_includes form, "<%%= form_with(model: <%= model_resource_name %>"
    assert_includes form, "attributes.each do |attribute|"
    assert_includes form, "attribute.password_digest?"
    assert_includes form, "attribute.attachments?"
    assert_includes form, 'when :textarea, :rich_textarea then "textarea w-full"'
    assert_includes form, 'when :file_field then "file-input w-full"'
    assert_includes form, 'else "input w-full"'
    assert_includes form, 'class: "checkbox"'
    assert_class_tokens(form, "alert", "alert-error", "alert-soft")
    assert_class_tokens(form, "fieldset")
    assert_class_tokens(form, "fieldset-legend")
    assert_includes form, '<%%= form.submit class: action_button_classes(:primary) %>'
    assert_includes form, '<div class="card-actions flex-wrap justify-end">'

    assert_class_tokens(index, "table", "table-sm", "table-pin-rows", "min-w-max")
    assert_class_tokens(index, "overflow-x-auto")
    assert_includes index, '<header class="flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">'
    assert_includes index, 'class: action_button_classes(:primary)'
    assert_includes index, 'class: action_button_classes(:secondary)'
    assert_includes index, '<div class="flex flex-wrap justify-end gap-2">'
    index_header = index[/<header .*?<\/header>/m] || flunk("scaffold index header not found")
    assert_includes index_header, '<%%= content_for(:page_title) %>'
    assert_includes index_header, 'class: action_button_classes(:primary)'
    assert_includes index, "<%%= dom_id <%= singular_table_name %> %>"
    assert_includes index, "attribute.attachment?"
    assert_includes index, "attribute.attachments?"
    assert_includes index, "model_resource_name(singular_table_name)"
    assert_includes index, '<%%= pagination(@pagy, aria_label: "<%= human_name.pluralize %> pagination") %>'
    refute_includes index, "notice"

    assert_class_tokens(show, "card", "card-border", "bg-base-100")
    assert_includes show, '<div class="card-actions flex-wrap justify-end">'
    assert_includes show, 'method: :delete, class: action_button_classes(:destructive)'
    assert_operator show.index('Back to <%= human_name.pluralize.downcase %>'), :<,
      show.index('Edit this <%= human_name.downcase %>')
    assert_operator show.index('Edit this <%= human_name.downcase %>'), :<,
      show.index('Destroy this <%= human_name.downcase %>')
    assert_includes new_view, '<header class="flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">'
    assert_includes new_view, 'class: action_button_classes(:quiet)'
    new_header = new_view[/<header .*?<\/header>/m] || flunk("scaffold new header not found")
    assert_includes new_header, '<%%= content_for(:page_title) %>'
    assert_includes new_header, 'class: action_button_classes(:quiet)'
    assert_includes edit, '<header class="flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">'
    assert_includes edit, '<div class="flex flex-col gap-3 sm:flex-row">'
    edit_header = edit[/<header .*?<\/header>/m] || flunk("scaffold edit header not found")
    assert_includes edit_header, '<%%= content_for(:page_title) %>'
    assert_includes edit_header, '<div class="flex flex-col gap-3 sm:flex-row">'
    assert_includes edit_header, 'class: action_button_classes(:quiet)'
    assert_includes edit_header, 'class: action_button_classes(:secondary)'
    assert_operator edit.index('Back to <%= human_name.pluralize.downcase %>'), :<,
      edit.index('Show this <%= human_name.downcase %>')
    assert_includes edit, 'class: action_button_classes(:quiet)'
    assert_includes edit, 'class: action_button_classes(:secondary)'
    [index, new_view, edit].each { |view| refute_includes view, "content_for :page_actions" }
    assert_class_tokens(partial, "list")
    assert_class_tokens(partial, "list-row")
    assert_includes partial, "<%%= dom_id <%= singular_name %> %>"
    assert_class_tokens(controller_view, "card", "card-border", "bg-base-100")
    assert_includes controller_view, "<%= class_name %>#<%= @action %>"
    assert_includes controller_view, "Find me in <%= @path %>"

    refute_match(/style\s*=/, combined)
    refute_match(/(?:bg|text|border)-(?:blue|gray|slate|red|green|yellow)-\d+/, combined)
    refute_includes combined, "dark:"
    refute_match(/#[0-9a-f]{3,8}(?![0-9a-z])/i, combined)
    refute_match(/\bmin-h-\d+/, combined)
  end

  def test_content_actions_use_semantic_roles_wrapping_action_groups_and_stable_dom_order
    passkey_new = generated_file_source("app/views/account/passkeys/new.html.erb")
    admin_users = generated_file_source("app/views/admin/users/index.html.erb")
    admin_user_show = generated_file_source("app/views/admin/users/show.html.erb")
    admin_pages_index = generated_file_source("app/views/admin/pages/index.html.erb")
    admin_page_edit = generated_file_source("app/views/admin/pages/edit.html.erb")
    admin_faqs = generated_file_source("app/views/admin/faqs/index.html.erb")
    admin_faq_form = generated_file_source("app/views/admin/faqs/_form.html.erb")
    footer_setting = generated_file_source("app/views/admin/footer_settings/edit.html.erb")
    profile_form = generated_file_source("app/views/profiles/_form.html.erb")
    api_index = generated_file_source("app/views/api_credentials/index.html.erb")
    api_form = generated_file_source("app/views/api_credentials/_form.html.erb")
    api_show = generated_file_source("app/views/api_credentials/show.html.erb")
    notifications = generated_file_source("app/views/admin/notifications/index.html.erb")
    notification_form = generated_file_source("app/views/admin/notifications/_form.html.erb")
    notification_show = generated_file_source("app/views/admin/notifications/show.html.erb")
    notification_item = generated_file_source("app/views/notifications/_notification.html.erb")
    notification_popover = generated_file_source("app/views/notifications/_popover.html.erb")
    notification_history = generated_file_source("app/views/notifications/index.html.erb")
    notification_open = generated_file_source("app/views/notifications/open.turbo_stream.erb")
    account_delete = generated_file_source("app/views/accounts/delete.html.erb")

    assert_includes admin_user_show, '<div class="card-actions flex-wrap justify-end">'
    assert_includes admin_user_show, 'class_names(action_button_classes(:secondary), "btn-disabled")'
    assert_includes admin_user_show, "class: action_button_classes(:destructive)"
    assert_includes admin_user_show, "class: action_button_classes(:warning)"
    assert_includes admin_user_show, "class: action_button_classes(:secondary)"

    assert_class_tokens(admin_users, "table", "min-w-max")
    refute_includes admin_users, "admin_user_roles_path"
    refute_includes admin_users, "admin_user_role_path"
    [admin_pages_index, admin_faqs, api_index, notifications].each do |view|
      assert_class_tokens(view, "table", "min-w-max")
      assert_includes view, '<div class="flex flex-wrap justify-end gap-2">'
    end
    assert_includes admin_pages_index, "class: action_button_classes(:secondary)"
    assert_includes admin_faqs, "class: action_button_classes(:primary)"
    assert_includes admin_faqs, "class: action_button_classes(:secondary)"
    assert_includes admin_faqs, "class: action_button_classes(:destructive)"
    assert_includes footer_setting, "class: action_button_classes(:primary)"
    assert_includes api_index, "class: action_button_classes(:primary)"
    assert_includes api_index, "class: action_button_classes(:secondary)"
    assert_includes notifications, "class: action_button_classes(:primary)"
    assert_includes notifications, "class: action_button_classes(:secondary)"
    assert_includes notifications, "class: action_button_classes(:destructive)"
    refute_includes notifications, "btn-sm"
    refute_includes notifications, "text-error"
    assert_includes notification_item, "local_assigns.fetch(:compact)"
    refute_includes notification_item, "local_assigns.fetch(:compact, false)"
    assert_includes notification_item,
      'class: (compact ? "btn btn-outline btn-sm" : action_button_classes(:quiet))'
    assert_includes notification_popover, 'frame_prefix: "popover_personal_notification", compact: true'
    assert_includes notification_history, 'frame_prefix: "history_personal_notification", compact: false'
    assert_includes notification_open, "locals: { delivery: @delivery, frame_prefix:, compact: }"

    [passkey_new, admin_page_edit, admin_faq_form, footer_setting, profile_form, api_form,
     notification_form, notification_show, account_delete].each do |view|
      assert_includes view, '<div class="card-actions flex-wrap justify-end">'
    end
    assert_includes api_show, '<div class="card-actions mt-4 flex-wrap justify-end">'

    assert_source_order(admin_page_edit,
      'class: action_button_classes(:quiet)',
      'class: action_button_classes(:primary)')
    assert_source_order(admin_faq_form,
      'class: action_button_classes(:quiet)',
      'class: action_button_classes(:primary)')
    assert_source_order(profile_form,
      'class: action_button_classes(:quiet)',
      'class: action_button_classes(:primary)')
    assert_source_order(api_form,
      'class: action_button_classes(:quiet)',
      'class: action_button_classes(:primary)')
    assert_source_order(api_show,
      'class: action_button_classes(:quiet)',
      'class: action_button_classes(:secondary)',
      'class: action_button_classes(:warning)',
      'class: action_button_classes(:destructive)')
    assert_source_order(notification_form,
      'class: action_button_classes(:quiet)',
      'class: action_button_classes(:primary)')
    assert_source_order(notification_show,
      'class: action_button_classes(:quiet)',
      'class: action_button_classes(:secondary)')
    assert_source_order(passkey_new,
      'class: action_button_classes(:quiet)',
      'class="<%= action_button_classes(:primary) %>"')
    assert_source_order(account_delete,
      'class: action_button_classes(:quiet)',
      'action_button_classes(:destructive_confirm)')
  end

  def test_authentication_fixtures_use_unique_webauthn_identifiers_without_passwords
    users = generated_file_source("test/fixtures/users.yml")
    passkeys = generated_file_source("test/fixtures/passkey_credentials.yml")

    assert_includes users, 'webauthn_id: "dGVzdC11c2VyLW9uZQ"'
    assert_includes users, 'webauthn_id: "dGVzdC11c2VyLXR3bw"'
    assert_includes passkeys, "backup_eligible: true"
    assert_includes passkeys, "backup_state: false"
    refute_includes users, "encrypted_password"
    refute_includes users, "login_id"
  end

  def test_generates_the_pwa_manifest_routes_registration_and_push_handlers
    pwa = source_between("def configure_pwa", "def configure_web_push")
    worker = generated_file_source("app/views/pwa/service-worker.js")
    controller = generated_file_source("app/javascript/controllers/pwa_controller.js")
    layout = generated_file_source("app/views/layouts/application.html.erb")
    defaults = source_between("def configure_default_views", "def configure_web_push")

    assert_includes pwa, 'route \'get "manifest" => "rails/pwa#manifest", as: :pwa_manifest\''
    assert_includes pwa, 'route \'get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker\''
    assert_includes pwa, 'display: "standalone"'
    assert_includes pwa, 'theme_color: "#3ea8ff"'
    assert_includes pwa, 'src: "/icon.png"'
    assert_includes pwa, 'theme_color: "#3ea8ff"'
    assert_includes defaults, '<meta name="theme-color" content="#3ea8ff">'
    assert_includes defaults, 'tag.link rel: "manifest", href: application_routes.pwa_manifest_path(format: :json)'
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
    payload = generated_file_source("app/services/push_notification_payload.rb")
    controller = generated_file_source("app/controllers/push_subscriptions_controller.rb")

    assert_equal 'gem "web-push", "~> 3.1" if VALUES.fetch("web_push") == "use"', @source.lines.grep(/gem "web-push"/).first.strip
    assert_includes web_push, 'VAPID_SUBJECT = "https://localhost"'
    assert_includes web_push, 'append_to_file "mise.local.toml", <<~TOML'
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
    assert_includes notifier, "PushNotificationJob.perform_later("
    assert_includes notifier, "title,\n"
    assert_includes payload, "class PushNotificationPayload < T::Struct"
    assert_includes payload, "const :path, String"
    assert_includes payload, "sig { params(_state: T.nilable(JSON::State)).returns(String) }"
    assert_includes payload, "def to_json(_state = nil)"
    assert_includes controller, 'rate_limit to: 5, within: 1.minute, only: :test'
    assert_includes controller, 'head :accepted'
    assert_includes controller, 'status: :service_unavailable'
    assert_includes web_push, 'resource :push_subscription, only: %i[create destroy]'
    assert_includes web_push, 'resource :web_push_settings, only: :show, path: "web-push"'
    assert_includes controller, '"web-push-test",'
    assert_includes web_push, 'params.expect(push_subscription: %i[browser_id endpoint p256dh auth])'
    assert_includes web_push, "PushSubscriptionsController.cache_store.clear"
    refute_includes web_push, "Rails.cache.clear"
  end

  def test_solid_queue_uses_the_test_adapter_only_in_test_environment
    solid = source_between("def install_solid_components", "def install_job_operations")

    assert_includes @source, 'gem "solid_queue", "1.6.0" if VALUES.fetch("active_job") == "solid_queue"'
    assert_includes solid, 'environment "config.active_job.queue_adapter = :solid_queue"'
    assert_includes solid, 'environment "config.solid_queue.connects_to = { database: { writing: :queue } }", env: "development"'
    assert_includes solid, 'environment "config.active_job.queue_adapter = :test", env: "test"'
    assert_includes solid, 'plugin :solid_queue if ENV.fetch(\\"RAILS_ENV\\", \\"development\\") == \\"development\\"'
  end

  def test_solid_queue_configures_a_dedicated_development_database
    database = source_between("def configure_database", "def kamal_restore_cli_body")

    assert_includes database, 'if VALUES.fetch("active_job") == "solid_queue"'
    assert_includes database, 'development_databases["queue"] = {'
    assert_includes database, '"database" => "storage/development_queue.sqlite3"'
    assert_includes database, '"migrations_paths" => "db/queue_migrate"'
    assert_includes database, '"development" => development_databases'
  end

  def test_installs_mission_control_jobs_at_the_admin_authorization_boundary
    job_operations = source_between("def install_job_operations", "def install_maintenance_tasks")
    initializer = generated_file_source("config/initializers/mission_control_jobs.rb")
    controller = generated_file_source("app/controllers/admin/job_operations_controller.rb")
    helper = generated_file_source("app/helpers/admin/job_operations_helper.rb")
    policy = generated_file_source("app/policies/job_operation_policy.rb")
    layout = generated_file_source("app/views/layouts/mission_control/jobs/application.html.erb")
    navigation = generated_file_source("app/views/layouts/mission_control/jobs/_navigation.html.erb")
    application_selection = generated_file_source("app/views/layouts/mission_control/jobs/_application_selection.html.erb")
    jobs_index = generated_file_source("app/views/mission_control/jobs/jobs/index.html.erb")
    job_show = generated_file_source("app/views/mission_control/jobs/jobs/show.html.erb")
    queues_index = generated_file_source("app/views/mission_control/jobs/queues/index.html.erb")
    queue_show = generated_file_source("app/views/mission_control/jobs/queues/show.html.erb")
    recurring_tasks_index = generated_file_source("app/views/mission_control/jobs/recurring_tasks/index.html.erb")
    recurring_task_show = generated_file_source("app/views/mission_control/jobs/recurring_tasks/show.html.erb")
    workers_index = generated_file_source("app/views/mission_control/jobs/workers/index.html.erb")
    pagination = generated_file_source("app/views/mission_control/jobs/shared/_pagination_toolbar.html.erb")
    job_operation_views = %w[
      app/views/layouts/mission_control/jobs/application.html.erb
      app/views/layouts/mission_control/jobs/_application_selection.html.erb
      app/views/layouts/mission_control/jobs/_flash.html.erb
      app/views/layouts/mission_control/jobs/_navigation.html.erb
      app/views/mission_control/jobs/shared/_pagination_toolbar.html.erb
      app/views/mission_control/jobs/queues/index.html.erb
      app/views/mission_control/jobs/queues/show.html.erb
      app/views/mission_control/jobs/jobs/index.html.erb
      app/views/mission_control/jobs/jobs/show.html.erb
      app/views/mission_control/jobs/recurring_tasks/index.html.erb
      app/views/mission_control/jobs/recurring_tasks/show.html.erb
      app/views/mission_control/jobs/workers/index.html.erb
      app/views/mission_control/jobs/workers/show.html.erb
    ].map { |path| generated_file_source(path) }.join("\n")
    controller_test = generated_file_source("test/controllers/admin/job_operations_controller_test.rb")
    helper_test = generated_file_source("test/helpers/admin/job_operations_helper_test.rb")
    cleanup_test = generated_file_source("test/models/solid_queue_cleanup_test.rb")
    application_layout = generated_file_source("app/views/layouts/application.html.erb")
    after_bundle = @source.byteslice(@source.index("after_bundle do")..)

    assert_includes @source, 'gem "mission_control-jobs", "1.1.0" if VALUES.fetch("job_operations") == "enable"'
    assert_includes job_operations, 'environment "config.mission_control.jobs.adapters = [:solid_queue]"'
    assert_includes job_operations, 'environment "config.solid_queue.connects_to = { database: { writing: :queue } }", env: "test"'
    assert_includes job_operations, 'mount MissionControl::Jobs::Engine, at: "/admin/jobs", as: :admin_jobs'
    refute_includes job_operations, 'at: "/jobs"'
    assert_equal 1, @source.scan('mount MissionControl::Jobs::Engine').size
    assert_includes initializer, 'MissionControl::Jobs.base_controller_class = "Admin::JobOperationsController"'
    assert_includes initializer, "MissionControl::Jobs.http_basic_auth_enabled = false"
    refute_includes initializer, "username"
    refute_includes initializer, "password"
    assert_includes controller, "class JobOperationsController < BaseController"
    refute_includes controller, "APPLICATION_ROUTES"
    refute_includes controller, "include Rails.application.routes.url_helpers"
    refute_includes controller, "helper Rails.application.routes.url_helpers"
    assert_includes controller, "helper Admin::JobOperationsHelper"
    assert_includes controller, "authorize! :job_operation, to: :manage?"
    refute_includes controller, "has_role?"
    assert_includes policy, "def manage?"
    assert_includes policy, "admin?"
    assert_includes helper, "def with_host_application_locale(&block)"
    assert_includes helper, "engine_config = I18n.config"
    assert_includes helper, "I18n.config = I18n::Config.new"
    assert_includes helper, "with_host_i18n { capture(&render_block) }"
    assert_includes helper, "def translate(key = nil, **options)"
    assert_includes helper, "with_host_i18n { super(key, **options) }"
    assert_includes helper, "def t(key = nil, **options)"
    assert_includes helper, "I18n.with_locale(application_identity.default_locale, &render_block)"
    assert_includes helper, "I18n.config = engine_config"
    assert_includes helper, "NAVIGATION_SECTIONS.fetch(section.to_sym)"
    assert_includes helper, "JOB_STATUS_KEYS.fetch(status.to_s)"
    assert_includes helper, "JOB_ATTRIBUTE_KEYS.fetch(status.to_s)"
    assert_includes helper, "EVENT_KEYS.fetch(event)"
    assert_includes helper_test, "include Admin::JobOperationsHelper"
    refute_includes job_operations, "skip_around_action"
    refute_includes job_operations, "prepend"
    assert_includes layout, "<%= with_host_application_locale do %>"
    assert_includes layout, 'render template: "layouts/admin"'
    refute_includes layout, "with_menu_subnavigation"
    assert_includes layout, '<%= render layout: "layouts/mission_control/jobs/navigation" do %>'
    refute_includes layout, "content_for :page_title"
    refute_includes layout, "content_for :title"
    assert_operator layout.index("admin_content"), :<, layout.index('render layout: "layouts/mission_control/jobs/navigation"')
    assert_equal 1, layout.scan('render layout: "layouts/mission_control/jobs/navigation"').size
    refute_includes navigation, '<nav aria-label="Job operations sections" class="overflow-x-auto">'
    assert_includes navigation, "job_operation_navigation_label(key)"
    assert_includes navigation, "t('job_operations.aria.sections')"
    assert_includes navigation, "with_tab(tabs:)"
    refute_includes navigation, "size:"
    assert_includes navigation, "is_active: -> { key == current_section }"
    assert_includes navigation, '<%= yield %>'
    refute_includes navigation, "tab-content"
    assert_includes generated_file_source("app/helpers/application_helper.rb"), "min-w-max"
    assert_includes generated_file_source("app/helpers/application_helper.rb"), "sticky"
    refute_includes navigation, "max-w-[100cqw]"
    refute_includes navigation, "grid-cols-[repeat(8,max-content)]"
    refute_includes navigation, "grid-rows-[auto_auto]"
    refute_includes navigation, "h-auto"
    refute_includes navigation, "row-start-2"
    refute_includes navigation, "col-[1/-1]"
    assert_includes application_selection, 'class="flex flex-wrap items-center justify-end gap-3"'
    assert_includes application_selection, '<% if @application.servers.many? || selectable_applications.any? %>'
    assert_includes application_selection, 'class="tabs tabs-lift"'
    assert_includes application_selection, 'class="btn"'
    refute_includes application_selection, "tabs-sm"
    refute_includes application_selection, "btn-sm"
    refute_includes application_selection, "card-body"
    refute_includes application_selection, "Back to main app"
    refute_includes application_selection, "main_app.root_path"
    assert_includes jobs_index, 'class="card card-border bg-base-100"'
    assert_includes jobs_index, 'class="card-body"'
    assert_includes jobs_index, 'class="overflow-x-auto"'
    assert_includes jobs_index, "<% jobs_title = job_operation_jobs_title(jobs_status) %>"
    assert_includes jobs_index, "<% content_for :page_title, jobs_title %>"
    assert_includes jobs_index, 'class="table min-w-max"'
    assert_includes jobs_index, '<section class="card card-border bg-base-100" aria-label="<%= t(\'job_operations.aria.filters\') %>">'
    assert_includes jobs_index, '<div class="card-body">'
    refute_includes jobs_index, "content_for :page_actions_secondary"
    assert_includes jobs_index, '<div class="card-actions flex-wrap justify-end md:col-span-2">'
    assert_includes jobs_index, "class: action_button_classes(:secondary)"
    assert_includes jobs_index, "class: action_button_classes(:warning)"
    assert_includes jobs_index, "class: action_button_classes(:destructive)"
    assert_match(/button_to t\(active_filters\?.*?action_button_classes\(:warning\).*?button_to t\(active_filters\?.*?action_button_classes\(:destructive\)/m,
      jobs_index)
    assert_match(/button_to t\("job_operations\.actions\.run_now"\).*?action_button_classes\(:warning\).*?button_to t\("job_operations\.actions\.discard"\).*?action_button_classes\(:destructive\)/m,
      jobs_index)
    refute_includes jobs_index, "btn-sm"
    refute_includes jobs_index, '<section class="card card-border border-base-300 bg-base-100" aria-label="Job filters">'
    assert_includes job_show, 'class="mockup-code overflow-x-auto"'
    assert_includes job_show, '<% content_for :page_title, job_title(@job) %>'
    assert_includes job_show, 'class="collapse collapse-arrow card card-border bg-base-100"'
    assert_includes job_show, 'class="tabs tabs-box justify-end"'
    assert_includes job_show, '<div class="flex flex-wrap justify-end gap-2">'
    assert_includes job_show, "class: action_button_classes(:warning)"
    assert_includes job_show, "class: action_button_classes(:destructive)"
    assert_match(/button_to t\("job_operations\.actions\.retry"\).*?action_button_classes\(:warning\).*?button_to t\("job_operations\.actions\.discard"\).*?action_button_classes\(:destructive\)/m,
      job_show)
    assert_match(/button_to t\("job_operations\.actions\.run_now"\).*?action_button_classes\(:warning\).*?button_to t\("job_operations\.actions\.discard"\).*?action_button_classes\(:destructive\)/m,
      job_show)
    refute_includes job_show, "tabs-sm"
    assert_includes queues_index, '<div class="flex flex-wrap justify-end gap-2">'
    assert_includes queues_index, "class: action_button_classes(:warning)"
    assert_includes queues_index, "class: action_button_classes(:secondary)"
    refute_includes queues_index, "btn-sm"
    assert_includes queues_index, '<% content_for :page_title, t("job_operations.titles.queues") %>'
    [queue_show, recurring_tasks_index, recurring_task_show].each do |view|
      assert_includes view, '<div class="flex flex-wrap justify-end gap-2">'
    end
    assert_includes queue_show, "class: action_button_classes(:warning)"
    assert_includes queue_show, "class: action_button_classes(:secondary)"
    assert_includes recurring_tasks_index, "class: action_button_classes(:warning)"
    assert_includes recurring_task_show, "class: action_button_classes(:warning)"
    assert_includes pagination,
      '<%= with_pagination(aria_label:, summary: "#{page.index} / #{page.pages_count || "..."}") do %>'
    assert_equal 2, pagination.scan("pagination_item_classes(disabled: true)").size
    assert_equal 2, pagination.scan("class: pagination_item_classes %>").size
    refute_includes pagination, 'class="join"'
    refute_includes pagination, 'class: "btn join-item"'
    refute_includes pagination, "btn-sm"
    assert_includes queue_show, 'aria_label: t("job_operations.aria.queue_jobs_pagination")'
    assert_includes jobs_index, 'aria_label: t("job_operations.aria.status_jobs_pagination", status: jobs_title)'
    assert_includes recurring_task_show, 'aria_label: t("job_operations.aria.recurring_task_jobs_pagination")'
    assert_includes workers_index, 'aria_label: t("job_operations.aria.workers_pagination")'
    assert_includes helper, '"failed" => "badge-error"'
    assert_includes helper, '"finished" => "badge-success"'
    assert_includes job_operations, '"queues" => "キュー"'.b
    assert_includes job_operations, '"queues" => "Queues"'
    assert_includes job_operations, '"retry" => "再試行"'.b
    assert_includes job_operations, '"retry" => "Retry"'
    refute_includes layout, "bulma.min.css"
    refute_includes job_operations, 'mission_control/jobs/bulma.min.css'
    refute_includes job_operations, "mission_control_jobs_scoped"
    refute_includes job_operations, "@scope"
    %w[tabs-xs tabs-sm btn-xs btn-sm].each do |small_modifier|
      refute_includes job_operation_views, small_modifier
    end
    assert_includes job_operation_views, "card card-border bg-base-100"
    job_operation_views.scan(/<table class="([^"]*)">/).flatten.each do |table_class|
      assert_includes table_class.split, "min-w-max", table_class
    end
    job_operation_views.scan(/class(?::|=)\s*["']([^"']*\bbtn\b[^"']*)["']/).flatten.each do |button_class|
      assert_includes button_class.split, "btn", button_class
    end
    %w[is-boxed is-active navbar-item navbar-menu message-body is-hoverable is-fullwidth].each do |bulma_class|
      refute_includes [layout, navigation, application_selection, jobs_index, job_show, queues_index, pagination].join, bulma_class
    end
    assert_includes layout, "MissionControl::Jobs.importmap"
    assert_includes application_layout, "content_for?(:javascript_importmap)"
    assert_includes controller_test, "routes every engine action through the authorized base controller"
    assert_includes controller_test, "controller._process_action_callbacks.map(&:filter)"
    assert_includes controller_test, "keeps the matching section active on queue, job, and worker details"
    assert_includes controller_test, "assert_active_job_section"
    assert_includes controller_test, "allows admins to retry a failed Solid Queue job"
    assert_includes controller_test, "application_job_retry_path"
    assert_includes helper_test, "renders with the host locale and restores the engine config"
    assert_includes helper_test, "restores the engine config when rendering raises"
    assert_includes helper_test, "assert_same engine_config, I18n.config"
    assert_includes controller_test, "assert SolidQueue::ReadyExecution.exists?"
    assert_includes cleanup_test, "SolidQueue::Job.clear_finished_in_batches"
    assert_includes cleanup_test, 'assert_equal "every hour at minute 12"'
    assert_includes cleanup_test, "assert SolidQueue::Job.exists?(failed.id)"
    assert_includes @source, 'test_databases["queue"] = { "database" => "storage/test_queue.sqlite3", "migrations_paths" => "db/queue_migrate" }'
    assert_operator after_bundle.index("install_solid_components"), :<,
      after_bundle.index('install_job_operations if VALUES.fetch("job_operations") == "enable"')
    assert_operator after_bundle.index('install_job_operations if VALUES.fetch("job_operations") == "enable"'), :<,
      after_bundle.index('install_maintenance_tasks if VALUES.fetch("maintenance_tasks") == "enable"')
  end

  def test_installs_maintenance_tasks_through_the_official_generator_and_admin_boundary
    maintenance = source_between("def install_maintenance_tasks", "def configure_common_files")
    route = source_between("def configure_maintenance_tasks_route", "def run_checked")
    controller = generated_file_source("app/controllers/admin/maintenance_tasks_controller.rb")
    policy = generated_file_source("app/policies/maintenance_task_policy.rb")
    initializer = generated_file_source("config/initializers/maintenance_tasks.rb")
    layout = generated_file_source("app/views/layouts/maintenance_tasks/admin.html.erb")
    helper = generated_file_source("app/helpers/admin/maintenance_tasks_helper.rb")
    tasks_index = generated_file_source("app/views/maintenance_tasks/tasks/index.html.erb")
    task = generated_file_source("app/views/maintenance_tasks/tasks/_task.html.erb")
    task_show = generated_file_source("app/views/maintenance_tasks/tasks/show.html.erb")
    run = generated_file_source("app/views/maintenance_tasks/runs/_run.html.erb")
    error = generated_file_source("app/views/maintenance_tasks/runs/info/_errored.html.erb")
    refresh = generated_file_source("app/javascript/controllers/maintenance_tasks_refresh_controller.js")
    controller_test = generated_file_source("test/controllers/admin/maintenance_tasks_controller_test.rb")
    countdown_task = generated_file_source("app/tasks/maintenance/countdown_task.rb")
    countdown_test = generated_file_source("test/tasks/maintenance/countdown_task_test.rb")
    after_bundle = @source.byteslice(@source.index("after_bundle do")..)

    assert_includes @source, 'gem "maintenance_tasks", "2.17.0" if VALUES.fetch("maintenance_tasks") == "enable"'
    assert_includes maintenance, 'generate "maintenance_tasks:install"'
    assert_includes maintenance, 'generate "maintenance_tasks:task", "countdown"'
    assert_includes route, "Prism.parse(source)"
    assert_includes route, 'actual == \'mount MaintenanceTasks::Engine, at: "/maintenance_tasks"\''
    assert_includes route, 'mount MaintenanceTasks::Engine, at: "/admin/maintenance_tasks", as: :admin_maintenance_tasks'
    assert_includes initializer, 'MaintenanceTasks.parent_controller = "Admin::MaintenanceTasksController"'
    assert_includes initializer, "T.bind(self, Admin::MaintenanceTasksController)"
    assert_includes initializer, '"triggered_by_user_id" => T.must(authorization_user).id'
    assert_includes initializer, "Rails.application.config.to_prepare"
    assert_includes initializer, "MaintenanceTasks::TasksHelper"
    assert_includes initializer, "target.prepend(helper) unless target < helper"
    assert_includes initializer, "MaintenanceTasks::ApplicationController.content_security_policy false"
    refute_includes initializer, "content_security_policy_nonce"
    refute_includes initializer, "style_src_elem"
    assert_includes controller, "class MaintenanceTasksController < BaseController"
    refute_includes controller, "include Rails.application.routes.url_helpers"
    refute_includes controller, "helper Rails.application.routes.url_helpers"
    assert_includes controller, "helper Admin::MaintenanceTasksHelper"
    assert_includes controller, "authorize! :maintenance_task, to: :manage?"
    refute_includes controller, "BULMA_CDN"
    refute_includes controller, "has_role?"
    assert_includes policy, "def manage?"
    assert_includes policy, "admin?"
    assert_includes layout, 'render template: "layouts/admin"'
    assert_includes layout, 'data-controller="maintenance-tasks-refresh"'
    refute_includes layout, "stylesheet_link_tag"
    assert_includes helper, '"new" => { badge: "badge-neutral", progress: "progress-neutral" }'
    assert_includes helper, '"running" => { badge: "badge-info", progress: "progress-info" }'
    assert_includes helper, '"paused" => { badge: "badge-warning", progress: "progress-warning" }'
    assert_includes helper, '"succeeded" => { badge: "badge-success", progress: "progress-success" }'
    assert_includes helper, '"errored" => { badge: "badge-error", progress: "progress-error" }'
    refute_includes helper, 'badge-\#{color}'
    refute_includes helper, 'progress-\#{color}'
    assert_includes helper, 'class: "select w-full"'
    assert_includes helper, 'class: "textarea w-full"'
    assert_includes helper, "form_builder: ActionView::Helpers::FormBuilder"
    refute_includes helper, "T.untyped"
    assert_class_tokens tasks_index, "card", "card-border"
    assert_class_tokens task, "link", "link-hover"
    assert_class_tokens task_show, "fieldset"
    assert_class_tokens task_show, "file-input"
    assert_includes task_show, '<div class="card-actions flex-wrap justify-end">'
    assert_includes task_show, 'form.submit "Run", class: action_button_classes(:primary)'
    assert_class_tokens task_show, "collapse", "collapse-arrow"
    assert_class_tokens task_show, "mockup-code"
    assert_includes task_show, "code.lines(chomp: true).each.with_index(1)"
    assert_includes task_show, '<pre data-prefix="<%= line_number %>"><code><%= highlight_code(line) %></code></pre>'
    refute_includes task_show, '<pre data-prefix=""><code><%= highlight_code(code) %></code></pre>'
    assert_includes controller_test, 'assert_select ".mockup-code > pre", count: source_lines.length'
    assert_includes controller_test, 'code_lines.pluck("data-prefix")'
    assert_includes task_show, '<%= with_pagination(aria_label: "Previous runs pagination") do %>'
    assert_includes task_show, 'class: pagination_item_classes %>'
    refute_includes task_show, 'class="join justify-end"'
    refute_includes task_show, 'class: "btn join-item"'
    assert_includes run, '<div class="card-actions flex-wrap justify-end">'
    assert_includes run, "class: action_button_classes(:secondary)"
    assert_includes run, "class: action_button_classes(:warning)"
    assert_includes run, "class: action_button_classes(:destructive)"
    paused_actions = run[/<% if run\.paused\? %>(.*?)<% elsif run\.errored\? %>/m, 1]
    pausing_actions = run[/<% elsif run\.pausing\? %>(.*?)<% elsif run\.active\? %>/m, 1]
    active_actions = run[/<% elsif run\.active\? %>(.*?)<% end %>/m, 1]
    refute_nil paused_actions
    refute_nil pausing_actions
    refute_nil active_actions
    assert_source_order(paused_actions,
      'class: action_button_classes(:secondary)',
      'class: action_button_classes(:destructive)')
    assert_source_order(pausing_actions,
      'class: action_button_classes(:warning)',
      'class: action_button_classes(:destructive)')
    assert_source_order(active_actions,
      'class: action_button_classes(:warning)',
      'class: action_button_classes(:destructive)')
    refute_includes [task_show, run].join, "btn-sm"
    assert_includes task, "admin_maintenance_tasks.task_path(task)"
    assert_includes task_show, "admin_maintenance_tasks.task_runs_path(@task)"
    assert_includes run, "admin_maintenance_tasks.resume_task_run_path(@task, run)"
    assert_class_tokens error, "alert", "alert-error", "alert-soft"
    refute_includes maintenance, 'create_file "app/assets/stylesheets/maintenance_tasks.css"'
    refute_includes maintenance, "bulma@"
    assert_includes refresh, 'this.element.querySelector("[data-refresh]")'
    assert_includes refresh, "window.setTimeout"
    assert_includes refresh, "this.abortController?.abort()"
    assert_includes maintenance, 'create_file "docs/maintenance_tasks.md"'
    assert_includes controller_test, "assert_enqueued_with(job: MaintenanceTasks::TaskJob)"
    assert_includes controller_test, 'assert_select ".badge.badge-neutral", text: "New", count: 3'
    assert_includes controller_test, 'assert_select "a", text: "Maintenance::CountdownTask", count: 1'
    assert_includes controller_test, 'assert_equal "succeeded", run.reload.status'
    assert_includes controller_test, 'assert_equal "pausing", pausing_run.reload.status'
    assert_includes controller_test, 'assert_equal "enqueued", resumable_run.reload.status'
    assert_includes controller_test, 'assert_equal "cancelled", cancellable_run.reload.status'
    assert_includes controller_test, 'input.file-input[type=file][name=csv_file]'
    assert_includes maintenance, "no_collection"
    assert_includes maintenance, "csv_collection"
    assert_includes maintenance, "attribute :quantity, :integer"
    assert_includes maintenance, "attribute :ratio, :float"
    assert_includes maintenance, "attribute :amount, :decimal"
    assert_includes maintenance, "attribute :scheduled_at, :datetime"
    assert_includes maintenance, "attribute :due_on, :date"
    assert_includes maintenance, "attribute :starts_at, :time"
    assert_includes maintenance, "def process"
    assert_includes countdown_task, "class CountdownTask < MaintenanceTasks::Task"
    assert_includes countdown_task, "10.downto(1).to_a"
    assert_includes countdown_task, 'Rails.logger.info("Countdown: \#{number}")'
    assert_includes countdown_test, "numbers = Maintenance::CountdownTask.collection"
    assert_includes countdown_test, "assert_equal 10.downto(1).to_a, numbers"
    assert_includes countdown_test, "numbers.each { |number| Maintenance::CountdownTask.process(number) }"
    refute_includes maintenance, '.keep'
    assert_operator after_bundle.index("install_solid_components"), :<,
      after_bundle.index('install_maintenance_tasks if VALUES.fetch("maintenance_tasks") == "enable"')
    assert_operator after_bundle.index('install_maintenance_tasks if VALUES.fetch("maintenance_tasks") == "enable"'), :<,
      after_bundle.index("configure_database")
  end

  def test_generates_web_push_client_state_reconciliation_and_settings_page
    client = generated_file_source("app/javascript/controllers/push_subscription_controller.js")
    notifications_view = generated_file_source("app/views/web_push_settings/show.html.erb")
    notifications_controller = generated_file_source("app/controllers/web_push_settings_controller.rb")
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
    assert_includes defaults, 'link_to application_routes.web_push_settings_path'
    assert_includes defaults, 'controller_path == "web_push_settings"'
    refute_includes defaults, 'web_push_section'
    refute_includes devise, 'accounts/push_notifications'
    assert_includes defaults, 'body_controllers << "push-subscription" if web_push_enabled'
    assert_includes evidence, 'set_evidence_web_push_mode("rotated")'
    assert_includes evidence, 'set_evidence_web_push_mode("default")'
    assert_includes evidence, 'set_evidence_web_push_mode("denied")'
    assert_includes evidence, 'set_evidence_web_push_mode("unsupported")'
  end

  def test_generates_always_on_in_app_notifications_with_global_cursor_and_personal_delivery_sync
    notifications = source_between("def configure_in_app_notifications", "def configure_default_views")
    model = generated_file_source("app/models/notification.rb")
    delivery_model = generated_file_source("app/models/notification_delivery.rb")
    header = generated_file_source("app/views/shared/_header.html.erb")
    unread_status = generated_file_source("app/views/notifications/_unread_status.html.erb")
    tab_unread_status = generated_file_source("app/views/notifications/_tab_unread_status.html.erb")
    announcement_item = generated_file_source("app/views/notifications/_announcement.html.erb")
    announcements_panel = generated_file_source("app/views/notifications/_announcements_panel.html.erb")
    announcement_read_error = generated_file_source("app/views/notifications/_announcement_read_error.html.erb")
    popover = generated_file_source("app/views/notifications/_popover.html.erb")
    history = generated_file_source("app/views/notifications/index.html.erb")
    read_announcements = generated_file_source("app/views/notifications/read_announcements.turbo_stream.erb")
    admin_index = generated_file_source("app/views/admin/notifications/index.html.erb")
    admin_form = generated_file_source("app/views/admin/notifications/_form.html.erb")
    recipient_controller = generated_file_source("app/javascript/controllers/notification_recipients_controller.js")
    popover_controller = generated_file_source("app/javascript/controllers/notification_popover_controller.js")
    announcements_controller = generated_file_source("app/javascript/controllers/notification_announcements_controller.js")
    notification_item = generated_file_source("app/views/notifications/_notification.html.erb")
    controller = generated_file_source("app/controllers/notifications_controller.rb")
    admin_controller = generated_file_source("app/controllers/admin/notifications_controller.rb")
    service = generated_file_source("app/services/notification_delivery_synchronization.rb")
    recipients = generated_file_source("app/controllers/admin/notification_recipients_controller.rb")
    recipient_results = generated_file_source("app/views/admin/notification_recipients/index.html.erb")
    notification_test = generated_file_source("test/models/notification_test.rb")
    delivery_test = generated_file_source("test/models/notification_delivery_test.rb")
    user_notification_test = generated_file_source("test/models/user_notification_test.rb")
    controller_test = generated_file_source("test/controllers/notifications_controller_test.rb")
    admin_controller_test = generated_file_source("test/controllers/admin/notifications_controller_test.rb")
    system_test = generated_file_source("test/system/notifications_test.rb")
    after_bundle = @source.byteslice(@source.index("after_bundle do")..)

    assert_includes notifications, 'add_check_constraint :notifications'
    refute_includes notifications, "t.string :message"
    assert_includes notifications, 'add_index :notifications, [:audience, :draft, :published_at, :id]'
    assert_includes notifications, 'generate "migration", "AddGlobalNotificationsReadAtToUsers"'
    assert_includes notifications, 'add_column :users, :global_notifications_read_at, :datetime, null: false'
    refute_match(/add_column :users, :global_notifications_read_at.*default:/, notifications)
    assert_includes model, "has_rich_text :message, store_if_blank: false"
    assert_includes model, "message.to_plain_text.strip"
    assert_includes model, "errors.add(:message, :too_long, count: 140)"
    assert_includes model, 'scope :published, ->(cutoff = Time.current)'
    assert_includes model, 'where(draft: false).where(published_at: ..cutoff)'
    assert_includes model, 'scope :announcements, -> { where(audience: "all_users") }'
    assert_includes model, 'validate :published_selected_notification_has_recipient'
    assert_includes notifications, 'add_index :notification_deliveries, [:notification_id, :user_id], unique: true'
    assert_includes notifications, 'foreign_key: { on_delete: :cascade }'
    assert_includes delivery_model, 'validate :notification_targets_selected_users'
    assert_includes delivery_model, 'errors.add(:notification, :invalid) unless notification&.selected_users?'
    assert_includes delivery_model, '.where(notification: { published_at: ..cutoff })'
    assert_includes notifications, 'save_with_delivery_synchronization!'
    assert_includes service, 'NotificationDelivery.insert_all(rows, unique_by:'
    assert_includes service, 'notification.notification_deliveries.where.not(user_id: recipient_ids).delete_all'
    assert_includes model, 'after_update :delete_deliveries_for_announcement, if: :changed_to_announcement?'
    assert_includes model, 'saved_change_to_audience? && all_users?'
    assert_includes model, 'notification_deliveries.delete_all'
    refute_includes service, "User.ids"
    refute_includes service, "all_users"
    assert_includes notifications, 'before_create :initialize_global_notifications_read_at'
    assert_match(/inject_into_class "app\/models\/user\.rb", "User", <<~RUBY\n\s+extend T::Sig/, notifications)
    refute_includes notifications, 'self.created_at ||= Time.current'
    assert_includes notifications, 'self.global_notifications_read_at = T.must(created_at)'
    assert_includes notifications, 'def has_unread_personal_notifications?(cutoff: Time.current)'
    assert_includes notifications, 'def has_unread_announcements?(cutoff: Time.current)'
    assert_includes notifications, 'def has_unread_notifications?(cutoff: Time.current)'
    assert_includes notifications, '.exists?(["published_at > ?", global_notifications_read_at])'
    assert_includes notifications, 'has_unread_personal_notifications?(cutoff:) || has_unread_announcements?(cutoff:)'
    assert_includes notifications, 'def mark_announcements_read_through!(cutoff:)'
    assert_includes notifications, '.where(id:, global_notifications_read_at: ...cutoff)'
    assert_includes notifications, '.update_all(global_notifications_read_at: cutoff, updated_at: now)'
    assert_match(/def mark_announcements_read_through!\(cutoff:\).*?reload/m, notifications)
    assert_includes controller, 'find_by!(notification_id: params.expect(:id))'
    assert_includes controller, 'deliveries_scope.where(opened_at: nil).update_all'
    assert_includes notifications, 'patch "open-all", action: :open_all'
    assert_includes notifications, 'patch "global-read", action: :read_announcements, as: :read_announcements'
    assert_includes controller, 'TABS = %w[personal announcements].freeze'
    assert_includes controller, '@tab = params.fetch(:tab, "personal")'
    assert_includes controller, 'raise ActionController::BadRequest unless TABS.include?(@tab)'
    assert_includes controller, 'Notification.published(cutoff).announcements.ordered.with_rich_text_message_and_embeds'
    assert_includes controller, 'raise ActionController::BadRequest if @cutoff > Time.current'
    assert_includes controller, 'T.must(current_user).mark_announcements_read_through!(cutoff: @cutoff)'
    assert_includes controller, 'rescue ActiveRecord::ActiveRecordError'
    assert_equal 1, controller.scan("mark_announcements_read_through!").size
    assert_includes recipients, '.limit(20)'
    assert_includes recipients, 'profiles.display_name LIKE :query'
    refute_includes recipients, "integer_query"
    refute_includes recipients, "users.id = :id"
    assert_includes recipient_results, "T.must(user.profile).display_name"
    refute_includes recipient_results, "ID:"
    assert_includes header, 'popovertarget="notifications-popover"'
    assert_includes header, 'class="dropdown dropdown-end'
    assert_includes header, 'notification-popover#load'
    refute_includes header, 'src: application_routes.popover_notifications_path'
    assert_includes header, 'class="skeleton h-4'
    assert_includes unread_status, 'class="status status-primary status-sm"'
    assert_includes unread_status, "current_user.has_unread_notifications?"
    assert_includes tab_unread_status, 'class="status status-primary status-xs"'
    assert_includes popover, 'open_all_notifications_path'
    assert_includes popover, 'class: "btn btn-outline btn-sm"'
    assert_includes popover, "with_tab(tabs:, size: :sm)"
    assert_includes popover, 'popover_notifications_path(tab: "personal")'
    assert_includes popover, 'popover_notifications_path(tab: "announcements")'
    assert_includes popover, "notifications_path(tab:)"
    assert_includes notification_item, "delivery.notification.message"
    assert_includes announcement_item, "announcement.message"
    refute_includes announcement_item, "open_notification_path"
    assert_includes announcements_panel, "read_announcements_notifications_path"
    assert_includes announcements_panel, "form.hidden_field :cutoff"
    assert_includes announcements_panel, "form.hidden_field :surface"
    assert_includes announcements_panel, 'render "notifications/announcement_read_error"'
    assert_includes announcement_read_error, 'class="alert alert-error alert-soft'
    assert_includes history, 'turbo_action: "advance"'
    assert_includes history, "with_tab(tabs:)"
    assert_includes history, 'notifications_path(tab: "personal")'
    assert_includes history, 'notifications_path(tab: "announcements")'
    assert_includes read_announcements, 'turbo_stream.replace "notification_unread_status"'
    assert_includes read_announcements, 'status_target = "\#{@surface}_announcements_unread_status"'
    assert_includes read_announcements, 'if @read_failed'
    assert_includes read_announcements, 'partial: "notifications/announcement_read_error"'
    assert_includes popover_controller, 'if (event.newState !== "open") return'
    refute_includes popover_controller, "|| this.frameTarget.src"
    assert_includes popover_controller, 'this.frameTarget.removeAttribute("complete")'
    assert_includes popover_controller, "this.frameTarget.reload()"
    assert_includes announcements_controller, 'document.documentElement.hasAttribute("data-turbo-preview")'
    assert_includes announcements_controller, "this.formTarget.requestSubmit()"
    assert_includes announcements_controller, "if (event.detail.success) return"
    assert_includes announcements_controller, "failed(event)"
    assert_includes announcements_controller, "event.stopPropagation()"
    assert_includes announcements_controller, 'this.errorTarget.classList.remove("hidden")'
    assert_includes admin_index, 'table table-sm table-pin-rows min-w-max'
    assert_includes admin_index, "notification.message_plain_text"
    assert_includes admin_index, 'notification.all_users? ? t("notifications.admin.all_users")'
    assert_includes admin_controller, "authorize! @notification, to: :update?"
    assert_includes admin_form, "form.rich_text_area :message"
    assert_includes admin_form, "[user.id, T.must(user.profile).display_name]"
    assert_includes admin_form, "T.must(user.profile).display_name"
    refute_includes admin_form, "index_with"
    assert_includes admin_form, "notification_recipients_remove_label_value"
    assert_includes admin_form, 'notification_recipients_target: "audience"'
    assert_includes admin_form, 'data-notification-recipients-target="selector"'
    assert_includes admin_form, 'class="list rounded-box border border-base-300" data-notification-recipients-target="hidden" hidden'
    assert_includes admin_form, 'data-notification-recipients-target="count"'
    assert_includes admin_form, 'data-notification-recipients-target="empty"'
    refute_includes admin_form, "form.text_area :message"
    assert_includes recipients, ".where.not(id: @selected_ids)"
    assert_includes recipient_controller, "remove(event)"
    assert_includes recipient_controller, 'this.selectorTarget.hidden = !selectedUsers'
    assert_includes recipient_controller, 'input.disabled = this.audienceTarget.value !== "selected_users"'
    assert_includes recipient_controller, "this.countTarget.textContent = entries.length"
    assert_includes recipient_controller, 'row.className = "list-row items-center"'
    assert_includes recipient_controller, "row.append(name, button, input)"
    assert_includes recipient_controller, 'button.dataset.action = "notification-recipients#remove"'
    assert_includes recipient_controller, 'button.className = "btn btn-outline btn-sm"'
    refute_includes recipient_controller, 'wrapper.className = "badge'
    assert_includes recipient_results, 'class="list rounded-box border border-base-300"'
    assert_includes recipient_results, 'class="btn btn-outline btn-sm"'
    refute_includes recipient_results, "btn-active"
    assert_includes notification_test, 'test "published selected users require at least one existing recipient"'
    assert_includes notification_test, 'test "all users never create delivery rows and switching to all users deletes existing rows"'
    assert_includes delivery_test, 'test "rejects delivery rows for all-user announcements"'
    assert_includes user_notification_test, 'user.created_at.to_fs(:usec), user.global_notifications_read_at.to_fs(:usec)'
    assert_includes user_notification_test, 'test "shows old announcements to later users without marking them unread"'
    assert_includes user_notification_test, 'test "distinguishes personal and announcement unread state"'
    assert_includes user_notification_test, 'test "backdated publication and message edits do not create announcement unread state"'
    assert_includes user_notification_test, 'test "moves the announcement cursor monotonically and reloads a newer concurrent value"'
    assert_includes controller_test, 'test "defaults to personal deliveries and separates announcements"'
    assert_includes controller_test, 'test "GET requests do not move the announcement cursor and invalid tabs are rejected"'
    assert_includes controller_test, 'test "marks only announcements through the displayed cutoff"'
    assert_includes controller_test, 'test "keeps unread indicators and returns a retryable stream when the cursor update fails"'
    assert_includes controller_test, 'test "rejects a malformed announcement cutoff without changing the cursor"'
    assert_includes controller_test, 'test "rejects a future announcement cutoff without changing the cursor"'
    assert_includes controller_test, 'test "rejects an unknown announcement surface without changing the cursor"'
    assert_includes admin_controller_test, 'test "rejects a published selected notification without recipients"'
    assert_includes admin_controller_test, 'test "renders all-user and selected-user edit forms for an administrator"'
    assert_includes admin_controller_test, 'test "updates a selected notification without dropping unchanged recipients"'
    assert_includes system_test, 'test "shows announcements without personal read controls and marks the displayed cutoff"'
    assert_includes system_test, 'test "edits a selected notification without losing existing recipients"'
    assert_includes system_test, 'assert_no_button I18n.t("notifications.open")'
    assert_includes system_test, "popover_requests = resource_names.count"
    assert_includes system_test, 'assert_operator resource_names.count { |name| name.match?(%r{/notifications/popover}) }, :>, popover_requests'
    assert_includes system_test, '(?:page=2&tab=announcements|tab=announcements&page=2)'
    assert_includes system_test, 'assert_selector \'[data-notification-recipients-target="selector"][hidden]\''
    assert_operator after_bundle.index("configure_lexxy"), :<, after_bundle.index("configure_in_app_notifications")
    assert_match(/configure_profile\n  configure_in_app_notifications\n  configure_api/m, after_bundle)
  end

  def test_generates_fixed_multi_role_storage_and_action_policy_authorization
    roles = source_between("def configure_roles", "def configure_profile")
    model = generated_file_source("app/models/user_role.rb")
    policy = generated_file_source("app/policies/user_policy.rb")
    overview_controller = generated_file_source("app/controllers/admin/overview_controller.rb")
    overview_view = generated_file_source("app/views/admin/overview/show.html.erb")
    users_controller = generated_file_source("app/controllers/admin/users_controller.rb")
    avatars_controller = generated_file_source("app/controllers/admin/user_avatars_controller.rb")
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
    assert_includes roles, 'attr_accessor :skip_initial_admin_role'
    assert_includes roles, 'after_create :grant_initial_admin_role_in_development'
    assert_includes roles, 'def has_role?(role)'
    assert_includes roles, 'def grant_role!(role)'
    assert_includes roles, 'find_or_create_by!(role: normalized_role)'
    assert_includes roles, 'def revoke_role!(role)'
    assert_includes roles, 'def last_admin?'
    assert_includes roles, 'def grant_initial_admin_role_in_development'
    assert_includes roles, 'return if skip_initial_admin_role'
    assert_includes roles, 'grant_role!(:admin) if UserRole.admin.none?'
    refute_includes roles, 'User.count == 1'
    refute_includes roles, 'after_commit :grant_initial_admin_role_in_development'

    assert_includes roles, 'authorize :user, through: :authorization_user'
    assert_includes roles, 'helper_method :authorization_user'
    assert_includes roles, 'rescue_from ActionPolicy::Unauthorized, with: :render_forbidden'
    assert_includes roles, 'sig { params(_error: ActionPolicy::Unauthorized).void }'
    assert_includes roles, 'def render_forbidden(_error)'
    assert_includes roles, 'include Pagy::Method'
    assert_includes policy, 'def overview?'
    assert_includes policy, 'def index?'
    assert_includes policy, 'def show?'
    assert_includes policy, 'def edit?'
    assert_includes policy, 'def update?'
    assert_includes policy, 'def manage_roles?'
    assert_includes policy, 'relation_scope do |relation|'
    assert_includes overview_controller, 'authorize! User, to: :overview?'
    assert_includes overview_controller, '@total_users = User.count'
    assert_includes overview_controller, '@administrators = User.where(id: UserRole.admin.select(:user_id)).count'
    assert_includes overview_controller, '@new_users_last_30_days = User.where(created_at: 30.days.ago..).count'
    assert_includes overview_controller, '@published_faqs = Faq.where(published: true).count'
    assert_includes overview_controller, '@managed_pages = Page.count'
    assert_includes overview_view, 'content_for :page_title, t("admin.overview.title")'
    assert_includes overview_view, 'data-admin-overview-stats'
    assert_class_tokens overview_view, "grid", "sm:grid-cols-2", "xl:grid-cols-3"
    assert_includes roles, 'root "overview#show"'
    assert_includes users_controller, 'authorize! User, to: :index?'
    assert_includes users_controller, 'authorized_scope(#{user_scope})'
    assert_includes users_controller, 'pagy(:offset, users, limit: 25)'
    assert_includes users_controller, 'authorize! @user, to: :show?'
    assert_includes users_controller, 'authorize! @user, to: :edit?'
    assert_includes users_controller, 'authorize! @user, to: :update?'
    assert_includes users_controller, 'params.expect(profile: %i[screen_name display_name avatar_upload])'
    assert_includes avatars_controller, 'authorize! @user, to: :update?'
    assert_includes avatars_controller, 'profile.avatar.purge if profile.avatar.attached?'
    assert_includes roles_controller, 'authorize! @user, to: :manage_roles?'
    assert_includes roles_controller, '@user == authorization_user'
    assert_includes roles_controller, 'head :unprocessable_content'
    assert_includes roles, 'resources :users, only: %i[index show edit update] do'
    assert_includes roles, 'resource :avatar, only: :destroy, controller: "user_avatars"'
    assert_includes roles, 'resources :roles, only: %i[create destroy], controller: "user_roles", param: :role'
  end

  def test_generates_admin_role_ui_bootstrap_task_and_local_seed_hook
    roles = source_between("def configure_roles", "def configure_profile")
    view = generated_file_source("app/views/admin/users/index.html.erb")
    show = generated_file_source("app/views/admin/users/show.html.erb")
    edit = generated_file_source("app/views/admin/users/edit.html.erb")
    task = generated_file_source("lib/tasks/roles.rake")
    service = generated_file_source("app/services/admin_role_grant.rb")
    local_seed = generated_file_source("db/seeds.local.rb.example")
    helper = generated_file_source("app/helpers/application_helper.rb")
    agents = File.binread(File.expand_path("../../AGENTS.md", __dir__)).force_encoding(Encoding::UTF_8)

    assert_class_tokens view, "card", "card-border", "bg-base-100"
    assert_class_tokens view, "overflow-x-auto"
    assert_class_tokens view, "table", "table-sm", "table-pin-rows", "min-w-max"
    assert_class_tokens view, "avatar"
    assert_class_tokens view, "link"
    refute_includes view, "link-hover"
    assert_includes agents, "hover時だけ下線を表示する`link-hover`は使用しません"
    assert_includes agents, "header・footerなどのnavigation内やdaisyUIの`menu` component内"
    assert_class_tokens view, "badge"
    assert_includes helper, 'destructive: "btn btn-outline btn-error"'
    assert_includes helper, 'warning: "btn btn-outline btn-warning"'
    assert_includes view, 'admin_user_path(user)'
    assert_includes view, 'profile_avatar(T.must(user.profile), size: 40, alt: "")'
    refute_includes view, 'admin_user_roles_path'
    refute_includes view, 'admin_user_role_path'
    assert_includes show, "class: action_button_classes(:destructive)"
    assert_includes show, "class: action_button_classes(:warning)"
    assert_includes show, 'data: { turbo_confirm: t("admin.users.grant_confirm", name: profile.display_name) }'
    assert_includes show, 'data: { turbo_confirm: t("admin.users.revoke_confirm", name: profile.display_name) }'
    assert_includes edit, 'render "profiles/form", profile: @profile, form_url: admin_user_path(@user), cancel_path: admin_user_path(@user)'
    assert_includes edit, 'render "profiles/avatar_delete", profile: @profile, avatar_path: admin_user_avatar_path(@user)'
    assert_includes roles, "class Admin::UsersControllerTest < ActionDispatch::IntegrationTest\n      include ActiveJob::TestHelper"
    assert_includes view, 'pagination(@pagy, aria_label: t("admin.users.pagination"))'
    assert_class_tokens helper, "join"
    assert_includes helper, '"btn join-item"'
    refute_includes view, '@pagy.page_url(:previous)'
    refute_includes view, '@pagy.page_url(:next)'
    refute_match(/(?:bg|text|border)-(?:blue|gray|slate|red|green|yellow)-\d+/, view)
    refute_includes view, "dark:"
    refute_match(/#[0-9a-f]{3,8}(?![0-9a-z])/i, view)

    assert_includes task, 'task :grant_admin, [:user_id] => :environment'
    assert_includes task, 'AdminRoleGrant.call(arguments[:user_id])'
    refute_includes task, 'User.find'
    assert_includes service, 'sig { params(user_id: T.nilable(T.any(String, Integer)), output: IO).returns(User) }'
    assert_includes service, 'User.find(identifier)'
    assert_includes service, 'user.grant_role!(:admin)'
    assert_includes roles, 'Rails.root.join("db/seeds.local.rb")'
    assert_includes roles, 'load local_seeds.to_s if local_seeds.file?'
    assert_includes roles, 'append_to_file ".gitignore", "\\n/db/seeds.local.rb\\n"'
    assert_includes local_seed, 'AdminRoleGrant.call(ENV.fetch("ADMIN_USER_ID"))'
    assert_includes roles, 'create_locale_pair("roles"'
    assert_includes roles, '"last_admin" => "The final administrator cannot delete their account"'
    assert_includes roles, 'I18n.t("admin.user_roles.create.notice")'
    assert_includes roles, 'I18n.t("admin.user_roles.destroy.self_forbidden")'
  end

  def test_role_generation_uses_the_single_devise_authentication_context_and_protects_the_last_admin
    roles = source_between("def configure_roles", "def configure_profile")
    accounts = source_between("  accounts_controller = <<~RUBY", '  create_file "app/controllers/accounts_controller.rb"')
    assert_includes roles, "def authorization_user"
    assert_includes roles, "current_user"
    refute_includes roles, "Current.user"
    assert_includes roles, "before_action :authenticate_user!"
    assert_includes @source, "configure_devise_routes"
    assert_includes @source, "devise_for :users, skip: :all"
    assert_includes @source, 'to: "users/passkey_sessions#new"'
    assert_includes accounts, "if T.must(current_user).last_admin?"
    assert_includes accounts, 't("accounts.destroy.last_admin")'
    assert_match(/install_devise\n  install_siwe if .*additional_login_methods.*siwe.*\n  configure_roles/m, @source)
  end

  def test_role_tests_cover_storage_policy_controllers_and_task
    model_test = generated_file_source("test/models/user_role_test.rb")
    policy_test = generated_file_source("test/policies/user_policy_test.rb")
    users_controller_test = generated_file_source("test/controllers/admin/users_controller_test.rb")
    roles_controller_test = generated_file_source("test/controllers/admin/user_roles_controller_test.rb")
    avatars_controller_test = generated_file_source("test/controllers/admin/user_avatars_controller_test.rb")
    task_test = generated_file_source("test/tasks/roles_task_test.rb")

    assert_includes model_test, 'assert_not invalid.valid?'
    assert_includes model_test, 'test "grants admin when no administrator exists in development"'
    assert_includes model_test, 'test "does not grant admin when an administrator already exists in development"'
    assert_includes model_test, 'test "skips sample users and grants admin to the next created user"'
    assert_includes model_test, '10.times.map { User.create!(skip_initial_admin_role: true) }'
    assert_includes model_test, 'assert_equal 0, UserRole.admin.count'
    assert_includes model_test, 'test "does not grant initial admin outside development"'
    assert_includes model_test, 'with_rails_environment("development")'
    assert_includes model_test, '%w[test production].each do |environment_name|'
    assert_includes model_test, 'Rails.env = environment'
    assert_includes model_test, 'Rails.env = previous_environment'
    assert_includes model_test, 'assert_no_difference("UserRole.count") { user.grant_role!(:admin) }'
    assert_includes model_test, 'UserRole.insert_all!'
    assert_includes model_test, 'assert_raises(ActiveRecord::NotNullViolation)'
    assert_includes model_test, 'assert_raises(ActiveRecord::RecordNotDestroyed)'
    assert_includes model_test, 'assert_not user.destroy'
    assert_includes policy_test, 'apply(:index?)'
    assert_includes policy_test, 'apply(:show?)'
    assert_includes policy_test, 'apply(:edit?)'
    assert_includes policy_test, 'apply(:update?)'
    assert_includes policy_test, 'apply_scope(User.all, type: :active_record_relation)'
    assert_includes users_controller_test, 'assert_have_authorized_scope(type: :active_record_relation, with: UserPolicy)'
    assert_includes users_controller_test, 'assert_response :forbidden'
    assert_includes users_controller_test, 'create_additional_users(25)'
    assert_includes users_controller_test, 'I18n.t("admin.users.pagination")'
    assert_includes users_controller_test, 'test "updates only the users profile"'
    assert_includes users_controller_test, 'test "updates an avatar through the existing profile policy"'
    assert_includes users_controller_test, 'get edit_admin_user_url(@regular)'
    assert_includes users_controller_test, 'patch admin_user_url(@regular), params: { profile: { display_name: "Unauthenticated" } }'
    assert_includes users_controller_test, 'assert_not @regular.has_role?(:admin)'
    assert_includes avatars_controller_test, 'test "allows an admin to delete another users avatar"'
    assert_includes avatars_controller_test, 'assert_response :forbidden'
    assert_includes roles_controller_test, 'assert_no_difference("UserRole.count")'
    assert_includes roles_controller_test, 'assert_response :unprocessable_content'
    assert_includes roles_controller_test, 'assert_redirected_to new_user_session_url'
    assert_includes roles_controller_test, 'delete admin_user_role_url(@admin, "admin")'
    assert_includes @source, 'test "refuses deletion of the last admin account"'
    assert_includes task_test, 'assert_no_difference("User.count")'
    assert_includes task_test, '@task.reenable'
    assert_includes task_test, 'load Rails.root.join("db/seeds.rb")'
    assert_includes task_test, 'File.write(local_seeds, \'ENV["ROLE_LOCAL_SEED_LOADED"] = "yes"\\n\')'
    assert_includes @source, 'require "action_policy/test_helper"'
    assert_includes @source, 'include ActionPolicy::TestHelper'
  end

  def test_generated_form_controls_cards_and_buttons_use_daisyui_defaults
    input_classes = @source.scan(/class: "input[^"]*"/)
    refute_empty input_classes
    input_classes.each do |input_class|
      refute_includes input_class, "min-h-11"
    end

    card_classes = class_attributes(@source).select { |classes| classes.include?("card-border") }
    refute_empty card_classes
    card_classes.each do |classes|
      assert_includes classes, "card"
      assert_includes classes, "bg-base-100"
      refute_includes classes, "border-base-300"
      refute_includes classes, "shadow-none"
    end

    custom_suffix = "rapid"
    removed_classes = %w[btn card input].map { |component| "#{component}-#{custom_suffix}" }
    removed_classes.concat((1..3).map { |level| "shadow-elevation-#{level}" })
    removed_classes.each { |class_name| refute_includes @source, class_name }

    helper_button_classes = @source.scan(/class: "([^"]*\bbtn\b[^"]*)"/).flatten
    html_button_classes = @source.scan(/class="([^"]*\bbtn\b[^"]*)"/).flatten
    javascript_button_classes = @source.scan(/className = "([^"]*\bbtn\b[^"]*)"/).flatten
    button_classes = helper_button_classes + html_button_classes + javascript_button_classes
    button_classes.each { |button_class| refute_includes button_class, "min-h-11" }
    assert_equal({
      "btn" => 2,
      "btn btn-circle btn-ghost" => 1,
      "btn btn-ghost btn-circle" => 1,
      "btn btn-outline" => 3,
      "btn btn-outline btn-sm" => 4,
      "btn btn-primary btn-outline" => 1,
      "<%= compact ? 'btn btn-sm' : action_button_classes(:secondary) %>" => 1,
      "btn join-item" => 3,
      "btn mt-3 w-full" => 1
    }, button_classes.tally)
    refute_match(/\bclass(?:=|:\s*)'[^']*\bbtn\b/, @source)

    assert_includes @source, 'primary: "btn btn-primary"'
    assert_operator @source.scan("action_button_classes(:primary)").length, :>=, 2
  end

  def test_siwe_sign_in_uses_an_explicit_stimulus_action
    javascript = generated_file_source("app/javascript/controllers/siwe_sign_in_controller.js")
    devise_views = source_between("def configure_devise_views", "def configure_in_app_notifications")

    assert_includes @source, 'app/javascript/controllers/siwe_sign_in_controller.js'
    assert_includes @source, 'import { Controller } from "@hotwired/stimulus"'
    assert_includes @source, 'data-controller="siwe-sign-in"'
    assert_includes @source, 'data-action="siwe-sign-in#authenticate"'
    assert_includes @source, "async authenticate()"
    refute_includes @source, "async connect()"
    assert_includes @source, 'data-siwe-sign-in-target="error"'
    assert_includes devise_views, 'data-siwe-sign-in-wallet-not-registered-value="<%= t(\'siwe.errors.wallet_not_registered\') %>"'
    assert_includes javascript, 'this.modeValue === "login"'
    assert_includes javascript, 'payload.error === "wallet_not_registered"'
    assert_includes javascript, "this.walletNotRegisteredValue"
    refute_includes @source, 'app/javascript/siwe_sign_in.js'
    refute_includes @source, 'import \\"siwe_sign_in\\"'
  end

  def test_authentication_buttons_use_accessible_method_icons_and_evm_wallet_copy
    devise_views = source_between("def configure_devise_views", "def configure_in_app_notifications")
    passkey_svg = <<~'SVG'.strip
      <svg xmlns="http://www.w3.org/2000/svg" class="size-5" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" aria-hidden="true" data-slot="icon">
    SVG
    evm_wallet_svg = <<~'SVG'.strip
      <svg class="size-5" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 507.83 470.86" aria-hidden="true">
    SVG

    assert_equal 1, devise_views.scan("passkey_icon = <<~'SVG'.strip").size
    assert_equal 1, devise_views.scan("evm_wallet_icon = <<~'SVG'.strip").size
    assert_equal 1, devise_views.scan(passkey_svg).size
    assert_equal 1, devise_views.scan(evm_wallet_svg).size
    assert_includes devise_views,
      'd="M7.864 4.243A7.5 7.5 0 0 1 19.5 10.5c0 2.92-.556 5.709-1.568 8.268'
    assert_includes devise_views, 'd="M482.09.5 284.32 147.38l36.58-86.66z"'
    assert_equal 2, devise_views.scan('#{passkey_icon}<%= t("authentication.sign_').size
    assert_equal 2, devise_views.scan('#{evm_wallet_icon}<%= t("authentication.sign_').size
    assert_includes devise_views, '#{passkey_icon}<%= t("authentication.sign_in_with_passkey") %>'
    assert_includes devise_views, '#{passkey_icon}<%= t("authentication.sign_up_with_passkey") %>'
    assert_includes devise_views, '#{evm_wallet_icon}<%= t("authentication.sign_in_with_wallet") %>'
    assert_includes devise_views, '#{evm_wallet_icon}<%= t("authentication.sign_up_with_wallet") %>'

    assert_includes @source,
      '"sign_in_description" => "Passkeyまたは登録済みEVMウォレットでログインします。"'.b
    assert_includes @source,
      '"sign_up_description" => "PasskeyまたはEVMウォレットで、パスワードなしのアカウントを作成します。"'.b
    assert_includes @source,
      '"sign_in_with_wallet" => "EVMウォレットでログイン", "sign_up_with_wallet" => "EVMウォレットでアカウントを作成"'.b
    refute_match(Regexp.new("(?<!EVM)(?<!EOA)ウォレット".b), @source)
  end

  def test_siwe_requests_are_post_only_csrf_protected_and_rate_limited_by_ip_and_session
    sessions = generated_file_source("app/controllers/users/siwe_sessions_controller.rb")
    registrations = generated_file_source("app/controllers/users/siwe_registrations_controller.rb")
    identities = generated_file_source("app/controllers/account/siwe_identities_controller.rb")

    assert_includes @source, 'post "users/sign_in/siwe/challenge"'
    assert_includes @source, 'post "users/sign_in/siwe"'
    assert_includes @source, 'post "users/sign_up/siwe/challenge"'
    assert_includes @source, 'post "users/sign_up/siwe"'
    assert_includes @source, "resources :siwe_identities, only: %i[index show new create edit update]"
    assert_includes @source, "post :challenge, on: :collection"
    [sessions, registrations, identities].each do |controller|
      assert_includes controller, "rate_limit"
      assert_includes controller, "to: 10"
      assert_includes controller, "within: 1.minute"
      assert_includes controller, "T.bind(self,"
      assert_includes controller, '"#{request.remote_ip}:#{session_binding}"'
      refute_includes controller, "skip_forgery_protection"
    end
  end

  def test_account_settings_and_siwe_identity_management_use_current_user_scope
    profile = generated_file_source("app/views/accounts/show.html.erb")
    passkeys = generated_file_source("app/controllers/account/passkeys_controller.rb")
    destruction = generated_file_source("app/controllers/account/credential_destructions_controller.rb")
    identities = generated_file_source("app/controllers/account/siwe_identities_controller.rb")
    identity_index = generated_file_source("app/views/account/siwe_identities/index.html.erb")
    identity_edit = generated_file_source("app/views/account/siwe_identities/edit.html.erb")
    identity_show = generated_file_source("app/views/account/siwe_identities/show.html.erb")

    refute_includes profile, "login_id"
    refute_includes profile, ">ID<"
    assert_includes passkeys, "account_user.passkey_credentials.find(params.expect(:id))"
    assert_includes destruction, "CredentialDestruction.target_for!"
    assert_includes destruction, "CredentialDestruction.passkeys_for"
    refute_includes destruction, "valid_password?"
    assert_includes identities, "account_user.siwe_identities.find(params.expect(:id))"
    refute_includes identities, "valid_password?"
    assert_includes identity_index, 'class="list gap-3"'
    refute_includes identity_edit, "current_password"
    refute_includes identity_edit, "method: :delete"
    refute_includes identity_show, "current_password"
    assert_includes identity_show, 'data-siwe-sign-in-destruction-action-value="delete_siwe"'
    assert_includes @source, 't("accounts.destroy.last_admin")'
  end

  def test_profile_generation_is_always_on_with_all_features
    controller = generated_file_source("app/controllers/profiles_controller.rb")
    crop_controller = generated_file_source("app/javascript/controllers/image_crop_controller.js")
    crop_system_test = generated_file_source("test/system/profile_avatar_crop_test.rb")
    avatar_helper = generated_file_source("app/helpers/avatar_helper.rb")
    avatar_helper_test = generated_file_source("test/helpers/avatar_helper_test.rb")
    profile_form = generated_file_source("app/views/profiles/_form.html.erb")
    profile_edit = generated_file_source("app/views/profiles/edit.html.erb")
    avatar_delete = generated_file_source("app/views/profiles/_avatar_delete.html.erb")
    profile_configuration = source_between("def configure_profile", "def configure_api")

    assert_includes @source, "  configure_profile\n"
    assert_includes @source, "  install_image_cropper\n"
    assert_includes @source, 'run_checked "bin/importmap pin cropperjs@2.1.1"'
    assert_includes @source, %q(path = "vendor/javascript/#{package.sub('/', '--')}.js")
    refute_includes @source, 'rails_command "active_storage:install"'
    assert_includes @source, 't.references :user, null: false, foreign_key: true, index: { unique: true }'
    assert_includes @source, 'has_one :profile, dependent: :destroy'
    assert_includes @source, 'after_create :create_profile!'
    assert_includes @source, 'gem "haikunator"'
    assert_includes @source, 'gem "boring_avatars", "~> 0.1.0", require: "boring_avatars/bindings/rails"'
    refute_includes @source, "profile_features"
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
    assert_includes profile_form, 'form_with model: profile, url: form_url'
    assert_includes profile_form, 'link_to t("common.cancel"), cancel_path'
    assert_includes profile_edit, 'render "form", profile: @profile, form_url: profile_path, cancel_path: profile_path'
    assert_includes profile_edit, 'render "avatar_delete", profile: @profile, avatar_path: profile_avatar_path'
    assert_includes avatar_delete, 'button_to t("profiles.avatar_delete"), avatar_path'
    assert_includes profile_configuration, '<fieldset class="fieldset min-w-0 grid-cols-1">'
    assert_includes profile_configuration, 'form.file_field :avatar_upload, class: "file-input min-w-0 w-full", accept: "image/jpeg,image/png,image/webp"'
    assert_includes profile_configuration, 'data: { image_crop_target: "input", action: "change->image-crop#select" }'
    assert_includes profile_configuration, 'data-controller="image-crop"'
    assert_includes profile_configuration, 'data-image-crop-aspect-ratio-value="1"'
    assert_includes profile_configuration, 'data-image-crop-output-width-value="512"'
    assert_includes profile_configuration, 'data-image-crop-output-height-value="512"'
    assert_includes profile_configuration, 'with_modal('
    assert_includes profile_configuration, '#{avatar_crop_modal}#{form_wrapper_close}'
    assert_includes @source, "assert_select 'form[action=?] dialog', profile_path, count: 0"
    refute_includes profile_configuration, "modal-box"
    assert_includes profile_configuration, '<p class="label"><span class="min-w-0 whitespace-normal"><%= t("profiles.avatar_hint") %></span></p>'
    assert_includes @source, 'route "resource :profile, only: %i[show edit update]"'
    assert_includes profile_configuration, 'delete "profile/avatar", to: "profiles#destroy_avatar", as: :profile_avatar'
    assert_includes profile_configuration, "def destroy_avatar"
    assert_includes profile_configuration, "profile = T.must(account_user.profile)"
    assert_includes profile_configuration, "profile.avatar.purge if"
    assert_includes profile_configuration, 'I18n.t("profiles.avatar.destroy.notice")'
    assert_includes profile_configuration, '"notice" => "Your avatar image was deleted."'
    assert_includes avatar_helper, "BORING_AVATAR_COLORS = %w[#ffffff #3ea8ff #f1f5f9 #0f83fd #d6e3ed].freeze"
    assert_includes avatar_helper, "profile.user_id.to_s"
    assert_includes avatar_helper, "variant: :beam"
    assert_includes avatar_helper, "AVATAR_VARIANTS = { 40 => :header_avatar, 64 => :profile_avatar }.freeze"
    assert_includes avatar_helper, "image_tag profile.avatar.variant(variant)"
    assert_includes avatar_helper, "width: size, height: size"
    assert_includes profile_configuration, "attachment.variant :header_avatar, resize_to_fill: [40, 40], preprocessed: true"
    assert_includes profile_configuration, "attachment.variant :profile_avatar, resize_to_fill: [64, 64], preprocessed: true"
    assert_includes profile_configuration, 'assert_enqueued_jobs 2, only: ActiveStorage::TransformJob'
    assert_includes profile_configuration, 'perform_enqueued_jobs(only: ActiveStorage::TransformJob)'
    assert_includes profile_configuration, "validates :avatar_upload, avatar_upload: true"
    assert_includes profile_configuration, 'create_file "app/services/avatar_upload.rb"'
    assert_includes profile_configuration, "class AvatarUpload < T::Struct"
    assert_includes profile_configuration, "AvatarImagePolicy.validate!(AvatarUpload.coerce(upload))"
    assert_includes profile_configuration, "self.avatar = avatar_upload"
    assert_includes profile_configuration, "MAX_BYTES = T.let(5 * 1024 * 1024, Integer)"
    assert_includes profile_configuration, 'MAX_DIMENSION = T.let(4096, Integer)'
    assert_includes profile_configuration, 'raise_error(:not_square) unless image.width == image.height'
    assert_includes profile_configuration, "Marcel::MimeType.for"
    assert_includes profile_configuration, 'Vips::Image.new_from_file(path, access: :sequential, fail_on: :truncated)'
    assert_includes avatar_helper_test, "profile.user_id.to_s"
    assert_includes avatar_helper_test, "normalize_boring_avatar_ids"
    assert_includes crop_controller, 'import Cropper from "cropperjs"'
    refute_includes crop_controller, "OUTPUT_SIZE"
    refute_includes crop_controller, "avatar"
    assert_includes crop_controller, "aspectRatio: Number"
    assert_includes crop_controller, 'movable precise resizable'
    assert_includes crop_controller, "outputWidth: Number"
    assert_includes crop_controller, "outputHeight: Number"
    assert_includes crop_controller, 'if (!this.hasAspectRatioValue) return ""'
    assert_includes crop_controller, "return this.hasAspectRatioValue ? this.aspectRatioValue : Number.NaN"
    assert_includes crop_controller, 'this.cropperSelection().$toCanvas(this.canvasOptions())'
    assert_includes crop_controller, "if (this.hasOutputWidthValue) options.width = this.outputWidthValue"
    assert_includes crop_controller, "if (this.hasOutputHeightValue) options.height = this.outputHeightValue"
    assert_includes crop_controller, "this.validateConfiguration()"
    assert_includes crop_controller, "this.allowedTypesValue.includes(file.type)"
    assert_includes crop_controller, "const transfer = new DataTransfer()"
    assert_includes crop_controller, 'document.addEventListener("turbo:before-cache", this.beforeCache)'
    assert_includes crop_controller, "this.cropper?.destroy()"
    assert_includes crop_system_test, "crops a rectangular image to a 512 pixel square before upload"
    assert_includes crop_system_test, "supports configured and free aspect ratios"
    assert_includes crop_system_test, 'element.removeAttribute("data-image-crop-aspect-ratio-value")'
    assert_includes crop_system_test, 'assert_equal [640, 360], selected_image_dimensions'
    assert_includes crop_system_test, 'assert_equal [240, 120], selected_image_dimensions'
    assert_includes crop_system_test, "keeps the last confirmed crop when replacements are dismissed"
    assert_includes crop_system_test, "page.send_keys(:escape)"
    assert_includes crop_system_test, "playwright_page.mouse.click(5, 5)"
    assert_includes crop_system_test, "keeps the last confirmed crop when image conversion fails"
    assert_includes crop_system_test, "HTMLCanvasElement.prototype.toBlob = function(callback) { callback(null) }"
    assert_includes crop_system_test, 'assert_equal [512, 512], metadata.values_at("width", "height")'
    refute_includes profile_configuration, "boring_avatar_seed"
    assert_includes @source, 'assert_equal profile.screen_name.camelize, profile.display_name'
  end

  def test_configures_active_storage_proxy_delivery_without_imgproxy
    delivery = source_between("def configure_image_delivery", "def install_action_text")
    action_text_test = generated_file_source("test/controllers/pages_controller_test.rb")
    delivery_test = generated_file_source("test/integration/image_delivery_test.rb")

    assert_includes delivery, "config.active_storage.variant_processor = :vips"
    assert_includes delivery, "config.active_storage.track_variants = true"
    assert_includes delivery, "config.active_storage.resolve_model_to_route = :rails_storage_proxy"
    assert_includes action_text_test, "keeps Action Text image attachments separate from the avatar policy"
    assert_includes action_text_test, "/rails/active_storage/representations/proxy/"
    assert_includes delivery_test, "rails_storage_proxy_path(variant)"
    assert_includes delivery_test, 'response.headers.fetch("cache-control")'
    assert_includes delivery_test, 'assert_includes response.headers.fetch("cache-control"), "public"'
    assert_includes delivery_test, 'assert_includes response.headers.fetch("cache-control"), "immutable"'
    assert_includes delivery_test, "assert_no_difference"
    assert_includes @source, "ActiveStorageDB::File.find_by!(ref: variant.image.blob.key)"
    assert_includes @source, "assert_equal variant.image.blob.download, stored_variant.data"
    refute_includes @source, "imgproxy"
    refute_includes @source, "IMGPROXY"
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
    database_configuration = source_between("def configure_database", "def kamal_restore_cli_body")

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
    assert_includes database_configuration, '"/rails/storage/production_storage.sqlite3"'
    refute_includes database_configuration, "STORAGE_DATABASE_PATH"
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

  def test_kamal_uses_a_litestream_accessory_and_confirmed_restore
    kamal = source_between("def configure_kamal", "after_bundle do")
    restore = source_between("def kamal_restore_cli_body", "def configure_kamal_restore")
    volume_helper = source_between("def configure_kamal_restore", "def configure_litestream_r2")
    r2 = source_between("def configure_litestream_r2", "def configure_kamal")

    assert_includes @source, 'gem "kamal", "~> 2.11", require: false'
    assert_includes kamal, "minimum_version: 2.11.0"
    assert_includes kamal, "litestream/litestream:0.5.15"
    assert_includes kamal, '"restore-if-db-not-exists" => true'
    assert_includes kamal, '"type" => "s3"'
    assert_includes kamal, '"endpoint" => "$" + "{CF_ACCOUNT_ID}.r2.cloudflarestorage.com"'
    assert_includes kamal, '"region" => "auto"'
    assert_includes kamal, '"#{app_id}_<%= ENV.fetch(\\"KAMAL_DESTINATION\\") %>_storage:/rails/storage"'
    assert_includes kamal, "require_destination: true"
    assert_includes kamal, 'create_file ".kamal/secrets-common"'
    assert_includes kamal, 'remove_file ".kamal/secrets"'
    assert_includes kamal, 'create_file "config/deploy.production.yml"'
    assert_includes kamal, 'create_file "config/deploy.staging.yml"'
    refute_match(/AWS_ACCESS_KEY_ID|AWS_SECRET_ACCESS_KEY|LITESTREAM_STORAGE_REPLICA_URL/, kamal)
    assert_includes kamal, 'cmd: bin/jobs --mode async'
    assert_includes kamal, 'GET /status HTTP/1.0'
    assert_includes kamal, 'CMD ["./bin/thrust", "./bin/rails", "server"]'
    assert_includes kamal, 'create_file ".kamal/hooks/pre-deploy"'
    refute_includes kamal, "Procfile.prod"
    refute_includes kamal, "foreman"
    refute_includes kamal, "THRUSTER_HTTP_PORT"
    refute_includes kamal, "THRUSTER_TARGET_PORT"

    assert_includes restore, 'option_parser.on("--plan")'
    assert_includes restore, 'option_parser.on("--timestamp=RFC3339")'
    assert_includes restore, 'option_parser.on("--rollback=OPERATION_ID")'
    assert_includes restore, 'option_parser.on("--destination=DESTINATION")'
    assert_includes restore, 'unless @input.tty? && @output.tty?'
    assert_includes restore, 'confirm!("RESTORE #{APP_ID} #{@destination} #{target}")'
    assert_includes restore, '@runner.run!(*arguments, "-d", @destination)'
    assert_includes restore, '"-integrity-check", "full"'
    assert_includes restore, '"-dry-run"'
    assert_includes restore, '"lock", "acquire"'
    assert_includes restore, '"app", "maintenance"'
    assert_includes restore, '"litestream", "sync"'
    assert_includes restore, "Shellwords.join"
    refute_includes restore, '"-force"'
    refute_includes restore, "if-replica-exists"
    refute_includes restore, "--yes"

    assert_includes volume_helper, 'SIDECAR_SUFFIXES = ["", "-wal", "-shm", "-journal"]'
    assert_includes volume_helper, "installed.reverse_each"
    assert_includes volume_helper, "moved_previous.reverse_each"
    assert_includes volume_helper, "replaced-by-rollback"

    assert_includes r2, "DESTINATIONS = %w[production staging].freeze"
    assert_includes r2, "Kamal destination"
    assert_includes r2, "selected: DESTINATIONS"
    assert_includes r2, '[@wrangler, "whoami", "--json"]'
    assert_includes r2, '[@wrangler, "r2", "bucket", "info", bucket, "--json"]'
    assert_includes r2, '/\[code: 10006\]/'
    assert_includes r2, '"CLOUDFLARE_ACCOUNT_ID" => account_id'
    assert_includes r2, 'INITIAL_TOKEN_ENV = "CLOUDFLARE_INITIAL_API_TOKEN"'
    assert_includes r2, '"key" => "account_api_tokens", "type" => "edit"'
    assert_includes r2, 'INITIAL_TOKEN_PERMISSION_GROUP_NAME = "Account API Tokens Write"'
    assert_includes r2, 'ACCOUNT_SCOPE = "com.cloudflare.api.account"'
    assert_includes r2, 'R2_PERMISSION_GROUP_NAME = "Workers R2 Storage Bucket Item Write"'
    assert_includes r2, 'R2_BUCKET_SCOPE = "com.cloudflare.edge.r2.bucket"'
    assert_includes r2, '"/accounts/#{account_id}/tokens/verify"'
    assert_includes r2, '"/accounts/#{account_id}/tokens/#{token_id}"'
    assert_includes r2, '"/accounts/#{account_id}/tokens/permission_groups"'
    assert_includes r2, '"/accounts/#{account_id}/tokens"'
    assert_includes r2, 'validate_cloudflare_initial_token!(account)'
    assert_includes r2, 'class RequestError < Error'
    assert_includes r2, 'Digest::SHA256.hexdigest(token_value)'
    assert_includes r2, '["CLOUDFLARE_R2_API_TOKEN", *DEPLOY_SECRET_FIELDS].freeze'
    refute_includes r2, 'password: true'
    assert_includes r2, 'stdin_data: JSON.generate(item)'
    assert_includes r2, 'default: false'
    assert_includes r2, '%w[op user get --me --format=json]'
    assert_includes r2, '%W[op account get --format=json --account=#{service_account_id}]'
    assert_includes r2, '%W[op service-account create #{name}]'
    assert_includes r2, '"#{record_name(vault)}:read_items,write_items"'
    refute_includes r2, '--can-create-vaults'
    assert_includes r2, '%W[mise set --file #{@mise_local} --stdin OP_SERVICE_ACCOUNT_TOKEN]'
    assert_includes r2, '%W[op vault create #{name} --format=json]'
    refute_includes r2, '%W[op vault create #{name} --format=json --account=#{service_account_id}]'
    assert_includes r2, '"#{normalized_app_id(app_id)}-#{destination}"'
    assert_includes r2, 'stdin_data: token.dup'
    refute_includes kamal, 'append_to_file ".gitignore", "\n/mise.local.toml\n"'
    assert_includes kamal, "mise exec -- bin/kamal setup -d production"
    refute_includes r2, "1Password account/vault"
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
    evidence_capture = source_between("  runner = <<~'RUBY'", "\n  RUBY\n  runner = runner.sub")
    default_page_seeds = source_between("    default_page_contents = {", "    FooterSetting.find_or_create_by!")

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
    assert_equal 2, default_page_seeds.scan('"corp" => <<~HTML').size
    assert_equal 2, default_page_seeds.scan('"terms" => <<~HTML').size
    assert_equal 2, default_page_seeds.scan('"privacy" => <<~HTML').size
    assert_equal 2, default_page_seeds.scan('"transaction-law" => <<~HTML').size
    assert_includes default_page_seeds, "}.fetch(I18n.default_locale)"
    assert_includes default_page_seeds, 'page.content = default_page_contents.fetch(slug) if page.new_record? && default_page_contents.key?(slug)'
    refute_includes default_page_seeds, "page.content.blank?"
    assert_includes default_page_seeds, '<th class="lexxy-content__table-cell--header"><p>運営者名</p></th><td><p>株式会社◯◯</p></td>'.b
    assert_includes default_page_seeds, '<th class="lexxy-content__table-cell--header"><p>Operator name</p></th><td><p>Example Co., Ltd.</p></td>'
    assert_equal 8, default_page_seeds.scan('class="lexxy-content__table-cell--header"').size
    refute_includes default_page_seeds, 'scope="row"'
    assert_includes default_page_seeds, "第5条（禁止事項）".b
    assert_includes default_page_seeds, "5. Prohibited conduct"
    assert_includes default_page_seeds, "3. 利用目的".b
    assert_includes default_page_seeds, "3. Purposes of use"
    assert_includes default_page_seeds, "販売事業者".b
    assert_includes default_page_seeds, "Seller or Service Provider"
    assert_equal 1, @source.scan('"company" => "運営者情報"'.b).size
    assert_equal 1, @source.scan('"company" => "Operator information"').size
    assert_equal 1, @source.scan('"corp" => "運営者情報"'.b).size
    assert_equal 1, @source.scan('"corp" => "Operator information"').size
    refute_includes @source, '"company" => "運営会社"'.b
    refute_includes @source, '"corp" => "運営会社"'.b
    refute_includes @source, '"company" => "Company"'
    refute_includes @source, '"corp" => "Company"'
    assert_includes evidence_capture, '<th class="lexxy-content__table-cell--header"><p>運営者名</p></th><td><p>株式会社◯◯</p></td>'.b
    assert_includes evidence_capture, 'assert_operator_information_table(viewport)'
    assert_includes evidence_capture, 'assert_operator geometry.fetch("documentWidth"), :<=, geometry.fetch("viewportWidth")'
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

    assert_equal %w[#ffffff #3ea8ff #f1f5f9 #0f83fd #d6e3ed], palette
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
    assert_operator after_bundle.index("configure_kamal"),
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

  def test_installs_sorbet_and_checks_types_and_rbi_files_in_the_regular_test_suite
    sorbet_test = generated_file_source("test/sorbet_test.rb")
    shim = generated_file_source("sorbet/rbi/shims/framework_bindings.rbi")
    bundler_connection_pool_shim = generated_file_source("sorbet/rbi/shims/bundler_connection_pool.rbi")
    application_typechecking = source_between("def configure_application_typechecking", "def configure_config_typechecking")
    config_typechecking = source_between("def configure_config_typechecking", "def configure_sorbet_shims")
    shim_configuration = source_between("def configure_sorbet_shims", "def configure_database")
    after_bundle = @source.byteslice(@source.index("after_bundle do")..)
    development_gems = source_between("gem_group :development do", "gem_group :development, :test do")
    development_and_test_gems = source_between("gem_group :development, :test do", "gem_group :test do")

    assert_includes @source, 'gem "sorbet-runtime"'
    assert_includes development_gems, 'gem "sorbet", require: false'
    assert_includes development_and_test_gems, 'gem "tapioca", require: false'
    assert_includes after_bundle, "configure_sorbet"
    assert_operator after_bundle.index('run_checked "bin/annotaterb models"'),
      :<, after_bundle.index("configure_config_typechecking")
    assert_operator after_bundle.index("configure_config_typechecking"),
      :<, after_bundle.index('run_checked "bundle exec tapioca init"')
    assert_operator after_bundle.index('run_checked "bundle exec tapioca init"'),
      :<, after_bundle.index('append_to_file "sorbet/tapioca/require.rb"')
    assert_includes after_bundle, 'require "action_mailer"'
    assert_includes after_bundle, 'require "mail"'
    assert_operator after_bundle.index('append_to_file "sorbet/tapioca/require.rb"'),
      :<, after_bundle.index('run_checked "bin/tapioca gem action_policy actionmailer browser mail webauthn"')
    assert_operator after_bundle.index('run_checked "bin/tapioca gem action_policy actionmailer browser mail webauthn"'),
      :<, after_bundle.index('run_checked "RAILS_ENV=test bin/rails db:prepare"')
    assert_includes after_bundle, 'require "webauthn/fake_client"'
    assert_operator after_bundle.index('run_checked "bundle exec tapioca init"'),
      :<, after_bundle.index('append_to_file "sorbet/config"')
    assert_operator after_bundle.index('append_to_file "sorbet/config"'),
      :<, after_bundle.index('run_checked "RAILS_ENV=test bin/rails db:prepare"')
    assert_includes after_bundle, "--suppress-payload-superclass-redefinition-for=Net::IMAP::Literal"
    assert_includes after_bundle, "--suppress-payload-superclass-redefinition-for=Net::IMAP::QuotedString"
    assert_operator after_bundle.index('run_checked "RAILS_ENV=test bin/rails db:prepare"'),
      :<, after_bundle.index('run_checked "RAILS_ENV=test bin/tapioca dsl --environment=test"')
    assert_operator after_bundle.index('run_checked "RAILS_ENV=test bin/tapioca dsl --environment=test"'),
      :<, after_bundle.index("configure_application_typechecking")
    assert_operator after_bundle.index("configure_application_typechecking"),
      :<, after_bundle.index("configure_sorbet_shims")
    assert_operator after_bundle.index("configure_sorbet_shims"),
      :<, after_bundle.index('remove_file "sorbet/rbi/todo.rbi"')
    assert_operator after_bundle.index('remove_file "sorbet/rbi/todo.rbi"'),
      :<, after_bundle.index('run_checked "bin/tapioca gems --verify"')
    assert_operator after_bundle.index('run_checked "bin/tapioca gems --verify"'),
      :<, after_bundle.index('run_checked "RAILS_ENV=test bin/tapioca dsl --verify --environment=test"')
    assert_operator after_bundle.index('run_checked "RAILS_ENV=test bin/tapioca dsl --verify --environment=test"'),
      :<, after_bundle.index('run_checked "bin/tapioca check-shims"')
    assert_operator after_bundle.index('run_checked "bin/tapioca check-shims"'),
      :<, after_bundle.index('run_checked "bundle exec srb tc"')
    assert_includes sorbet_test, '"bin/tapioca", "gems", "--verify"'
    assert_includes sorbet_test, '"bin/tapioca", "dsl", "--verify", "--environment=test"'
    assert_includes sorbet_test, '{ "RAILS_ENV" => "test" }'
    assert_includes sorbet_test, '"bin/tapioca", "check-shims"'
    assert_includes sorbet_test, '"bundle", "exec", "srb", "tc"'
    assert_includes sorbet_test, "TYPED_RUBY_PATTERNS"
    assert_includes sorbet_test, "STRICT_RUBY_PATHS"
    assert_includes sorbet_test, "APPLICATION_DSL_RBI_SOURCES"
    assert_includes sorbet_test, 'assert_match(/\\A# typed: (?:true|strict)\\n\\z/'
    assert_includes sorbet_test, 'assert_equal "# typed: strict\\n"'
    assert_includes sorbet_test, 'assert_not_predicate todo, :exist?'
    %w[
      api_credential
      application_mailer
      faq
      footer_setting
      page
      profile
      push_notification_job
      push_subscription
      siwe_challenge
      siwe_identity
      user
      user_role
    ].each do |dsl_rbi|
      assert_includes sorbet_test, %Q{"#{dsl_rbi}" =>}
    end
    assert_includes sorbet_test, 'assert_path_exists Rails.root.join("sorbet/rbi/dsl/#{name}.rbi")'
    %w[app/controllers app/helpers app/models app/policies app/services app/jobs app/mailers app/tasks app/validators config lib test].each do |directory|
      assert_includes application_typechecking, "#{directory}/**/*.rb"
    end
    assert_includes application_typechecking, "db/seeds.rb"
    assert_includes application_typechecking, 'strictness = strict_paths.include?(path) ? "strict" : "true"'
    assert_includes application_typechecking, 'prepend_to_file path, "# typed: #{strictness}\\n"'
    assert_includes config_typechecking, 'prepend_to_file "config/puma.rb", "T.bind(self, Puma::DSL)'
    assert_includes config_typechecking, 'prepend_to_file "config/importmap.rb", "T.bind(self, Importmap::Map)'
    assert_includes config_typechecking, 'node.receiver.name == :CI'
    assert_includes config_typechecking, '"ActiveSupport::ContinuousIntegration"'
    assert_includes config_typechecking, 'T.bind(self, ActiveSupport::ContinuousIntegration)'
    assert_includes shim, "class Rails::Application"
    assert_includes shim, "def self.config_for(name, env: T.unsafe(nil)); end"
    assert_includes shim, "class ActiveRecord::Base"
    assert_includes shim, "extend Devise::Models"
    assert_includes shim, "class ActiveSupport::TestCase"
    assert_includes shim, "include ActiveRecord::TestFixtures"
    assert_includes shim, "class ActionDispatch::SystemTestCase"
    assert_includes shim, "include GeneratedPathHelpersModule"
    assert_includes shim, "class ApplicationController"
    assert_includes shim, "include ActionPolicy::Controller"
    assert_includes shim, "class DeviseController < ActionController::Base"
    assert_includes shim, "include Devise::Controllers::SignInOut"
    assert_includes shim, "module ApplicationHelper"
    assert_includes shim, "module ApplicationHelper::ApplicationRoutes"
    assert_includes shim, "include GeneratedUrlHelpersModule"
    assert_includes shim, "include GeneratedPathHelpersModule"
    assert_includes shim_configuration, "module AvatarHelper"
    assert_includes shim_configuration, 'create_file "sorbet/rbi/shims/boring_avatars.rbi"'
    assert_includes shim_configuration, "BoringAvatars::RailsAttributeValue"
    assert_includes shim_configuration, 'create_file "sorbet/rbi/shims/bundler_connection_pool.rbi"'
    assert_includes bundler_connection_pool_shim, "class ConnectionPool"
    assert_includes bundler_connection_pool_shim, "module ForkTracker; end"
    assert_includes shim_configuration, "module Admin::MaintenanceTasksHelper"
    assert_includes shim_configuration, "job_operations_bindings = if VALUES.fetch(\"job_operations\") == \"enable\""
    assert_includes shim_configuration, "module Admin::JobOperationsHelper"
    assert_includes shim_configuration, "include MissionControl::Jobs::ApplicationHelper"
    assert_includes @source, "T.bind(self, Admin::MaintenanceTasksController)"
    assert_includes @source, '"triggered_by_user_id" => T.must(authorization_user).id'
    assert_includes shim, "class User"
    assert_includes shim, "include Devise::Models::Authenticatable"
    refute_includes shim, "include Devise::Models::DatabaseAuthenticatable"
    refute_includes shim, "def password; end"
    assert_includes shim, "class UserPolicy"
    assert_includes shim, ".bind(UserPolicy)"
    assert_includes shim, "User::PrivateRelation"
    assert_includes sorbet_test, "assert status.success?"
  end

  def test_adds_inline_signatures_to_domain_public_apis
    user = generated_file_source("app/models/user.rb")
    challenge = generated_file_source("app/models/siwe_challenge.rb")
    notifier = generated_file_source("app/services/push_notifier.rb")
    job = generated_file_source("app/jobs/push_notification_job.rb")
    identity = generated_file_source("lib/application_identity.rb")

    [challenge, notifier, job, identity].each do |source|
      assert_includes source, "extend T::Sig"
    end
    assert_includes @source, "extend T::Sig"
    assert_includes @source, "sig { params(role: T.any(String, Symbol)).returns(T::Boolean) }"
    assert_includes @source, "T::Sig::WithoutRuntime.sig { returns(T::Boolean) }"
    assert_includes challenge, ").returns([SiweChallenge, String])"
    assert_includes notifier, "user: T.nilable(User)"
    assert_includes job, "tag: T.nilable(String)"
    refute_includes job, "T.untyped"
    assert_includes identity, "configuration: T::Hash[Symbol, T.nilable(String)]"
    assert_includes identity, "environment: T::Hash[String, String]"
    assert_includes identity, "returns(T::Hash[Symbol, T.any(String, Integer)])"
  end

  def test_generates_deterministic_playwright_evidence_capture
    evidence = source_between("def configure_evidence_capture", "def configure_annotaterb").force_encoding(Encoding::UTF_8)
    common_files = source_between("def configure_common_files", "def configure_evidence_capture").force_encoding(Encoding::UTF_8)
    update_evidence = File.binread(File.expand_path("../../bin/update-evidence", __dir__))

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
    assert_includes evidence, 'browser_post_json('
    assert_includes evidence, '"/users/sign_in/siwe/challenge"'
    assert_includes evidence, "credentials: 'same-origin'"
    assert_includes evidence, 'page.current_window.resize_to(viewport.fetch("width"), viewport.fetch("height"))'
    assert_includes evidence, 'assert_default_outline_button_colors("#notifications-popover .btn.btn-outline")'
    assert_includes evidence, 'borderProbe.style.border = "1px solid var(--color-base-300)"'
    assert_includes evidence, 'textProbe.style.color = "var(--color-base-content)"'
    assert_includes evidence, 'assert_equal colors.fetch("expectedBorder"), colors.fetch("border")'
    assert_includes evidence, 'assert_equal colors.fetch("expectedText"), colors.fetch("text")'
    assert_includes evidence, 'login_as(@user, scope: :user)'
    assert_includes evidence, '"passkey-registration-risk-warning"'
    assert_includes evidence, '"passkeys-multiple"'
    assert_includes evidence, '"passkey-delete-reauth"'
    assert_includes evidence, '"account-delete-reauth"'
    assert_includes evidence, '"siwe-login-unregistered-wallet"'
    assert_includes evidence, 'translate("siwe.errors.wallet_not_registered")'
    assert_includes evidence, 'defaultBackupEligibility: backup_eligible'
    assert_includes evidence, 'defaultBackupState: backup_state'
    refute_includes evidence, 'User.human_attribute_name(:login_id)'
    refute_includes evidence, 'User::LOGIN_ID_BYTES'
    refute_includes evidence, 'User.human_attribute_name(:password)'
    assert_includes evidence, '"api-credential-secret"'
    assert_includes evidence, 'assert_selector ".alert.alert-warning.alert-soft", count: 1'
    assert_includes evidence, "def with_deterministic_secure_random"
    assert_includes evidence, "T.must(singleton_class).define_method(:urlsafe_base64, T.must(original_method))"
    assert_includes evidence, '"navigation-authenticated-open"'
    assert_includes evidence, '"about"'
    assert_includes evidence, '"faq"'
    assert_includes evidence, '"admin-page-edit"'
    assert_includes evidence, '"admin-faqs"'
    assert_includes evidence, '"admin-faq-edit"'
    assert_includes evidence, '"admin-footer-setting"'
    assert_includes evidence, '"admin-maintenance-task-paused"'
    assert_includes evidence, '"admin-maintenance-task-errored"'
    assert_includes evidence, 'assert_selector ".alert.alert-error.alert-soft", text: "Evidence task failure", count: 1'
    assert_includes evidence, 'assert_button "Pause"'
    assert_includes evidence, 'assert_button "Resume"'
    assert_includes evidence, 'assert_button "Cancel"'
    assert_includes evidence, '"admin-notifications"'
    assert_includes evidence, '"admin-notification-show"'
    assert_includes evidence, '"admin-notification-edit"'
    assert_includes evidence, 'raise "全体通知に個別配信行が作成されました" if announcement.notification_deliveries.exists?'
    assert_includes evidence, '"notifications-popover-announcements"'
    assert_includes evidence, '"notifications-announcements"'
    assert_source_order(evidence,
      '"notifications-popover-unread"',
      '"notifications-popover-announcements"',
      '"notifications-history"',
      '"notifications-announcements"',
      'within("#notifications-popover") { click_button translate("notifications.open_all") }',
      '"notifications-popover-opened"')
    assert_includes evidence, "[320, 390, 640, 960, 961].each do |width|"
    assert_includes evidence, '"Notification tabs wrapped at #{width}px"'
    assert_includes evidence, '"Active notification tab is detached from its panel at #{width}px"'
    assert_includes evidence, '"admin-overview"'
    assert_includes evidence, '"admin-users"'
    assert_includes evidence, '"admin-user-show"'
    assert_includes evidence, '"admin-user-edit"'
    assert_includes evidence, "form[action='\#{admin_user_path(@regular_user)}'] input[name='profile[display_name]']"
    assert_includes evidence, 'dismiss_confirm { click_button translate("admin.users.grant") }'
    assert_includes evidence, 'accept_confirm { click_button translate("admin.users.grant") }'
    assert_includes evidence, 'accept_confirm { click_button translate("admin.users.revoke") }'
    assert_includes evidence, "def assert_admin_overview_geometry"
    assert_includes evidence, 'document.querySelector("[data-admin-overview-stats]")'
    assert_includes evidence, 'assert_equal(viewport == "mobile" ? 1 : 3, geometry.fetch("columnCount"))'
    assert_includes evidence, 'text: translate("navigation.admin"), count: 2, visible: :all'
    assert_includes evidence, 'assert_no_selector %(header a[href="#{host_routes.admin_root_path}"]), visible: :all'
    assert_includes evidence, '"web-push-enabled"'
    assert_includes evidence, 'set_evidence_web_push_mode("granted")'
    assert_includes evidence,
      'assert_selector ".alert.alert-info.alert-soft", text: translate("api_credentials.empty"), count: 1'
    assert_includes evidence,
      'assert_selector ".alert.alert-success.alert-soft", text: translate("passkeys.updated"), count: 1'
    assert_includes evidence,
      'assert_selector ".alert.alert-success.alert-soft", text: translate("siwe.identities.updated"), count: 1'
    assert_includes evidence, '[data-push-subscription-target="status"].alert-success.alert-soft'
    assert_includes evidence, '[data-push-subscription-target="status"].alert-info.alert-soft'
    assert_includes evidence, "def reconnect_web_push_controller"
    assert_includes evidence, "playwright_page.evaluate(script)"
    assert_includes evidence, '[data-push-subscription-target="toggle"]:not([disabled])'
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
    assert_includes evidence, "def verify_with_menu_layout_geometry"
    assert_includes evidence, "def verify_page_actions_geometry"
    assert_includes evidence, "def verify_pagination_geometry"
    assert_includes evidence, '@pagination_users = 48.times.map { User.create! } if @pagination_users.nil?'
    assert_includes evidence, 'const nav = document.querySelector(\'nav[aria-label="#{translate("admin.users.pagination")}"]\')'
    assert_includes evidence, 'assert_equal 5, geometry.fetch("directItemCount")'
    assert_includes evidence, 'assert_equal geometry.fetch("childCount"), geometry.fetch("directItemCount")'
    assert_includes evidence, 'assert_equal 1, geometry.fetch("rowCount")'
    assert_includes evidence, 'assert_equal 1, geometry.fetch("fontSizes").length'
    assert_includes evidence, "def assert_standard_button_size_modifiers"
    assert_includes evidence, 'default: "btn"'
    assert_includes evidence, 'small: "btn btn-sm"'
    assert_includes evidence, 'extraSmall: "btn btn-xs"'
    assert_includes evidence, 'assert_operator sizes.fetch("default"), :>, sizes.fetch("small")'
    assert_includes evidence, 'assert_operator sizes.fetch("small"), :>, sizes.fetch("extraSmall")'
    assert_includes evidence, "def assert_standard_card_border_colors"
    assert_includes evidence, 'normal.className = "card card-border bg-base-100"'
    assert_includes evidence, 'error.className = "card card-border border-error bg-base-100"'
    assert_includes evidence, 'assert_equal styles.fetch("expectedNormalColor"), styles.fetch("normalColor")'
    assert_includes evidence, 'assert_equal styles.fetch("expectedErrorColor"), styles.fetch("errorColor")'
    assert_includes evidence, 'actionButtonsUseDefaultSize:'
    assert_includes evidence, 'assert failed_geometry.fetch("actionButtonsUseDefaultSize")'
    assert_includes evidence, 'assert_equal 1, failed_geometry.fetch("actionButtonFontSizes").length'
    assert_includes evidence, 'assert_equal 2, geometry.fetch("iconCount")'
    assert_includes evidence, 'assert_equal "auto", geometry.fetch("navOverflowX")'
    assert_includes evidence, 'assert_in_delta geometry.fetch("navRight"), geometry.fetch("toolbarRight"), 1'
    assert_includes evidence, "prepare_job_operations_data if JOB_OPERATIONS"
    assert_includes evidence, "class EvidenceFailedJob < ApplicationJob"
    assert_includes evidence, 'data-page-actions-container="card"'
    assert_includes evidence, 'data-page-actions-container="tab"'
    assert_includes evidence, 'actionColumnCount: getComputedStyle(actions).gridTemplateColumns.split(" ").length'
    assert_includes evidence, '{ "account" => account_path, "admin" => admin_root_path }.each'
    assert_includes evidence, "[320, 390, 640, 960, 961].each"
    assert_includes evidence, "visit path"
    assert_includes evidence, '"#{area} with-menu should use a horizontal menu at #{width}px"'
    assert_includes evidence, '"#{area} with-menu mobile category should be visible at #{width}px"'
    assert_includes evidence, '"#{area} with-menu category should remain fixed while scrolling at #{width}px"'
    assert_includes evidence, '"#{area} with-menu should be horizontally scrollable at #{width}px"'
    assert_includes evidence, '"#{area} with-menu should use a vertical menu at #{width}px"'
    assert_includes evidence, '"#{area} with-menu layout should use one column at #{width}px"'
    assert_includes evidence, '"#{area} with-menu layout should use two columns at #{width}px"'
    assert_includes evidence, "def assert_admin_navigation_active"
    assert_includes evidence, 'text: translate("navigation.dashboard"), count: 2, visible: :all'
    assert_includes evidence, "assert_equal account_path, URI.parse(admin_links.last[:href]).path"
    assert_includes evidence, "def assert_account_navigation_scope"
    assert_includes evidence, 'translate("navigation.account_menu")'
    assert_includes evidence, 'translate("navigation.admin_menu")'
    assert_includes evidence, 'SCENARIO_SET = "full"'
    assert_includes evidence, "capture_common_scenarios"
    assert_includes evidence, 'capture_siwe_scenarios if ADDITIONAL_LOGIN_METHODS.include?("siwe")'
    assert_includes evidence, 'capture_current_page("siwe-provider-picker", "EVMウォレット選択", viewport_name)'
    assert_includes evidence, 'text: "MetaMask", count: 1'
    assert_includes evidence, 'text: "Rabby Wallet", count: 1'
    assert_includes evidence, "capture_avatar_scenarios if AVATAR"
    assert_includes evidence, "def capture_avatar_page"
    assert_includes evidence, "perform_enqueued_jobs(only: ActiveStorage::TransformJob)"
    assert_includes evidence, "avatar image failed: expected"
    assert_includes evidence, 'Object.const_get("AvatarTestImage")'
    assert_includes evidence, 'capture_current_page("profile-avatar-crop-modal", "プロフィール画像の切り抜き", viewport)'
    assert_includes evidence, "def assert_avatar_crop_modal_geometry"
    assert_includes evidence, 'assert_equal({ "width" => 512, "height" => 512, "type" => "image/png" }, cropped)'
    assert_includes evidence, '[320, 390, 640, 960, 961].each'
    assert_includes update_evidence, 'run!(File.join(SAMPLE, "bin/rails"), "test:system", chdir: SAMPLE)'
    refute_includes evidence, "capture_siwe_delta"
    refute_includes evidence, "capture_avatar_delta"
    assert_includes evidence, 'runner = runner.sub("__ADDITIONAL_LOGIN_METHODS__", additional_login_methods.inspect)'
    assert_includes evidence, 'runner = runner.sub("__AVATAR__", avatar.inspect)'
    assert_includes evidence, 'runner = runner.sub("__WEB_PUSH__", web_push.inspect)'
    assert_includes evidence, 'runner = runner.sub("__JOB_OPERATIONS__", job_operations.inspect)'
    assert_includes evidence, 'runner = runner.sub("__MAINTENANCE_TASKS__", maintenance_tasks.inspect)'
    assert_includes evidence, "disabled_constants = []"
    assert_includes evidence, "node.is_a?(Prism::IfNode)"
    assert_includes evidence, "node.location.start_line - 1"
    assert_includes evidence, "removed_lines = Array.new(runner.lines.length, false)"
    assert_includes evidence, "runner.lines.each_with_index.filter_map"
    assert_includes evidence, '"admin-job-operations"'
    assert_includes evidence, '"admin-job-operations-failed"'
    assert_includes evidence, '"admin-job-operations-navigation-open"'
    assert_includes evidence, '"navigation-regular-user"'
    assert_includes evidence, 'viewport_size = VIEWPORTS.fetch(viewport)'
    assert_includes evidence, "def verify_job_operations_geometry"
    assert_includes evidence, 'failed_title = translate("job_operations.titles.status_jobs.failed")'
    assert_includes evidence, 'text: /^#{Regexp.escape(failed_title)}/'
    assert_includes evidence, 'geometry.fetch("tabContentCount")'
    assert_includes evidence, 'failed_geometry.fetch("tabContentRadius")'
    assert_includes evidence, "REGULAR_PRIVATE_KEY"
    assert_includes evidence, 'visit host_routes.admin_jobs_path'
    assert_includes evidence, '"admin-maintenance-tasks"'
    assert_includes evidence, '"admin-maintenance-tasks-navigation-open"'
    assert_includes evidence, "def verify_maintenance_tasks_geometry"
    assert_includes evidence, "[320, 390, 640, 960, 961].each"
    assert_includes evidence, 'visit host_routes.admin_maintenance_tasks_path'
    assert_includes evidence, 'find("details.collapse", text: "Source code").find("summary").click'
    assert_includes evidence, 'code_lines = all(".mockup-code > pre")'
    assert_includes evidence, 'code_lines.pluck("data-prefix")'
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
    with_menu_layout = generated_file_source("app/views/layouts/_with_menu.html.erb")
    account_layout = generated_file_source("app/views/layouts/_account_shell.html.erb")
    admin_layout = generated_file_source("app/views/layouts/admin.html.erb")
    admin_navigation = source_between(
      "  admin_navigation_items = <<~ERB",
      '  signed_in_condition = "user_signed_in?"'
    )
    authentication_layout = generated_file_source("app/views/layouts/authentication.html.erb")
    home = generated_file_source("app/views/home/index.html.erb")
    login = generated_file_source("app/views/users/passkey_sessions/new.html.erb")
    registration = generated_file_source("app/views/users/passkey_registrations/new.html.erb")
    account_navigation = source_between(
      "  account_navigation_items = <<~ERB",
      "  admin_navigation_items = <<~ERB"
    )

    assert_class_tokens header, "navbar", "mx-auto", "w-full", "max-w-6xl", "px-5"
    assert_class_tokens header, "dropdown", "dropdown-end", "dropdown-hover"
    assert_class_tokens header, "menu", "menu-sm", "dropdown-content"
    ghost_controls = header.scan(/<(?:button|summary)\b[^>]*class="[^"]*\bbtn-ghost\b[^"]*"[^>]*>/)
    assert_equal 1, ghost_controls.size
    ghost_controls.each { |control| assert_includes control, "aria-label=" }
    assert_includes @source, '<summary class="btn btn-circle btn-ghost" aria-label='
    assert_includes header, 'class="btn btn-outline"'
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

    assert_class_tokens with_menu_layout, "mx-auto", "w-full", "max-w-6xl", "px-5"
    assert_class_tokens with_menu_layout, "min-w-0", "h-fit"
    assert_includes with_menu_layout, 'data-layout="with-menu"'
    assert_includes with_menu_layout, 'min-[961px]:grid-cols-[220px_minmax(0,1fr)]'
    assert_includes with_menu_layout, '<%= yield :with_menu_navigation %>'
    assert_includes with_menu_layout, '<% page_content = yield %>'
    assert_includes with_menu_layout, '<h1 class="mb-6 text-2xl font-bold leading-[1.5]"><%= content_for(:page_title) %></h1>'
    assert_includes with_menu_layout, '<%= page_actions(card: true) unless content_for?(:page_actions_in_tab) %>'
    assert_includes with_menu_layout, '<%= page_content %>'
    assert_operator with_menu_layout.index("page_content = yield"), :<, with_menu_layout.index("content_for(:page_title)")
    assert_operator with_menu_layout.index("content_for(:page_title)"), :<, with_menu_layout.index("page_actions(card: true)")
    assert_operator with_menu_layout.index("page_actions(card: true)"), :<, with_menu_layout.index("<%= page_content %>")
    refute_includes with_menu_layout, "with_menu_subnavigation"
    refute_includes with_menu_layout, "tab-content"
    assert_includes with_menu_layout, '<% content_for :content, flush: true do %>'
    assert_includes with_menu_layout, '<%= render template: "layouts/application" %>'
    %w[account admin controller_path layout_name].each { |consumer_detail| refute_includes with_menu_layout, consumer_detail }

    assert_class_tokens account_layout, "menu", "menu-horizontal", "min-[961px]:menu-vertical"
    assert_class_tokens account_layout, "w-max", "min-w-full", "min-[961px]:w-full"
    assert_class_tokens account_layout, "overflow-x-auto", "min-[961px]:overflow-visible"
    assert_class_tokens account_layout, "menu-title", "max-[961px]:hidden"
    assert_includes account_layout, "data-with-menu-mobile-category"
    assert_includes account_layout, "data-with-menu-scroll"
    assert_includes account_layout, "data-with-menu-items"
    assert_includes account_layout, '<% content_for :with_menu_navigation, flush: true do %>'
    assert_includes account_layout, '<%= render "shared/account_navigation" %>'
    assert_includes account_layout, '<%= render layout: "layouts/with_menu" do %>'
    refute_includes account_layout, "grid-cols"
    assert_class_tokens admin_layout, "menu", "menu-horizontal", "min-[961px]:menu-vertical"
    assert_class_tokens admin_layout, "w-max", "min-w-full", "min-[961px]:w-full"
    assert_class_tokens admin_layout, "overflow-x-auto", "min-[961px]:overflow-visible"
    assert_class_tokens admin_layout, "menu-title", "max-[961px]:hidden"
    assert_includes admin_layout, "data-with-menu-mobile-category"
    assert_includes admin_layout, "data-with-menu-scroll"
    assert_includes admin_layout, "data-with-menu-items"
    assert_includes admin_layout, '<% content_for :with_menu_navigation, flush: true do %>'
    assert_includes admin_layout, '<%= render "shared/admin_navigation" %>'
    assert_includes admin_layout, '<%= render layout: "layouts/with_menu" do %>'
    assert_includes admin_layout, '<%= content_for?(:admin_content) ? yield(:admin_content) : yield %>'
    refute_includes admin_layout, "grid-cols"
    assert_includes admin_layout, "application_translate('navigation.admin_menu')"
    assert_includes admin_layout, 'application_translate("navigation.admin")'
    assert_includes @source, 'layout "admin"'
    assert_includes account_navigation, '"menu-active" if current_page?'
    refute_includes account_navigation, '"bg-base-content text-base-100" if current_page?'
    refute_includes account_navigation, "min-h-11"
    refute_includes account_navigation, "ホームへ戻る".b
    refute_includes account_navigation, "application_routes.root_path"
    assert_equal 6, account_navigation.scan('<svg xmlns="http://www.w3.org/2000/svg" class="size-5"').size
    assert_equal 6, account_navigation.scan('aria-hidden="true" data-slot="icon"').size
    assert_includes account_navigation, "profile_path"
    assert_includes account_navigation, 't("navigation.dashboard")'
    assert_includes account_navigation, 'M17.982 18.725A7.488 7.488 0 0 0 12 15.75'
    assert_includes account_navigation, 'M9.594 3.94c.09-.542.56-.94 1.11-.94'
    assert_includes account_navigation, 'link_to application_routes.web_push_settings_path'
    assert_includes account_navigation, 't("navigation.web_push_settings")'
    assert_includes account_navigation, 'controller_path.in?(["account/passkeys", "account/siwe_identities"])'
    refute_includes account_navigation, "account_siwe_identities_path"
    refute_includes account_navigation, 'M9 12.75 11.25 15 15 9.75'
    refute_includes account_navigation, 'allowed_to?(:index?, User)'
    assert_includes account_navigation, 'allowed_to?(:overview?, User)'
    assert_includes account_navigation, 'application_routes.admin_root_path'
    assert_includes account_navigation, 't("navigation.admin")'
    assert_operator account_navigation.index("application_routes.admin_root_path"), :>,
      account_navigation.index("application_routes.api_credentials_path")
    refute_includes account_navigation, 'admin_users_path'
    refute_includes account_navigation, "admin_pages_path"
    refute_includes account_navigation, "admin_faqs_path"
    refute_includes account_navigation, "edit_admin_footer_setting_path"
    assert_equal 9, admin_navigation.scan('<svg xmlns="http://www.w3.org/2000/svg" class="size-5"').size
    assert_equal 9, admin_navigation.scan('aria-hidden="true" data-slot="icon"').size
    assert_includes admin_navigation, 'application_routes.admin_root_path'
    assert_includes admin_navigation, '"menu-active" if controller_path == "admin/overview"'
    assert_includes admin_navigation, 'application_translate("navigation.overview")'
    assert_includes admin_navigation, '"menu-active" if controller_path.in?(%w[admin/users admin/user_roles])'
    assert_includes admin_navigation, 'application_routes.admin_notifications_path'
    assert_includes admin_navigation, '"menu-active" if controller_path == "admin/pages"'
    assert_includes admin_navigation, '"menu-active" if controller_path == "admin/faqs"'
    assert_includes admin_navigation, '"menu-active" if controller_path == "admin/footer_settings"'
    assert_includes admin_navigation, "application_routes.admin_users_path"
    assert_includes admin_navigation, "application_routes.admin_jobs_path"
    assert_includes admin_navigation, '"menu-active" if controller_path.start_with?("mission_control/jobs/")'
    assert_includes admin_navigation, '"menu-active" if controller_path.start_with?("maintenance_tasks/")'
    assert_includes admin_navigation, 'link_to application_routes.account_path'
    assert_includes admin_navigation, 'application_translate("navigation.dashboard")'
    assert_operator admin_navigation.index("application_routes.account_path"), :>,
      admin_navigation.index("application_routes.admin_maintenance_tasks_path")
    assert_includes @source, 'controller_path.start_with?("admin/")'
    assert_includes @source, 'controller_path.start_with?("mission_control/jobs/")'
    assert_includes @source, 'controller_path.start_with?("maintenance_tasks/")'
    assert_includes header, 'application_translate("navigation.admin")'
    assert_includes header, '<%= render "shared/account_navigation" %>'
    assert_includes header, '<li class="menu-title"><%= application_translate("navigation.admin") %></li>'
    assert_includes @source, '<div class="menu-title">'
    refute_match(/<li class="menu-title[^\"]*">\s*<span>/, @source)
    assert_includes header, '<li role="separator"></li>'
    refute_includes header, "border-t border-base-300"
    assert_includes header, '<%= link_to #{logout_path}, data: { turbo_method: :delete } do %>'
    assert_includes header, 'M15.75 9V5.25A2.25 2.25 0 0 0 13.5 3'
    assert_match(/<svg[^>]+class="size-5"[^>]+aria-hidden="true"[^>]+data-slot="icon">\s*<path[^>]+M15\.75 9V5\.25/m, header)
    assert_includes header, 'data: { turbo_method: :delete }'
    assert_includes @source, 'M3.75 6.75h16.5M3.75 12h16.5m-16.5 5.25h16.5'
    assert_includes @source, 't("common.menu")'
    refute_includes header, "min-h-11 items-center gap"

    assert_class_tokens authentication_layout, "hero"
    assert_class_tokens authentication_layout, "hero-content", "flex-col", "gap-4"
    assert_equal 2, authentication_layout.scan('<div class="card card-border bg-base-100 w-full">').size
    assert_equal 2, authentication_layout.scan('<div class="card-body p-6 sm:p-8">').size
    assert_includes authentication_layout, "content_for?(:authentication_switch)"
    assert_includes authentication_layout, "<%= yield :authentication_switch %>"
    assert_class_tokens home, "hero"
    assert_class_tokens home, "hero-content"
    assert_class_tokens login, "checkbox"
    [login, registration].each do |view|
      assert_includes view, 'class_names(action_button_classes(:primary), "btn-block")'
      assert_includes view, 'class_names(action_button_classes(:secondary), "btn-block")'
      assert_includes view, "content_for :authentication_switch"
      assert_class_tokens view, "mb-4", "text-sm", "text-base-content/70"
      refute_includes view, '<div class="divider"></div>'
    end
    assert_includes login, 't("authentication.new_account_prompt")'
    assert_includes registration, 't("authentication.existing_account_prompt")'
    assert_includes login, 'link_to t("authentication.create_account"), new_user_registration_path'
    assert_includes registration, 'link_to t("authentication.back_to_sign_in"), new_user_session_path'
    assert_includes login, 'data-controller="passkey"'
    assert_includes registration, 'data-controller="passkey"'
  end

  def test_devise_guest_navigation_uses_real_line_breaks
    guest_navigation = source_between(
      "  guest_desktop_navigation = <<~ERB",
      "  profile_identity = if display_name_enabled"
    )

    assert_equal 2, guest_navigation.scan("<<~ERB").size
    assert_includes guest_navigation, 'class: "btn btn-outline"'
    refute_includes guest_navigation, "\\\\n'"
  end

  def test_regular_views_do_not_define_with_menu_layout_content
    ordinary_views = %w[
      app/views/accounts/show.html.erb
      app/views/admin/users/index.html.erb
      app/views/admin/users/edit.html.erb
      app/views/admin/pages/index.html.erb
      app/views/mission_control/jobs/queues/index.html.erb
      app/views/maintenance_tasks/tasks/index.html.erb
    ]

    ordinary_views.each do |path|
      view = generated_file_source(path)
      refute_includes view, "with_menu_navigation", path
      refute_includes view, "with_menu_subnavigation", path
      assert_includes view, "content_for :page_title", path
      refute_includes view, "<h1", path
    end
  end

  def test_page_actions_use_shared_slots_without_moving_model_or_form_actions
    helper = generated_file_source("app/helpers/application_helper.rb")
    passkeys = generated_file_source("app/views/account/passkeys/index.html.erb")
    identities = generated_file_source("app/views/account/siwe_identities/index.html.erb")
    api_credentials = generated_file_source("app/views/api_credentials/index.html.erb")
    faqs = generated_file_source("app/views/admin/faqs/index.html.erb")
    application_selection = generated_file_source("app/views/layouts/mission_control/jobs/_application_selection.html.erb")
    jobs_index = generated_file_source("app/views/mission_control/jobs/jobs/index.html.erb")
    job_show = generated_file_source("app/views/mission_control/jobs/jobs/show.html.erb")
    api_form = generated_file_source("app/views/api_credentials/_form.html.erb")

    assert_includes helper, "def page_actions(card:)"
    assert_includes helper, "private :page_actions"
    assert_includes helper, 'data: { page_actions_column: "secondary" }'
    assert_includes helper, 'data: { page_actions_column: "primary" }'
    assert_includes helper, 'class: "grid min-w-0 gap-4 sm:grid-cols-2"'
    assert_includes helper, 'class: "card card-border bg-base-100 mb-6"'
    assert_includes helper, 'class: "card-body p-3"'
    assert_includes helper, 'content_for(:page_actions_in_tab, "true", flush: true)'
    assert_operator helper.index("tab_content = capture(&block)"), :<, helper.index("page_actions(card: false)")

    [passkeys, identities, api_credentials, faqs].each do |view|
      assert_includes view, "content_for :page_actions_primary"
      refute_includes view, "content_for :page_actions_secondary"
    end
    assert_includes application_selection, "content_for :page_actions_secondary"
    refute_includes jobs_index, "content_for :page_actions_secondary"
    assert_includes jobs_index, "content_for :page_actions_primary"

    refute_includes job_show, "content_for :page_actions_primary"
    assert_includes job_show, '<header class="flex flex-wrap items-start justify-between gap-4">'
    refute_includes api_form, "content_for :page_actions_primary"
    assert_includes api_form, '<div class="card-actions flex-wrap justify-end">'
    assert_includes api_form, '<%= form.submit class: action_button_classes(:primary) %>'
  end

  def test_with_menu_standard_surfaces_use_p_3_without_changing_nested_or_variant_cards
    standard_surface_views = %w[
      app/views/accounts/show.html.erb
      app/views/profiles/show.html.erb
      app/views/profiles/edit.html.erb
      app/views/web_push_settings/show.html.erb
      app/views/admin/notifications/index.html.erb
      app/views/admin/notifications/new.html.erb
      app/views/admin/notifications/edit.html.erb
      app/views/admin/notifications/show.html.erb
      app/views/api_credentials/index.html.erb
      app/views/api_credentials/show.html.erb
      app/views/api_credentials/new.html.erb
      app/views/api_credentials/edit.html.erb
      app/views/admin/users/index.html.erb
      app/views/admin/pages/index.html.erb
      app/views/admin/pages/edit.html.erb
      app/views/admin/faqs/index.html.erb
      app/views/admin/faqs/new.html.erb
      app/views/admin/faqs/edit.html.erb
      app/views/admin/footer_settings/edit.html.erb
    ]

    standard_surface_views.each do |path|
      view = generated_file_source(path)

      assert_equal 1, view.scan('class="card-body p-3"').size, path
      refute_includes view, "p-5 sm:p-6", path
    end

    account_delete = generated_file_source("app/views/accounts/delete.html.erb")
    job_show = generated_file_source("app/views/mission_control/jobs/jobs/show.html.erb")
    public_page = generated_file_source("app/views/pages/_page.html.erb")

    assert_includes account_delete, '<section class="card card-border border-error bg-base-100">'
    assert_includes account_delete, '<div class="card-body">'
    assert_includes job_show, '<div class="card-body p-0">'
    assert_includes public_page, '<div class="card-body"><%= @page.content %></div>'
  end

  def test_page_titles_use_one_content_for_contract_across_generated_views
    application_helper = generated_file_source("app/helpers/application_helper.rb")
    home = generated_file_source("app/views/home/index.html.erb")
    public_views = %w[
      lib/templates/erb/scaffold/index.html.erb.tt
      lib/templates/erb/scaffold/show.html.erb.tt
      lib/templates/erb/scaffold/new.html.erb.tt
      lib/templates/erb/scaffold/edit.html.erb.tt
      lib/templates/erb/controller/view.html.erb.tt
      app/views/pages/_page.html.erb
      app/views/faqs/index.html.erb
      app/views/users/passkey_sessions/new.html.erb
      app/views/users/passkey_registrations/new.html.erb
      app/views/notifications/index.html.erb
    ]
    with_menu_views = %w[
      app/views/accounts/show.html.erb
      app/views/account/siwe_identities/index.html.erb
      app/views/account/siwe_identities/new.html.erb
      app/views/account/siwe_identities/show.html.erb
      app/views/account/siwe_identities/edit.html.erb
      app/views/account/passkeys/index.html.erb
      app/views/account/passkeys/new.html.erb
      app/views/account/passkeys/show.html.erb
      app/views/account/passkeys/edit.html.erb
      app/views/accounts/delete.html.erb
      app/views/admin/users/index.html.erb
      app/views/admin/pages/index.html.erb
      app/views/admin/pages/edit.html.erb
      app/views/admin/faqs/index.html.erb
      app/views/admin/faqs/new.html.erb
      app/views/admin/faqs/edit.html.erb
      app/views/admin/footer_settings/edit.html.erb
      app/views/profiles/show.html.erb
      app/views/profiles/edit.html.erb
      app/views/api_credentials/index.html.erb
      app/views/api_credentials/show.html.erb
      app/views/api_credentials/new.html.erb
      app/views/api_credentials/edit.html.erb
      app/views/web_push_settings/show.html.erb
      app/views/admin/notifications/index.html.erb
      app/views/admin/notifications/new.html.erb
      app/views/admin/notifications/edit.html.erb
      app/views/admin/notifications/show.html.erb
      app/views/maintenance_tasks/tasks/index.html.erb
      app/views/maintenance_tasks/tasks/show.html.erb
      app/views/mission_control/jobs/queues/index.html.erb
      app/views/mission_control/jobs/queues/show.html.erb
      app/views/mission_control/jobs/jobs/index.html.erb
      app/views/mission_control/jobs/jobs/show.html.erb
      app/views/mission_control/jobs/recurring_tasks/index.html.erb
      app/views/mission_control/jobs/recurring_tasks/show.html.erb
      app/views/mission_control/jobs/workers/index.html.erb
      app/views/mission_control/jobs/workers/show.html.erb
    ]

    assert_includes application_helper, "page_title = content_for(:page_title).presence"
    refute_includes application_helper, "content_for(:title)"
    refute_includes @source, "content_for :title"
    refute_includes @source, "eyebrow"
    refute_includes home, "content_for :page_title"
    refute_includes home, "content_for :title"

    public_views.each do |path|
      view = generated_file_source(path)
      assert_includes view, "content_for :page_title", path
      assert_includes view, "content_for(:page_title)", path
      assert_includes view, "<h1", path
    end

    with_menu_views.each do |path|
      view = generated_file_source(path)
      assert_includes view, "content_for :page_title", path
      refute_includes view, "<h1", path
    end
  end

  def test_passkey_is_the_required_passwordless_authentication_baseline
    devise = source_between("def install_devise", "def install_siwe")
    user = generated_file_source("app/models/user.rb")
    passkey = generated_file_source("app/models/passkey_credential.rb")
    challenge = generated_file_source("app/models/webauthn_challenge.rb")
    default_name = generated_file_source("app/services/passkey_default_name.rb")
    default_name_test = generated_file_source("test/services/passkey_default_name_test.rb")
    signup_controller = generated_file_source("app/controllers/users/passkey_registrations_controller.rb")
    account_controller = generated_file_source("app/controllers/account/passkeys_controller.rb")
    signup_view = generated_file_source("app/views/users/passkey_registrations/new.html.erb")
    account_new_view = generated_file_source("app/views/account/passkeys/new.html.erb")
    account_edit_view = generated_file_source("app/views/account/passkeys/edit.html.erb")
    risk_flash = generated_file_source("app/views/shared/_flash.html.erb")

    assert_includes @source, 'gem "devise", "~> 5.0.4"'
    assert_includes @source, 'gem "webauthn", "~> 3.4"'
    assert_includes @source, 'gem "browser", "~> 6.2"'
    assert_includes devise, "t.string :webauthn_id, null: false"
    assert_includes devise, "t.datetime :remember_created_at"
    assert_includes devise, "add_index :users, :webauthn_id, unique: true"
    refute_includes devise, "t.string :login_id"
    refute_includes devise, "t.string :encrypted_password"
    assert_includes user, 'devise #{devise_declaration}'
    assert_includes devise, "%w[passkey_authenticatable rememberable]"
    refute_includes devise, "database_authenticatable"
    refute_includes devise, "registerable"
    assert_includes user, "before_validation :assign_webauthn_id, on: :create"
    assert_includes user, "candidate = WebAuthn.generate_user_id"
    assert_includes user, "validate :webauthn_id_cannot_change, on: :update"
    assert_includes passkey, "raise VerificationError, \"backup eligibility changed\""
    assert_includes passkey, "asserted_backup_state && !asserted_backup_eligible"
    assert_includes default_name, "6eb68689ae67a5f261eebae490f34633063d9da0"
    assert_includes default_name, '"bada5566-a7aa-401f-bd96-45619a55120d" => "1Password"'
    assert_includes default_name, '"fbfc3007-154e-4ecc-8c0b-6e020557d7bd" => "Apple Passwords"'
    assert_includes default_name, '"ea9b8d66-4d01-1d21-3ce4-b6b48cb575d4" => "Google Password Manager"'
    assert_includes default_name, "PROVIDER_NAMES[aaguid.to_s.downcase]"
    assert_includes default_name, "browser.platform.chrome_os?"
    assert_includes default_name, '"Passkey"'
    assert_includes default_name_test, "assert_operator name.length, :<=, 50"
    assert_includes signup_controller,
      "PasskeyDefaultName.resolve(aaguid: credential.response.aaguid, user_agent: request.user_agent)"
    assert_includes account_controller,
      "PasskeyDefaultName.resolve(aaguid: credential.response.aaguid, user_agent: request.user_agent)"
    refute_includes signup_controller, "params.expect(passkey_credential: [:name])"
    refute_includes signup_view, "form.text_field :name"
    refute_includes account_new_view, "form.text_field :name"
    assert_includes account_edit_view, "form.text_field :name"
    assert_includes challenge, "TTL = 5.minutes"
    assert_includes challenge, "session_digest"
    assert_includes challenge, "update_all(consumed_at: Time.current)"
    assert_includes challenge, "purpose == \"destroy\""
    assert_includes risk_flash,
      '<%= link_to t("credential_risk.add_login_method"), application_routes.account_passkeys_path, class: "link whitespace-nowrap" %>'
    refute_includes risk_flash, 'credential_risk.add_passkey'
    refute_includes risk_flash, 'credential_risk.add_wallet'
    refute_includes risk_flash, 'class: "btn btn-sm"'
    refute_includes devise, "verify_cross_origin"
    refute_includes devise, "allowed_top_origins"
  end
  def test_passkey_signup_and_discoverable_login_are_separate_ceremonies
    routes = source_between("def configure_devise_routes", "def configure_maintenance_tasks_route")
    registrations = generated_file_source("app/controllers/users/passkey_registrations_controller.rb")
    sessions = generated_file_source("app/controllers/users/passkey_sessions_controller.rb")
    registration = generated_file_source("app/views/users/passkey_registrations/new.html.erb")
    login = generated_file_source("app/views/users/passkey_sessions/new.html.erb")
    javascript = generated_file_source("app/javascript/controllers/passkey_controller.js")

    assert_includes routes, 'to: "users/passkey_registrations#options"'
    assert_includes routes, 'to: "users/passkey_registrations#create"'
    assert_includes routes, 'to: "users/passkey_sessions#options"'
    assert_includes routes, 'to: "users/passkey_sessions#create"'
    assert_includes registrations, "resident_key: \"required\""
    assert_includes registrations, "user_verification: \"required\""
    assert_includes registrations, "attestation: \"none\""
    assert_includes registrations, "User.create!"
    assert_includes sessions, "WebAuthn::Credential.options_for_get"
    assert_includes sessions, "user_handle"
    assert_includes registration, 'data-passkey-ceremony-value="create"'
    assert_includes login, 'data-passkey-ceremony-value="get"'
    refute_includes registration, "password"
    refute_includes login, "login_id"
    assert_includes javascript, "parseCreationOptionsFromJSON"
    assert_includes javascript, "parseRequestOptionsFromJSON"
    assert_includes javascript, "credential.toJSON()"
    refute_includes javascript, "base64"
  end
  def test_siwe_is_optional_and_keeps_signup_separate_from_existing_user_login
    siwe = source_between("def install_siwe", "def configure_roles")
    module_source = generated_file_source("lib/devise/siweable.rb")
    sessions = generated_file_source("app/controllers/users/siwe_sessions_controller.rb")
    registrations = generated_file_source("app/controllers/users/siwe_registrations_controller.rb")

    assert_includes @source,
      'gem "siwe-rb", "~> 0.2.0", require: "siwe" if VALUES.fetch("additional_login_methods").include?("siwe")'
    assert_includes module_source, "Devise.add_module("
    assert_includes module_source, "model: \"devise/models/siweable\""
    refute_includes module_source, "controller:"
    refute_includes module_source, "route:"
    assert_includes siwe, 'require Rails.root.join("lib/devise/siweable")'
    assert_includes sessions, "SiweIdentity.includes(:user).find_by"
    assert_includes sessions, 'render json: { error: "wallet_not_registered" }, status: :unauthorized'
    assert_includes sessions, "user = T.must(identity.user)"
    assert_includes sessions, "user.active_for_authentication?"
    assert_includes sessions, "sign_in(:user, user, event: :authentication)"
    refute_includes sessions, "find_or_create_by!"
    assert_includes registrations, "purpose: \"signup\""
    assert_includes registrations, "User.create!"
    assert_includes registrations, "siwe_identities.create!"
    assert_includes registrations, "SiweIdentityDefaultName.resolve(provider_name: params[:wallet_provider_name])"
    assert_includes registrations, "SiweIdentity.exists?"
  end
  def test_siwe_credentials_and_challenges_are_target_bound_and_replay_safe
    identity = generated_file_source("app/models/siwe_identity.rb")
    challenge = generated_file_source("app/models/siwe_challenge.rb")
    controller = generated_file_source("app/controllers/account/siwe_identities_controller.rb")
    default_name = generated_file_source("app/services/siwe_identity_default_name.rb")
    destruction = generated_file_source("app/controllers/account/credential_destructions_controller.rb")
    initializer = generated_file_source("config/initializers/devise_siweable.rb")

    assert_includes identity, "length: { maximum: 50 }"
    refute_includes identity, "uniqueness: { scope: :user_id"
    assert_includes identity, "errors.add(:address, :readonly)"
    assert_includes challenge, "TTL = 5.minutes"
    assert_includes challenge, "PURPOSES = %w[signup login link destroy]"
    assert_includes challenge, "session_digest: digest(session_binding)"
    assert_includes challenge, "action:"
    assert_includes challenge, "target_type: target&.class&.name"
    assert_includes challenge, "strict: true"
    assert_includes challenge, "update_all(consumed_at: Time.current)"
    assert_includes controller, "account_user.siwe_identities.find(params.expect(:id))"
    assert_includes controller, "SiweIdentityDefaultName.resolve(provider_name: params[:wallet_provider_name])"
    refute_includes controller, "siwe_identities.count"
    assert_includes default_name, 'FALLBACK_NAME = "Wallet"'
    assert_includes default_name, "name.present? && name.length <= MAX_LENGTH"
    refute_includes controller, "valid_password?"
    assert_includes destruction, 'purpose: "destroy"'
    assert_includes destruction, "action:"
    assert_includes destruction, "target:"
    assert_includes initializer, "%i[challenge_token signature]"
    refute_includes challenge, "request.host"
    refute_match(/\bparams(?:\.|\[)/, challenge)
  end

  def test_authentication_session_marks_the_current_wallet_and_blocks_its_removal
    session_concern = generated_file_source("app/controllers/concerns/authentication_credential_session.rb")
    passkey_sessions = generated_file_source("app/controllers/users/passkey_sessions_controller.rb")
    passkey_registrations = generated_file_source("app/controllers/users/passkey_registrations_controller.rb")
    siwe_sessions = generated_file_source("app/controllers/users/siwe_sessions_controller.rb")
    siwe_registrations = generated_file_source("app/controllers/users/siwe_registrations_controller.rb")
    identities = generated_file_source("app/controllers/account/siwe_identities_controller.rb")
    identity_index = generated_file_source("app/views/account/siwe_identities/index.html.erb")
    destruction = generated_file_source("app/controllers/account/credential_destructions_controller.rb")

    assert_includes @source, "include AuthenticationCredentialSession"
    assert_includes session_concern, "helper_method :current_authentication_credential?"
    assert_includes session_concern, "session[:authentication_credential_type] = credential.class.name"
    assert_includes session_concern, "session[:authentication_credential_id] = credential.id"
    assert_includes session_concern, "def forget_authentication_credential"
    [passkey_sessions, passkey_registrations, siwe_sessions, siwe_registrations].each do |controller|
      assert_includes controller, "remember_authentication_credential"
    end
    assert_includes passkey_sessions, "forget_authentication_credential"
    assert_includes siwe_sessions, "identity = SiweIdentity.includes(:user).find_by"
    assert_includes identities, "@removable_siwe_identity_ids"
    assert_includes identities, "current_authentication_credential?(@siwe_identity)"
    assert_includes identity_index, "current_authentication_credential?(identity)"
    assert_includes identity_index, 't("siwe.identities.current")'
    assert_includes identity_index, "@removable_siwe_identity_ids.include?(identity.id)"
    assert_includes destruction, 'raise CredentialDestruction::Error, "current authentication credential"'
  end

  def test_siwe_uses_eip_6963_provider_selection_and_legacy_fallback
    javascript = generated_file_source("app/javascript/controllers/siwe_sign_in_controller.js")
    picker = generated_file_source("app/views/shared/_siwe_provider_picker.html.erb")

    assert_includes javascript, 'window.addEventListener("eip6963:announceProvider"'
    assert_includes javascript, 'window.dispatchEvent(new Event("eip6963:requestProvider"))'
    assert_includes javascript, "if (providers.length > 1)"
    assert_includes javascript, "this.providerDialogTarget.showModal()"
    assert_includes javascript, "providers[0] || this.legacyProvider()"
    assert_includes javascript, "selected.provider.request"
    assert_includes javascript, "verifyPayload.wallet_provider_name = this.providerName(selected.info)"
    assert_includes javascript, '["signup", "link"].includes(this.modeValue)'
    refute_includes javascript, "window.ethereum.request({"
    assert_includes picker, "with_modal("
    assert_includes picker, 'class="menu mt-4 w-full"'
    assert_includes picker, 'siwe_sign_in_target: "providerDialog"'
    refute_includes javascript, "info.icon"
    refute_includes javascript, "info.rdns"
    %w[
      siwe-login-provider-picker
      siwe-signup-provider-picker
      siwe-link-provider-picker
      siwe-delete-passkey-provider-picker
      siwe-delete-identity-provider-picker
      siwe-delete-account-provider-picker
    ].each { |modal_id| assert_includes @source, modal_id }
  end
  def test_common_features_do_not_depend_on_legacy_authentication_identifiers
    refute_includes @source, "account_authentication"
    refute_includes @source, "Current.user"
    refute_includes @source, "wallet_address"
    refute_includes @source, "users.email"
    assert_includes @source, '"triggered_by_user_id" => T.must(authorization_user).id'
    assert_includes @source, 'AdminRoleGrant.call(ENV.fetch("ADMIN_USER_ID"))'
  end
end
