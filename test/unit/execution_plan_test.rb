# frozen_string_literal: true

require_relative "../test_helper"

class ExecutionPlanTest < Minitest::Test
  def test_default_plan_installs_only_selected_solid_component
    plan = RapidRailsTemplate::ExecutionPlan.build(
      RapidRailsTemplate::Configuration.build({}),
      app_id: "sample", app_name: "Sample App"
    )

    assert_equal "sample", plan.app_id
    assert_equal "Sample App", plan.app_name
    assert_equal "sample", plan.to_h.fetch("app_id")
    assert_equal "Sample App", plan.to_h.fetch("app_name")
    assert_equal "--name=sample", plan.generator_options.first
    refute_includes plan.generator_options, "--skip-thruster"
    assert_includes plan.generator_options, "--skip-docker"
    assert_includes plan.generator_options, "--skip-kamal"
    assert_includes plan.summary, "RailsアプリID: sample"
    assert_includes plan.summary, "表示用アプリ名: Sample App"
    assert_includes plan.gems, "solid_cache"
    refute_includes plan.gems, "solid_queue"
    refute_includes plan.gems, "mission_control-jobs"
    refute_includes plan.gems, "solid_cable"
    assert_includes plan.gems, "devise"
    assert_includes plan.gems, "haikunator"
    assert_includes plan.gems, "boring_avatars"
    assert_includes plan.gems, "annotaterb"
    assert_includes plan.gems, "sorbet"
    assert_includes plan.gems, "sorbet-runtime"
    assert_includes plan.gems, "tapioca"
    assert_includes plan.gems, "lexxy"
    assert_includes plan.gems, "active_storage_db"
    assert_includes plan.gems, "thruster"
    refute_includes plan.gems, "imgproxy-rails"
    assert_includes plan.artifacts, "bin/thrust"
    assert_includes plan.gems, "rails-i18n"
    assert_includes plan.gems, "devise-i18n"
    assert_includes plan.steps, "configure_application_identity"
    assert_includes plan.steps, "configure_image_delivery"
    assert_includes plan.steps, "install_action_text"
    assert_includes plan.steps, "install_active_storage_db"
    assert_includes plan.steps, "configure_database"
    assert_includes plan.steps, "configure_active_storage_db"
    assert_includes plan.steps, "configure_lexxy"
    assert_operator plan.steps.index("install_action_text"), :<, plan.steps.index("install_active_storage_db")
    assert_operator plan.steps.index("install_active_storage_db"), :<, plan.steps.index("configure_lexxy")
    assert_includes plan.steps, "install_daisyui"
    assert_operator plan.steps.index("install_action_text"), :<, plan.steps.index("configure_lexxy")
    assert_operator plan.steps.index("configure_lexxy"), :<, plan.steps.index("install_daisyui")
    assert_includes plan.steps, "configure_generator_view_templates"
    assert_operator plan.steps.index("install_daisyui"), :<, plan.steps.index("configure_generator_view_templates")
    assert_operator plan.steps.index("configure_generator_view_templates"), :<, plan.steps.index("configure_default_views")
    assert_includes plan.steps, "configure_api"
    assert_includes plan.steps, "configure_profile"
    assert_includes plan.steps, "install_image_cropper"
    assert_operator plan.steps.index("install_image_cropper"), :<, plan.steps.index("configure_profile")
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
    assert_operator plan.steps.index("annotate_models"), :<, plan.steps.index("initialize_sorbet")
    assert_operator plan.steps.index("initialize_sorbet"), :<, plan.steps.index("prepare_test_database")
    assert_operator plan.steps.index("prepare_test_database"), :<, plan.steps.index("generate_sorbet_dsl")
    assert_operator plan.steps.index("generate_sorbet_dsl"), :<, plan.steps.index("typecheck_application")
    assert_operator plan.steps.index("typecheck_application"), :<, plan.steps.index("resolve_sorbet_todos")
    assert_operator plan.steps.index("resolve_sorbet_todos"), :<, plan.steps.index("verify_sorbet")
    assert_operator plan.steps.index("generate_sorbet_dsl"), :<, plan.steps.index("verify_sorbet")
    assert_operator plan.steps.index("verify_sorbet"), :<, plan.steps.index("verify")
    assert_includes plan.artifacts, "package.json"
    assert_includes plan.artifacts, "package-lock.json"
    assert_includes plan.artifacts, ".annotaterb.yml"
    assert_includes plan.artifacts, "lib/tasks/annotate_rb.rake"
    assert_includes plan.artifacts, "bin/annotaterb"
    assert_includes plan.artifacts, "bin/tapioca"
    assert_includes plan.artifacts, "sorbet/config"
    assert_includes plan.artifacts, "sorbet/tapioca/config.yml"
    assert_includes plan.artifacts, "sorbet/tapioca/require.rb"
    assert_includes plan.artifacts, "sorbet/rbi/shims/framework_bindings.rbi"
    assert_includes plan.artifacts, "sorbet/rbi/**/*"
    assert_includes plan.artifacts, "test/sorbet_test.rb"
    assert_includes plan.artifacts, "db/seeds.rb"
    assert_includes plan.artifacts, "test/annotations_test.rb"
    assert_includes plan.artifacts, "test/support/evidence_capture.rb"
    assert_includes plan.artifacts, "lib/tasks/evidence.rake"
    assert_includes plan.artifacts, "app/models/user_role.rb"
    assert_includes plan.artifacts, "lib/application_identity.rb"
    assert_includes plan.artifacts, "config/application_identity.yml"
    assert_includes plan.artifacts, "config/locales/application.ja.yml"
    assert_includes plan.artifacts, "config/locales/application.en.yml"
    assert_includes plan.artifacts, "app/policies/application_policy.rb"
    assert_includes plan.artifacts, "app/policies/user_policy.rb"
    assert_includes plan.artifacts, "app/controllers/admin/users_controller.rb"
    assert_includes plan.artifacts, "app/controllers/admin/user_roles_controller.rb"
    assert_includes plan.artifacts, "app/views/admin/users/index.html.erb"
    assert_includes plan.artifacts, "app/services/admin_role_grant.rb"
    assert_includes plan.artifacts, "lib/tasks/roles.rake"
    assert_includes plan.artifacts, "db/seeds.local.rb.example"
    assert_includes plan.artifacts, "config/locales/roles.ja.yml"
    assert_includes plan.artifacts, "test/models/user_role_test.rb"
    assert_includes plan.artifacts, "test/policies/user_policy_test.rb"
    assert_includes plan.artifacts, "test/controllers/admin/users_controller_test.rb"
    assert_includes plan.artifacts, "test/controllers/admin/user_roles_controller_test.rb"
    assert_includes plan.artifacts, "test/tasks/roles_task_test.rb"
    assert_includes plan.artifacts, "app/views/layouts/application.html.erb"
    assert_includes plan.artifacts, "app/helpers/application_helper.rb"
    assert_includes plan.artifacts, "test/helpers/application_helper_test.rb"
    assert_includes plan.artifacts, "lib/templates/erb/scaffold/index.html.erb.tt"
    assert_includes plan.artifacts, "lib/templates/erb/scaffold/_form.html.erb.tt"
    assert_includes plan.artifacts, "lib/templates/erb/controller/view.html.erb.tt"
    assert_includes plan.artifacts, "app/views/layouts/authentication.html.erb"
    assert_includes plan.artifacts, "app/views/layouts/_with_menu.html.erb"
    assert_includes plan.artifacts, "app/views/layouts/account.html.erb"
    assert_includes plan.artifacts, "app/views/layouts/admin.html.erb"
    assert_includes plan.artifacts, "app/views/shared/_account_navigation.html.erb"
    assert_includes plan.artifacts, "app/views/shared/_admin_navigation.html.erb"
    assert_includes plan.artifacts, "app/views/devise/sessions/new.html.erb"
    assert_includes plan.artifacts, "app/views/accounts/show.html.erb"
    assert_includes plan.artifacts, "app/models/profile.rb"
    assert_includes plan.artifacts, "app/controllers/profiles_controller.rb"
    assert_includes plan.artifacts, "app/views/profiles/edit.html.erb"
    assert_includes plan.artifacts, "app/helpers/avatar_helper.rb"
    assert_includes plan.artifacts, "test/helpers/avatar_helper_test.rb"
    assert_includes plan.artifacts, "app/javascript/controllers/image_crop_controller.js"
    assert_includes plan.artifacts, "test/system/profile_avatar_crop_test.rb"
    assert_includes plan.artifacts, "vendor/javascript/cropperjs.js"
    assert_includes plan.artifacts, "vendor/javascript/@cropper--element-selection.js"
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
    assert_includes plan.artifacts, "config/storage.yml"
    assert_includes plan.artifacts, "config/initializers/active_storage_db.rb"
    assert_includes plan.artifacts, "db/storage_migrate/*_create_active_storage_db_files.active_storage_db.rb"
    assert_includes plan.artifacts, "test/models/active_storage_db_test.rb"
    assert_includes plan.artifacts, "test/integration/image_delivery_test.rb"
    assert_includes plan.artifacts, "docs/image_delivery.md"
    assert_includes plan.artifacts, "app/services/avatar_image_policy.rb"
    assert_includes plan.artifacts, "app/services/avatar_upload.rb"
    assert_includes plan.artifacts, "app/validators/avatar_upload_validator.rb"
    assert_empty plan.production_requirements
    assert_equal plan.production_requirements, plan.to_h.fetch("production_requirements")
  end

  def test_api_disabled_plan_omits_api_steps_and_artifacts
    plan = RapidRailsTemplate::ExecutionPlan.build(
      RapidRailsTemplate::Configuration.build("api" => "disable"),
      app_id: "sample", app_name: "Sample App"
    )

    refute_includes plan.steps, "configure_api"
    refute_includes plan.artifacts, "app/models/api_credential.rb"
    refute_includes plan.artifacts, "app/controllers/api/api_controller.rb"
    assert_includes plan.artifacts, "app/javascript/controllers/clipboard_controller.js"
    assert_includes plan.artifacts, "app/views/devise/registrations/complete.html.erb"
    refute_includes plan.artifacts, "app/views/api_credentials/index.html.erb"
  end

  def test_maintenance_tasks_enabled_plan_uses_existing_solid_queue_worker
    plan = RapidRailsTemplate::ExecutionPlan.build(
      RapidRailsTemplate::Configuration.build(
        "active_job" => "solid_queue",
        "maintenance_tasks" => "enable",
        "deployment" => "dokploy"
      ),
      app_id: "sample", app_name: "Sample App"
    )

    assert_includes plan.gems, "maintenance_tasks"
    assert_includes plan.steps, "install_maintenance_tasks"
    assert_operator plan.steps.index("install_solid_queue"), :<, plan.steps.index("install_maintenance_tasks")
    assert_includes plan.artifacts, "config/initializers/maintenance_tasks.rb"
    assert_includes plan.artifacts, "app/controllers/admin/maintenance_tasks_controller.rb"
    assert_includes plan.artifacts, "app/helpers/admin/maintenance_tasks_helper.rb"
    assert_includes plan.artifacts, "app/policies/maintenance_task_policy.rb"
    assert_includes plan.artifacts, "app/views/maintenance_tasks/tasks/*.html.erb"
    assert_includes plan.artifacts, "app/views/maintenance_tasks/runs/*.html.erb"
    assert_includes plan.artifacts, "app/views/maintenance_tasks/runs/info/_errored.html.erb"
    assert_includes plan.artifacts, "db/migrate/*_maintenance_tasks.rb"
    assert_equal %w[web worker], plan.processes
    assert_equal 1, plan.processes.count("worker")
  end

  def test_job_operations_enabled_plan_uses_existing_solid_queue_scheduler
    plan = RapidRailsTemplate::ExecutionPlan.build(
      RapidRailsTemplate::Configuration.build(
        "active_job" => "solid_queue",
        "job_operations" => "enable",
        "deployment" => "dokploy"
      ),
      app_id: "sample", app_name: "Sample App"
    )

    assert_includes plan.gems, "mission_control-jobs"
    assert_includes plan.steps, "install_job_operations"
    assert_operator plan.steps.index("install_solid_queue"), :<, plan.steps.index("install_job_operations")
    assert_includes plan.artifacts, "config/initializers/mission_control_jobs.rb"
    assert_includes plan.artifacts, "app/controllers/admin/job_operations_controller.rb"
    assert_includes plan.artifacts, "app/policies/job_operation_policy.rb"
    assert_includes plan.artifacts, "app/views/layouts/mission_control/jobs/application.html.erb"
    assert_includes plan.artifacts, "app/helpers/admin/job_operations_helper.rb"
    assert_includes plan.artifacts, "app/views/layouts/mission_control/jobs/*.html.erb"
    assert_includes plan.artifacts, "app/views/mission_control/jobs/**/*.html.erb"
    assert_includes plan.artifacts, "test/models/solid_queue_cleanup_test.rb"
    assert_equal %w[web worker], plan.processes
    assert_equal 1, plan.processes.count("worker")
    assert_includes plan.production_requirements, "Solid Queue worker/dispatcher/scheduler"
    assert_includes plan.production_requirements, "finished jobs retained for 1 day; failed jobs retained until retry/discard"
  end

  def test_job_operations_disabled_plan_omits_related_gem_step_and_artifacts
    plan = RapidRailsTemplate::ExecutionPlan.build(
      RapidRailsTemplate::Configuration.build(
        "active_job" => "solid_queue",
        "job_operations" => "disable"
      ),
      app_id: "sample", app_name: "Sample App"
    )

    refute_includes plan.gems, "mission_control-jobs"
    refute_includes plan.steps, "install_job_operations"
    refute_includes plan.artifacts, "config/initializers/mission_control_jobs.rb"
    refute_includes plan.artifacts, "app/controllers/admin/job_operations_controller.rb"
    refute_includes plan.artifacts, "app/policies/job_operation_policy.rb"
    refute_includes plan.artifacts, "app/views/layouts/mission_control/jobs/application.html.erb"
    refute_includes plan.artifacts, "app/helpers/admin/job_operations_helper.rb"
    refute_includes plan.artifacts, "app/views/layouts/mission_control/jobs/*.html.erb"
    refute_includes plan.artifacts, "app/views/mission_control/jobs/**/*.html.erb"
    refute_includes plan.artifacts, "test/models/solid_queue_cleanup_test.rb"
    assert_includes plan.production_requirements, "finished jobs retained for 1 day; failed jobs retained until retry/discard"
  end

  def test_maintenance_tasks_disabled_plan_omits_related_gem_step_and_artifacts
    plan = RapidRailsTemplate::ExecutionPlan.build(
      RapidRailsTemplate::Configuration.build(
        "active_job" => "solid_queue",
        "maintenance_tasks" => "disable"
      ),
      app_id: "sample", app_name: "Sample App"
    )

    refute_includes plan.gems, "maintenance_tasks"
    refute_includes plan.steps, "install_maintenance_tasks"
    refute_includes plan.artifacts, "config/initializers/maintenance_tasks.rb"
    refute_includes plan.artifacts, "app/controllers/admin/maintenance_tasks_controller.rb"
    refute_includes plan.artifacts, "app/helpers/admin/maintenance_tasks_helper.rb"
    refute_includes plan.artifacts, "app/views/maintenance_tasks/tasks/*.html.erb"
    refute_includes plan.artifacts, "app/views/maintenance_tasks/runs/*.html.erb"
    refute_includes plan.artifacts, "db/migrate/*_maintenance_tasks.rb"
  end

  def test_empty_profile_features_omit_profile_steps_and_artifacts
    plan = RapidRailsTemplate::ExecutionPlan.build(
      RapidRailsTemplate::Configuration.build("profile_features" => []),
      app_id: "sample", app_name: "Sample App"
    )

    assert_includes plan.steps, "install_action_text"
    refute_includes plan.steps, "configure_profile"
    refute_includes plan.steps, "install_image_cropper"
    refute_includes plan.gems, "haikunator"
    refute_includes plan.gems, "boring_avatars"
    refute_includes plan.artifacts, "app/models/profile.rb"
    refute_includes plan.artifacts, "app/controllers/profiles_controller.rb"
    refute_includes plan.artifacts, "app/views/profiles/edit.html.erb"
    refute_includes plan.artifacts, "app/helpers/avatar_helper.rb"
    refute_includes plan.artifacts, "test/helpers/avatar_helper_test.rb"
    refute_includes plan.artifacts, "app/services/avatar_image_policy.rb"
    refute_includes plan.artifacts, "app/services/avatar_upload.rb"
    refute_includes plan.artifacts, "app/validators/avatar_upload_validator.rb"
    refute_includes plan.artifacts, "app/javascript/controllers/image_crop_controller.js"
    refute_includes plan.artifacts, "test/system/profile_avatar_crop_test.rb"
    refute_includes plan.artifacts, "vendor/javascript/cropperjs.js"
  end

  def test_profile_without_avatar_uses_the_shared_action_text_active_storage_install
    plan = RapidRailsTemplate::ExecutionPlan.build(
      RapidRailsTemplate::Configuration.build("profile_features" => %w[screen_name display_name]),
      app_id: "sample", app_name: "Sample App"
    )

    assert_includes plan.steps, "configure_profile"
    assert_includes plan.steps, "install_action_text"
    refute_includes plan.steps, "install_image_cropper"
    refute_includes plan.gems, "boring_avatars"
    refute_includes plan.artifacts, "app/helpers/avatar_helper.rb"
    refute_includes plan.artifacts, "app/javascript/controllers/image_crop_controller.js"
    refute_includes plan.artifacts, "test/system/profile_avatar_crop_test.rb"
    refute_includes plan.artifacts, "vendor/javascript/cropperjs.js"
  end

  def test_avatar_only_profile_does_not_install_haikunator
    plan = RapidRailsTemplate::ExecutionPlan.build(
      RapidRailsTemplate::Configuration.build("profile_features" => %w[avatar]),
      app_id: "sample", app_name: "Sample App"
    )

    assert_includes plan.steps, "configure_profile"
    assert_includes plan.steps, "install_image_cropper"
    assert_includes plan.gems, "boring_avatars"
    refute_includes plan.gems, "haikunator"
    assert_includes plan.artifacts, "app/helpers/avatar_helper.rb"
    assert_includes plan.artifacts, "test/helpers/avatar_helper_test.rb"
    assert_includes plan.artifacts, "app/javascript/controllers/image_crop_controller.js"
    assert_includes plan.artifacts, "test/system/profile_avatar_crop_test.rb"
    assert_includes plan.artifacts, "vendor/javascript/cropperjs.js"
  end

  def test_siwe_plan_adds_siwe_to_devise
    plan = RapidRailsTemplate::ExecutionPlan.build(
      RapidRailsTemplate::Configuration.build("additional_login_methods" => %w[siwe], "deployment" => "none"),
      app_id: "sample", app_name: "Sample App"
    )

    assert_includes plan.gems, "siwe-rb"
    assert_includes plan.gems, "devise"
    assert_includes plan.steps, "install_devise"
    assert_includes plan.steps, "install_siwe"
    assert_includes plan.artifacts, "package.json"
    assert_includes plan.artifacts, "package-lock.json"
    assert_includes plan.artifacts, "app/views/devise/sessions/new.html.erb"
    assert_includes plan.artifacts, "app/javascript/controllers/siwe_sign_in_controller.js"
    assert_includes plan.artifacts, "test/helpers/application_helper_test.rb"
    assert_includes plan.artifacts, "app/views/account/siwe_identities/index.html.erb"
    assert_includes plan.artifacts, "app/views/account/siwe_identities/new.html.erb"
    assert_includes plan.artifacts, "app/views/account/siwe_identities/show.html.erb"
    assert_includes plan.artifacts, "app/views/account/siwe_identities/edit.html.erb"
    assert_includes plan.artifacts, "app/views/layouts/account_settings.html.erb"
    assert_includes plan.artifacts, "app/views/layouts/_account_shell.html.erb"
    assert_includes plan.artifacts, "app/models/siwe_identity.rb"
    assert_includes plan.artifacts, "app/models/siwe_challenge.rb"
    assert_includes plan.artifacts, "lib/devise/siweable.rb"
    assert_includes plan.artifacts, "test/controllers/users/siwe_sessions_controller_test.rb"
    assert_includes plan.artifacts, "config/locales/application.ja.yml"
    assert_includes plan.artifacts, "config/locales/application.en.yml"
    assert_equal plan.artifacts.uniq, plan.artifacts
    assert_includes plan.steps, "prepare_database"
    assert_includes plan.steps, "configure_roles"
    assert_includes plan.artifacts, "app/models/user_role.rb"
    assert_includes plan.artifacts, "app/policies/user_policy.rb"
    assert_includes plan.artifacts, "app/views/admin/users/index.html.erb"
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
      "solid_cache" => "use",
      "action_cable" => "solid_cable",
      "deployment" => "dokploy"
    )
    plan = RapidRailsTemplate::ExecutionPlan.build(configuration, app_id: "sample", app_name: "Sample App")

    assert_includes plan.gems, "web-push"
    assert_includes plan.gems, "solid_queue"
    assert_includes plan.gems, "solid_cache"
    assert_includes plan.gems, "solid_cable"
    assert_equal "solid_queue", configuration["active_job"]
    assert_equal "Web Pushの非同期送信に必要なため", configuration.reasons.fetch("active_job")
    assert_operator plan.steps.index("configure_pwa"), :<, plan.steps.index("configure_web_push")
    assert_operator plan.steps.index("configure_web_push"), :<, plan.steps.index("configure_default_views")
    assert_equal %w[web worker], plan.processes
    assert_includes plan.artifacts, "mise.local.toml"
    assert_includes plan.artifacts, "app/views/pwa/manifest.json.erb"
    assert_includes plan.artifacts, "app/views/pwa/service-worker.js"
    assert_includes plan.artifacts, "app/models/push_subscription.rb"
    assert_includes plan.artifacts, "app/jobs/push_notification_job.rb"
    assert_includes plan.artifacts, "app/services/push_notifier.rb"
    assert_includes plan.artifacts, "app/controllers/notifications_controller.rb"
    assert_includes plan.artifacts, "app/views/notifications/show.html.erb"
  end

  def test_pwa_without_web_push_only_generates_pwa_foundation
    plan = RapidRailsTemplate::ExecutionPlan.build(
      RapidRailsTemplate::Configuration.build("pwa" => "use", "web_push" => "skip"),
      app_id: "sample", app_name: "Sample App"
    )

    assert_includes plan.steps, "configure_pwa"
    refute_includes plan.steps, "configure_web_push"
    assert_includes plan.artifacts, "app/views/pwa/manifest.json.erb"
    refute_includes plan.artifacts, "app/models/push_subscription.rb"
    refute_includes plan.gems, "web-push"
  end
end
