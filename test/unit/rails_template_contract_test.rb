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
    pattern = /^(?<indent>[ \t]*)create_file #{Regexp.escape(path.inspect)}, <<~(?<delimiter>[A-Z]+), force: true\n(?<body>.*?)^\k<indent>\k<delimiter>$/m
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
      "app/views/shared/_header.html.erb" => %w[navbar dropdown menu btn],
      "app/views/shared/_flash.html.erb" => %w[alert],
      "app/views/shared/_footer.html.erb" => %w[footer],
      "app/views/home/index.html.erb" => %w[hero hero-content badge btn card card-body card-title],
      "app/views/accounts/show.html.erb" => %w[card card-body card-title list list-row badge btn],
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
    %w[navbar menu dropdown hero card fieldset input checkbox btn alert footer badge divider list].each do |component|
      assert class_attributes(views).any? { |classes| classes.include?(component) }, component
    end
    %w[bg-base-100 bg-base-200 border-base-300 text-base-content btn-primary].each { |utility| assert_includes views, utility }
    refute_match(/(?:bg|text|border)-(?:blue|gray|slate|red|green|yellow)-\d+/, views)
    refute_includes views, "dark:"
    refute_match(/#[0-9a-f]{3,8}(?![0-9a-z])/i, views)
  end

  def test_devise_fixtures_satisfy_the_generated_unique_email_constraint
    assert_includes @source, 'email: one@example.com'
    assert_includes @source, 'email: two@example.com'
    assert_includes @source, 'Devise::Encryptor.digest(User, "password123")'
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
    authentication_layout = generated_file_source("app/views/layouts/authentication.html.erb")
    home = generated_file_source("app/views/home/index.html.erb")
    shared_links = generated_file_source("app/views/devise/shared/_links.html.erb")
    login = generated_file_source("app/views/devise/sessions/new.html.erb")
    mobile_navigation = source_between("  mobile_navigation_items = if devise", "  home_action = if devise")
    account_navigation = source_between(
      "  account_navigation_items = if devise",
      "  account_navigation_items = account_navigation_items.lines"
    )

    assert_class_tokens header, "navbar", "mx-auto", "w-full", "max-w-6xl", "px-5"
    assert_class_tokens header, "dropdown", "dropdown-end"
    assert_class_tokens header, "menu", "menu-sm", "dropdown-content"
    assert_class_tokens header, "btn", "btn-ghost"
    mobile_menu_classes = class_attributes(header).find { |classes| classes.include?("dropdown-content") }
    refute_nil mobile_menu_classes
    refute mobile_menu_classes.any? { |token| token.match?(/\Ap(?:[trblxy])?-/) }, mobile_menu_classes.inspect
    assert_class_tokens footer, "footer", "mx-auto", "w-full", "max-w-6xl", "px-5"
    refute_includes footer, "Rails 8.1 / Tailwind CSS 4 / daisyUI 5"

    assert_class_tokens account_layout, "menu"
    assert_class_tokens account_layout, "menu-title"
    assert_class_tokens account_layout, "mx-auto", "w-full", "max-w-6xl", "px-5"
    refute_includes account_layout, "max-w-5xl"
    assert_includes account_navigation, '"menu-active" if current_page?'
    refute_includes account_navigation, '"bg-base-content text-base-100" if current_page?'
    refute_includes account_navigation, "min-h-11"
    refute_includes account_navigation, "ホームへ戻る".b
    refute_includes account_navigation, "root_path"
    assert_equal 3, account_navigation.scan('<svg xmlns="http://www.w3.org/2000/svg" class="size-5"').size
    assert_equal 3, account_navigation.scan('aria-hidden="true" data-slot="icon"').size
    assert_includes account_navigation, 'M17.982 18.725A7.488 7.488 0 0 0 12 15.75'
    assert_includes account_navigation, 'M9.594 3.94c.09-.542.56-.94 1.11-.94'
    account_item_class_options = account_navigation.lines.filter_map { |line| line[/class: (.*?), aria:/, 1] }
    assert_equal [
      '("menu-active" if current_page?(account_path))',
      '("menu-active" if current_page?(edit_user_registration_path))',
      '"menu-active"'
    ], account_item_class_options

    assert_includes mobile_navigation, "data: { turbo_method: :delete }"
    refute_includes mobile_navigation, "min-h-11"
    refute_includes mobile_navigation, "button_to"
    refute_includes mobile_navigation, "divider"
    refute_match(/\bclass:/, mobile_navigation)

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
end
