# frozen_string_literal: true

require_relative "../test_helper"

class ExecutionPlanTest < Minitest::Test
  def test_default_plan_installs_only_selected_solid_component
    plan = RapidRailsTemplate::ExecutionPlan.build(
      RapidRailsTemplate::Configuration.build({}),
      app_name: "sample"
    )

    assert_equal "sample", plan.app_name
    assert_equal "sample", plan.to_h.fetch("app_name")
    assert_equal "--name=sample", plan.generator_options.first
    assert_includes plan.summary, "アプリ名: sample"
    assert_includes plan.gems, "solid_cache"
    refute_includes plan.gems, "solid_queue"
    refute_includes plan.gems, "solid_cable"
    assert_includes plan.gems, "devise"
    assert_includes plan.gems, "haikunator"
    assert_includes plan.gems, "boring_avatars"
    assert_includes plan.gems, "annotaterb"
    assert_includes plan.gems, "lexxy"
    assert_includes plan.steps, "install_action_text"
    assert_includes plan.steps, "configure_lexxy"
    assert_includes plan.steps, "install_daisyui"
    assert_operator plan.steps.index("install_action_text"), :<, plan.steps.index("configure_lexxy")
    assert_operator plan.steps.index("configure_lexxy"), :<, plan.steps.index("install_daisyui")
    assert_includes plan.steps, "configure_generator_view_templates"
    assert_operator plan.steps.index("install_daisyui"), :<, plan.steps.index("configure_generator_view_templates")
    assert_operator plan.steps.index("configure_generator_view_templates"), :<, plan.steps.index("configure_default_views")
    assert_includes plan.steps, "configure_api"
    assert_includes plan.steps, "configure_profile"
    assert_includes plan.steps, "configure_default_views"
    assert_includes plan.steps, "configure_evidence_capture"
    assert_includes plan.steps, "configure_roles"
    assert_includes plan.steps, "configure_content_management"
    assert_operator plan.steps.index("install_devise"), :<, plan.steps.index("configure_roles")
    assert_operator plan.steps.index("configure_roles"), :<, plan.steps.index("configure_content_management")
    assert_includes plan.steps, "install_annotaterb"
    assert_operator plan.steps.index("install_annotaterb"), :<, plan.steps.index("prepare_database")
    assert_operator plan.steps.index("prepare_database"), :<, plan.steps.index("verify")
    assert_operator plan.steps.index("prepare_database"), :<, plan.steps.index("annotate_models")
    assert_operator plan.steps.index("annotate_models"), :<, plan.steps.index("verify")
    assert_includes plan.artifacts, "package.json"
    assert_includes plan.artifacts, "package-lock.json"
    assert_includes plan.artifacts, ".annotaterb.yml"
    assert_includes plan.artifacts, "lib/tasks/annotate_rb.rake"
    assert_includes plan.artifacts, "bin/annotaterb"
    assert_includes plan.artifacts, "test/annotations_test.rb"
    assert_includes plan.artifacts, "test/support/evidence_capture.rb"
    assert_includes plan.artifacts, "lib/tasks/evidence.rake"
    assert_includes plan.artifacts, "app/models/user_role.rb"
    assert_includes plan.artifacts, "app/policies/application_policy.rb"
    assert_includes plan.artifacts, "app/policies/user_policy.rb"
    assert_includes plan.artifacts, "app/controllers/admin/users_controller.rb"
    assert_includes plan.artifacts, "app/controllers/admin/user_roles_controller.rb"
    assert_includes plan.artifacts, "app/views/admin/users/index.html.erb"
    assert_includes plan.artifacts, "lib/tasks/roles.rake"
    assert_includes plan.artifacts, "db/seeds.local.rb.example"
    assert_includes plan.artifacts, "config/locales/roles.ja.yml"
    assert_includes plan.artifacts, "test/models/user_role_test.rb"
    assert_includes plan.artifacts, "test/policies/user_policy_test.rb"
    assert_includes plan.artifacts, "test/controllers/admin/users_controller_test.rb"
    assert_includes plan.artifacts, "test/controllers/admin/user_roles_controller_test.rb"
    assert_includes plan.artifacts, "test/tasks/roles_task_test.rb"
    assert_includes plan.artifacts, "app/views/layouts/application.html.erb"
    assert_includes plan.artifacts, "lib/templates/erb/scaffold/index.html.erb.tt"
    assert_includes plan.artifacts, "lib/templates/erb/scaffold/_form.html.erb.tt"
    assert_includes plan.artifacts, "lib/templates/erb/controller/view.html.erb.tt"
    assert_includes plan.artifacts, "app/views/layouts/authentication.html.erb"
    assert_includes plan.artifacts, "app/views/layouts/account.html.erb"
    assert_includes plan.artifacts, "app/views/layouts/admin.html.erb"
    assert_includes plan.artifacts, "app/views/shared/_admin_navigation.html.erb"
    assert_includes plan.artifacts, "app/views/devise/sessions/new.html.erb"
    assert_includes plan.artifacts, "app/views/accounts/show.html.erb"
    assert_includes plan.artifacts, "app/models/profile.rb"
    assert_includes plan.artifacts, "app/controllers/profiles_controller.rb"
    assert_includes plan.artifacts, "app/views/profiles/edit.html.erb"
    assert_includes plan.artifacts, "app/helpers/avatar_helper.rb"
    assert_includes plan.artifacts, "test/helpers/avatar_helper_test.rb"
    assert_includes plan.artifacts, "app/models/api_credential.rb"
    assert_includes plan.artifacts, "app/controllers/api/api_controller.rb"
    assert_includes plan.artifacts, "app/javascript/controllers/clipboard_controller.js"
    assert_includes plan.artifacts, "app/views/api_credentials/index.html.erb"
    assert_includes plan.artifacts, "app/models/page.rb"
    assert_includes plan.artifacts, "app/models/faq.rb"
    assert_includes plan.artifacts, "app/models/footer_setting.rb"
    assert_includes plan.artifacts, "app/controllers/pages_controller.rb"
    assert_includes plan.artifacts, "app/controllers/faqs_controller.rb"
    assert_includes plan.artifacts, "app/controllers/admin/pages_controller.rb"
    assert_includes plan.artifacts, "app/controllers/admin/faqs_controller.rb"
    assert_includes plan.artifacts, "app/controllers/admin/footer_settings_controller.rb"
    assert_includes plan.artifacts, "app/views/layouts/action_text/contents/_content.html.erb"
    assert_includes plan.artifacts, "config/locales/content_management.ja.yml"
    assert_includes plan.artifacts, "app/views/pages/about.html.erb"
    assert_includes plan.artifacts, "app/views/faqs/index.html.erb"
    assert_includes plan.artifacts, "app/views/admin/footer_settings/edit.html.erb"
  end

  def test_api_disabled_plan_omits_api_steps_and_artifacts
    plan = RapidRailsTemplate::ExecutionPlan.build(
      RapidRailsTemplate::Configuration.build("api" => "disable"),
      app_name: "sample"
    )

    refute_includes plan.steps, "configure_api"
    refute_includes plan.artifacts, "app/models/api_credential.rb"
    refute_includes plan.artifacts, "app/controllers/api/api_controller.rb"
    refute_includes plan.artifacts, "app/javascript/controllers/clipboard_controller.js"
    refute_includes plan.artifacts, "app/views/api_credentials/index.html.erb"
  end

  def test_empty_profile_features_omit_profile_steps_and_artifacts
    plan = RapidRailsTemplate::ExecutionPlan.build(
      RapidRailsTemplate::Configuration.build("profile_features" => []),
      app_name: "sample"
    )

    assert_includes plan.steps, "install_action_text"
    refute_includes plan.steps, "configure_profile"
    refute_includes plan.gems, "haikunator"
    refute_includes plan.gems, "boring_avatars"
    refute_includes plan.artifacts, "app/models/profile.rb"
    refute_includes plan.artifacts, "app/controllers/profiles_controller.rb"
    refute_includes plan.artifacts, "app/views/profiles/edit.html.erb"
    refute_includes plan.artifacts, "app/helpers/avatar_helper.rb"
    refute_includes plan.artifacts, "test/helpers/avatar_helper_test.rb"
  end

  def test_profile_without_avatar_uses_the_shared_action_text_active_storage_install
    plan = RapidRailsTemplate::ExecutionPlan.build(
      RapidRailsTemplate::Configuration.build("profile_features" => %w[screen_name display_name]),
      app_name: "sample"
    )

    assert_includes plan.steps, "configure_profile"
    assert_includes plan.steps, "install_action_text"
    refute_includes plan.gems, "boring_avatars"
    refute_includes plan.artifacts, "app/helpers/avatar_helper.rb"
  end

  def test_avatar_only_profile_does_not_install_haikunator
    plan = RapidRailsTemplate::ExecutionPlan.build(
      RapidRailsTemplate::Configuration.build("profile_features" => %w[avatar]),
      app_name: "sample"
    )

    assert_includes plan.steps, "configure_profile"
    assert_includes plan.gems, "boring_avatars"
    refute_includes plan.gems, "haikunator"
    assert_includes plan.artifacts, "app/helpers/avatar_helper.rb"
    assert_includes plan.artifacts, "test/helpers/avatar_helper_test.rb"
  end

  def test_wallet_plan_uses_siwe_and_not_devise
    plan = RapidRailsTemplate::ExecutionPlan.build(
      RapidRailsTemplate::Configuration.build("account_authentication" => "wallet_siwe", "deployment" => "none"),
      app_name: "sample"
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
    assert_includes plan.steps, "configure_roles"
    assert_includes plan.artifacts, "app/models/user_role.rb"
    assert_includes plan.artifacts, "app/policies/user_policy.rb"
    assert_includes plan.artifacts, "app/views/admin/users/index.html.erb"
    refute_includes plan.artifacts, "app/views/devise/sessions/new.html.erb"
    refute_includes plan.artifacts, "Dockerfile.prod"
  end

  def test_generator_options_disable_solid_bundle_and_selected_frameworks
    configuration = RapidRailsTemplate::Configuration.build("mail" => "skip")
    options = RapidRailsTemplate::GeneratorOptions.build(configuration)

    assert_includes options, "--skip-solid"
    assert_includes options, "--skip-action-mailer"
    refute_includes options, "--skip-action-text"
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
    plan = RapidRailsTemplate::ExecutionPlan.build(configuration, app_name: "sample")

    assert_includes plan.gems, "web-push"
    assert_includes plan.gems, "solid_queue"
    assert_includes plan.gems, "solid_cache"
    assert_includes plan.gems, "solid_cable"
    assert_equal %w[web worker], plan.processes
    assert_includes plan.artifacts, "mise.local.toml"
  end
end
