# frozen_string_literal: true

require_relative "../test_helper"

class ExecutionPlanTest < Minitest::Test
  def test_default_plan_installs_only_selected_solid_component
    plan = RapidRailsTemplate::ExecutionPlan.build(RapidRailsTemplate::Configuration.build({}))

    assert_includes plan.gems, "solid_cache"
    refute_includes plan.gems, "solid_queue"
    refute_includes plan.gems, "solid_cable"
    assert_includes plan.gems, "devise"
    assert_includes plan.gems, "haikunator"
    assert_includes plan.steps, "install_daisyui"
    assert_includes plan.steps, "configure_api"
    assert_includes plan.steps, "install_active_storage"
    assert_includes plan.steps, "configure_profile"
    assert_includes plan.steps, "configure_default_views"
    assert_operator plan.steps.index("prepare_database"), :<, plan.steps.index("verify")
    assert_includes plan.artifacts, "package.json"
    assert_includes plan.artifacts, "package-lock.json"
    assert_includes plan.artifacts, "app/views/layouts/application.html.erb"
    assert_includes plan.artifacts, "app/views/layouts/authentication.html.erb"
    assert_includes plan.artifacts, "app/views/layouts/account.html.erb"
    assert_includes plan.artifacts, "app/views/devise/sessions/new.html.erb"
    assert_includes plan.artifacts, "app/views/accounts/show.html.erb"
    assert_includes plan.artifacts, "app/models/profile.rb"
    assert_includes plan.artifacts, "app/controllers/profiles_controller.rb"
    assert_includes plan.artifacts, "app/views/profiles/edit.html.erb"
    assert_includes plan.artifacts, "app/models/api_credential.rb"
    assert_includes plan.artifacts, "app/controllers/api/api_controller.rb"
    assert_includes plan.artifacts, "app/javascript/controllers/clipboard_controller.js"
    assert_includes plan.artifacts, "app/views/api_credentials/index.html.erb"
  end

  def test_api_disabled_plan_omits_api_steps_and_artifacts
    plan = RapidRailsTemplate::ExecutionPlan.build(RapidRailsTemplate::Configuration.build("api" => "disable"))

    refute_includes plan.steps, "configure_api"
    refute_includes plan.artifacts, "app/models/api_credential.rb"
    refute_includes plan.artifacts, "app/controllers/api/api_controller.rb"
    refute_includes plan.artifacts, "app/javascript/controllers/clipboard_controller.js"
    refute_includes plan.artifacts, "app/views/api_credentials/index.html.erb"
  end

  def test_empty_profile_features_omit_profile_and_active_storage_steps_and_artifacts
    plan = RapidRailsTemplate::ExecutionPlan.build(
      RapidRailsTemplate::Configuration.build("profile_features" => [])
    )

    refute_includes plan.steps, "install_active_storage"
    refute_includes plan.steps, "configure_profile"
    refute_includes plan.gems, "haikunator"
    refute_includes plan.artifacts, "app/models/profile.rb"
    refute_includes plan.artifacts, "app/controllers/profiles_controller.rb"
    refute_includes plan.artifacts, "app/views/profiles/edit.html.erb"
  end

  def test_profile_without_avatar_does_not_install_active_storage
    plan = RapidRailsTemplate::ExecutionPlan.build(
      RapidRailsTemplate::Configuration.build("profile_features" => %w[screen_name display_name])
    )

    assert_includes plan.steps, "configure_profile"
    refute_includes plan.steps, "install_active_storage"
  end

  def test_avatar_only_profile_does_not_install_haikunator
    plan = RapidRailsTemplate::ExecutionPlan.build(
      RapidRailsTemplate::Configuration.build("profile_features" => %w[avatar])
    )

    assert_includes plan.steps, "configure_profile"
    refute_includes plan.gems, "haikunator"
  end

  def test_wallet_plan_uses_siwe_and_not_devise
    plan = RapidRailsTemplate::ExecutionPlan.build(
      RapidRailsTemplate::Configuration.build("account_authentication" => "wallet_siwe", "deployment" => "none")
    )

    assert_includes plan.gems, "siwe-rb"
    refute_includes plan.gems, "devise"
    assert_includes plan.artifacts, "package.json"
    assert_includes plan.artifacts, "package-lock.json"
    assert_includes plan.artifacts, "app/views/sessions/new.html.erb"
    assert_includes plan.artifacts, "app/javascript/controllers/siwe_sign_in_controller.js"
    assert_includes plan.artifacts, "app/views/accounts/edit.html.erb"
    assert_includes plan.artifacts, "config/locales/ja.yml"
    assert_equal plan.artifacts.uniq, plan.artifacts
    assert_includes plan.steps, "prepare_database"
    refute_includes plan.artifacts, "app/views/devise/sessions/new.html.erb"
    refute_includes plan.artifacts, "Dockerfile.prod"
  end

  def test_generator_options_disable_solid_bundle_and_selected_frameworks
    configuration = RapidRailsTemplate::Configuration.build("mail" => "skip", "action_text" => "skip")
    options = RapidRailsTemplate::GeneratorOptions.build(configuration)

    assert_includes options, "--skip-solid"
    assert_includes options, "--skip-action-mailer"
    assert_includes options, "--skip-action-text"
  end

  def test_all_feature_plan_contains_conditional_databases_and_processes
    configuration = RapidRailsTemplate::Configuration.build(
      "pwa" => "use",
      "web_push" => "use",
      "active_job" => "solid_queue",
      "solid_cache" => "use",
      "action_cable" => "solid_cable",
      "deployment" => "dokploy"
    )
    plan = RapidRailsTemplate::ExecutionPlan.build(configuration)

    assert_includes plan.gems, "web-push"
    assert_includes plan.gems, "solid_queue"
    assert_includes plan.gems, "solid_cache"
    assert_includes plan.gems, "solid_cable"
    assert_equal %w[web worker], plan.processes
    assert_includes plan.artifacts, "mise.local.toml"
  end
end
