# frozen_string_literal: true

module RapidRailsTemplate
  class ExecutionPlan
    attr_reader :app_id, :app_name, :configuration, :generator_options, :gems, :steps, :artifacts, :processes,
      :production_requirements

    def self.build(configuration, app_id:, app_name:)
      new(configuration, app_id:, app_name:)
    end

    def initialize(configuration, app_id:, app_name:)
      @app_id = app_id
      @app_name = app_name
      @configuration = configuration
      @generator_options = ["--name=#{app_id}", *GeneratorOptions.build(configuration)].freeze
      @gems = build_gems.freeze
      @steps = build_steps.freeze
      @artifacts = build_artifacts.freeze
      @processes = build_processes.freeze
      @production_requirements = build_production_requirements.freeze
      freeze
    end

    def to_h
      {
        "app_id" => app_id,
        "app_name" => app_name,
        "configuration" => configuration.to_h,
        "generator_options" => generator_options,
        "gems" => gems,
        "steps" => steps,
        "artifacts" => artifacts,
        "processes" => processes,
        "production_requirements" => production_requirements
      }
    end

    def summary
      lines = ["\n実行計画", "========", "RailsアプリID: #{app_id}", "表示用アプリ名: #{app_name}", "実効値:"]
      configuration.values.each { |key, value| lines << "  #{key}: #{value}" }
      configuration.reasons.each { |key, reason| lines << "    (#{key}: #{reason})" }
      lines << "rails new options: #{generator_options.join(' ')}"
      lines << "Gem: #{gems.join(', ')}"
      lines << "Steps: #{steps.join(' -> ')}"
      lines << "生成物: #{artifacts.empty? ? '(なし)' : artifacts.join(', ')}"
      lines << "Production processes: #{processes.empty? ? '(未設定)' : processes.join(', ')}"
      lines << "Production requirements: #{production_requirements.empty? ? '(なし)' : production_requirements.join(', ')}"
      lines.join("\n")
    end

    private

    def build_gems
      result = %w[pagy active_link_to action_policy sentry-ruby sentry-rails lexxy active_storage_db rails-i18n capybara capybara-playwright-driver factory_bot factory_bot_rails annotaterb sorbet sorbet-runtime tapioca ruby-lsp ruby-lsp-rails rubocop-rails rubocop-thread_safety momocop prism]
      result.concat(%w[devise devise-i18n webauthn])
      result << "siwe-rb" if configuration["additional_login_methods"].include?("siwe")
      result << "haikunator" if (configuration["profile_features"] & %w[screen_name display_name]).any?
      result << "boring_avatars" if configuration["profile_features"].include?("avatar")
      result << "thruster"
      result << "web-push" if configuration["web_push"] == "use"
      result << "solid_queue" if configuration["active_job"] == "solid_queue"
      result << "mission_control-jobs" if configuration["job_operations"] == "enable"
      result << "maintenance_tasks" if configuration["maintenance_tasks"] == "enable"
      result << "solid_cache" if configuration["solid_cache"] == "use"
      result << "solid_cable" if configuration["action_cable"] == "solid_cable"
      result << "kamal"
      result
    end

    def build_steps
      result = %w[declare_gems install_action_text install_active_storage_db configure_lexxy install_daisyui configure_generator_view_templates configure_rubocop configure_test_stack configure_evidence_capture install_annotaterb configure_application_gems configure_application_identity configure_image_delivery]
      result << "install_devise"
      result << "install_siwe" if configuration["additional_login_methods"].include?("siwe")
      result << "configure_roles"
      result << "configure_content_management"
      result << "install_image_cropper" if configuration["profile_features"].include?("avatar")
      result << "configure_profile" if configuration["profile_features"].any?
      result << "configure_api" if configuration["api"] == "enable"
      result << "configure_pwa" if configuration["pwa"] == "use"
      result << "configure_web_push" if configuration["web_push"] == "use"
      result << "configure_default_views"
      result << "install_solid_queue" if configuration["active_job"] == "solid_queue"
      result << "install_job_operations" if configuration["job_operations"] == "enable"
      result << "install_maintenance_tasks" if configuration["maintenance_tasks"] == "enable"
      result << "install_solid_cache" if configuration["solid_cache"] == "use"
      result << "install_solid_cable" if configuration["action_cable"] == "solid_cable"
      result << "configure_database"
      result << "configure_active_storage_db"
      result << "configure_kamal"
      result << "prepare_database"
      result << "annotate_models"
      result << "initialize_sorbet"
      result << "prepare_test_database"
      result << "generate_sorbet_dsl"
      result << "typecheck_application"
      result << "resolve_sorbet_todos"
      result << "verify_sorbet"
      result << "verify"
      result
    end

    def build_artifacts
      result = %w[
        package.json
        package-lock.json
        .annotaterb.yml
        lib/tasks/annotate_rb.rake
        bin/annotaterb
        test/annotations_test.rb
        bin/tapioca
        sorbet/config
        sorbet/tapioca/config.yml
        sorbet/tapioca/require.rb
        sorbet/rbi/shims/framework_bindings.rbi
        sorbet/rbi/shims/bundler_connection_pool.rbi
        sorbet/rbi/**/*
        test/sorbet_test.rb
        db/seeds.rb
        test/support/evidence_capture.rb
        lib/tasks/evidence.rake
        app/models/user_role.rb
        lib/application_identity.rb
        config/application_identity.yml
        config/initializers/application_identity.rb
        app/controllers/concerns/localized_request.rb
        app/helpers/application_helper.rb
        test/helpers/application_helper_test.rb
        config/locales/application.ja.yml
        config/locales/application.en.yml
        test/lib/application_identity_test.rb
        test/i18n_locale_test.rb
        app/policies/application_policy.rb
        app/policies/user_policy.rb
        app/controllers/admin/base_controller.rb
        app/controllers/admin/users_controller.rb
        app/controllers/admin/user_roles_controller.rb
        app/views/admin/users/index.html.erb
        app/services/admin_role_grant.rb
        app/models/page.rb
        app/models/faq.rb
        app/models/footer_setting.rb
        app/policies/page_policy.rb
        app/policies/faq_policy.rb
        app/policies/footer_setting_policy.rb
        app/controllers/pages_controller.rb
        app/controllers/faqs_controller.rb
        app/controllers/admin/pages_controller.rb
        app/controllers/admin/faqs_controller.rb
        app/controllers/admin/footer_settings_controller.rb
        app/views/pages/about.html.erb
        app/views/pages/corp.html.erb
        app/views/pages/manual.html.erb
        app/views/pages/terms.html.erb
        app/views/pages/privacy.html.erb
        app/views/pages/transaction-law.html.erb
        app/views/faqs/index.html.erb
        app/views/admin/pages/index.html.erb
        app/views/admin/pages/edit.html.erb
        app/views/admin/faqs/index.html.erb
        app/views/admin/faqs/new.html.erb
        app/views/admin/faqs/edit.html.erb
        app/views/admin/faqs/_form.html.erb
        app/views/admin/footer_settings/edit.html.erb
        app/views/layouts/action_text/contents/_content.html.erb
        config/locales/content_management.ja.yml
        config/locales/content_management.en.yml
        lib/tasks/roles.rake
        db/seeds.local.rb.example
        config/locales/roles.ja.yml
        config/locales/roles.en.yml
        test/fixtures/user_roles.yml
        test/models/user_role_test.rb
        test/policies/user_policy_test.rb
        test/controllers/admin/users_controller_test.rb
        test/controllers/admin/user_roles_controller_test.rb
        test/models/page_test.rb
        test/models/faq_test.rb
        test/models/footer_setting_test.rb
        test/policies/content_management_policy_test.rb
        test/controllers/pages_controller_test.rb
        test/controllers/faqs_controller_test.rb
        test/controllers/admin/pages_controller_test.rb
        test/controllers/admin/faqs_controller_test.rb
        test/controllers/admin/footer_settings_controller_test.rb
        test/tasks/roles_task_test.rb
        app/assets/tailwind/application.css
        lib/templates/erb/scaffold/index.html.erb.tt
        lib/templates/erb/scaffold/show.html.erb.tt
        lib/templates/erb/scaffold/new.html.erb.tt
        lib/templates/erb/scaffold/edit.html.erb.tt
        lib/templates/erb/scaffold/_form.html.erb.tt
        lib/templates/erb/scaffold/partial.html.erb.tt
        lib/templates/erb/controller/view.html.erb.tt
        app/controllers/home_controller.rb
        app/controllers/accounts_controller.rb
        app/views/layouts/application.html.erb
        app/views/layouts/authentication.html.erb
        app/views/layouts/_with_menu.html.erb
        app/views/layouts/_account_shell.html.erb
        app/views/layouts/account.html.erb
        app/views/layouts/admin.html.erb
        app/views/shared/_header.html.erb
        app/views/shared/_account_navigation.html.erb
        app/views/shared/_admin_navigation.html.erb
        app/views/shared/_flash.html.erb
        app/views/shared/_footer.html.erb
        app/views/home/index.html.erb
        app/views/accounts/show.html.erb
        test/integration/default_pages_test.rb
        config/storage.yml
        config/initializers/active_storage_db.rb
        db/storage_migrate/*_create_active_storage_db_files.active_storage_db.rb
        test/models/active_storage_db_test.rb
        test/integration/image_delivery_test.rb
        docs/image_delivery.md
        test/support/image_test_fixture.rb
      ]
      result << "bin/thrust"
      result << "sorbet/rbi/shims/boring_avatars.rbi" if configuration["profile_features"].include?("avatar")
      if configuration["api"] == "enable"
        result.concat(%w[
          app/models/api_credential.rb
          app/controllers/api/api_controller.rb
          app/controllers/api/api_credentials_controller.rb
          app/controllers/api_credentials_controller.rb
          app/views/api_credentials/index.html.erb
          app/views/api_credentials/show.html.erb
          app/views/api_credentials/new.html.erb
          app/views/api_credentials/edit.html.erb
          app/views/api_credentials/_form.html.erb
          config/locales/api_credentials.ja.yml
          config/locales/api_credentials.en.yml
          test/models/api_credential_test.rb
          test/controllers/api/api_credentials_controller_test.rb
          test/controllers/api_credentials_controller_test.rb
        ])
      end
      if configuration["profile_features"].any?
        result.concat(%w[
          app/models/profile.rb
          app/controllers/profiles_controller.rb
          app/views/profiles/show.html.erb
          app/views/profiles/edit.html.erb
          app/views/profiles/_form.html.erb
          config/locales/profiles.ja.yml
          config/locales/profiles.en.yml
          test/models/profile_test.rb
        ])
      end
      if configuration["profile_features"].include?("avatar")
        result.concat(%w[
          app/javascript/controllers/image_crop_controller.js
          app/services/avatar_image_policy.rb
          app/services/avatar_upload.rb
          app/validators/avatar_upload_validator.rb
          app/helpers/avatar_helper.rb
          test/services/avatar_image_policy_test.rb
          test/helpers/avatar_helper_test.rb
          test/system/profile_avatar_crop_test.rb
          vendor/javascript/cropperjs.js
          vendor/javascript/@cropper--element.js
          vendor/javascript/@cropper--element-canvas.js
          vendor/javascript/@cropper--element-crosshair.js
          vendor/javascript/@cropper--element-grid.js
          vendor/javascript/@cropper--element-handle.js
          vendor/javascript/@cropper--element-image.js
          vendor/javascript/@cropper--element-selection.js
          vendor/javascript/@cropper--element-shade.js
          vendor/javascript/@cropper--element-viewer.js
          vendor/javascript/@cropper--elements.js
          vendor/javascript/@cropper--utils.js
        ])
      end
      result.concat(%w[
        app/models/passkey_credential.rb
        app/models/webauthn_challenge.rb
        app/services/credential_destruction.rb
        app/controllers/concerns/webauthn_request.rb
        app/controllers/users/passkey_sessions_controller.rb
        app/controllers/users/passkey_registrations_controller.rb
        app/controllers/account/passkeys_controller.rb
        app/controllers/account/credential_destructions_controller.rb
        app/javascript/controllers/passkey_controller.js
        app/javascript/controllers/clipboard_controller.js
        app/views/users/passkey_sessions/new.html.erb
        app/views/users/passkey_registrations/new.html.erb
        app/views/account/passkeys/index.html.erb
        app/views/account/passkeys/new.html.erb
        app/views/account/passkeys/show.html.erb
        app/views/account/passkeys/edit.html.erb
        app/views/accounts/delete.html.erb
        app/views/layouts/account_settings.html.erb
        config/initializers/devise_passkey_authenticatable.rb
        config/initializers/webauthn.rb
        config/locales/authentication.ja.yml
        config/locales/authentication.en.yml
        config/locales/passkeys.ja.yml
        config/locales/passkeys.en.yml
        lib/devise/models/passkey_authenticatable.rb
        lib/devise/passkey_authenticatable.rb
        db/migrate/*_create_passkey_credentials.rb
        db/migrate/*_create_webauthn_challenges.rb
        test/models/passkey_credential_test.rb
        test/models/webauthn_challenge_test.rb
        test/controllers/users/passkey_authentication_controller_test.rb
      ])
      if configuration["additional_login_methods"].include?("siwe")
        result.concat(%w[
          app/models/siwe_identity.rb
          app/models/siwe_challenge.rb
          lib/devise/models/siweable.rb
          lib/devise/siweable.rb
          app/controllers/users/siwe_sessions_controller.rb
          app/controllers/users/siwe_registrations_controller.rb
          app/controllers/account/siwe_identities_controller.rb
          app/javascript/controllers/siwe_sign_in_controller.js
          app/views/account/siwe_identities/index.html.erb
          app/views/account/siwe_identities/new.html.erb
          app/views/account/siwe_identities/show.html.erb
          app/views/account/siwe_identities/edit.html.erb
          config/initializers/devise_siweable.rb
          config/locales/siwe.ja.yml
          config/locales/siwe.en.yml
          db/migrate/*_create_siwe_identities.rb
          db/migrate/*_create_siwe_challenges.rb
          test/models/siwe_identity_test.rb
          test/models/siwe_challenge_test.rb
          test/controllers/users/siwe_sessions_controller_test.rb
          test/controllers/account/siwe_identities_controller_test.rb
        ])
      end
      if configuration["pwa"] == "use"
        result.concat(%w[
          app/views/pwa/manifest.json.erb
          app/views/pwa/service-worker.js
          app/javascript/controllers/pwa_controller.js
          test/integration/pwa_identity_test.rb
        ])
      end
      if configuration["web_push"] == "use"
        result.concat(%w[
          app/models/push_subscription.rb
          app/controllers/push_subscriptions_controller.rb
          app/controllers/notifications_controller.rb
          app/jobs/push_notification_job.rb
          app/services/push_notification_payload.rb
          app/services/push_notifier.rb
          app/services/vapid_configuration.rb
          app/javascript/controllers/push_subscription_controller.js
          app/views/notifications/show.html.erb
          config/locales/web_push.ja.yml
          config/locales/web_push.en.yml
          test/models/push_subscription_test.rb
          test/controllers/push_subscriptions_controller_test.rb
          test/jobs/push_notification_job_test.rb
          test/services/push_notifier_test.rb
        ])
      end
      if configuration["maintenance_tasks"] == "enable"
        result.concat(%w[
          config/initializers/maintenance_tasks.rb
          app/controllers/admin/maintenance_tasks_controller.rb
          app/helpers/admin/maintenance_tasks_helper.rb
          app/policies/maintenance_task_policy.rb
          app/views/layouts/maintenance_tasks/admin.html.erb
          app/views/maintenance_tasks/tasks/*.html.erb
          app/views/maintenance_tasks/runs/*.html.erb
          app/views/maintenance_tasks/runs/info/_errored.html.erb
          app/javascript/controllers/maintenance_tasks_refresh_controller.js
          config/locales/maintenance_tasks.ja.yml
          config/locales/maintenance_tasks.en.yml
          db/migrate/*_maintenance_tasks.rb
          docs/maintenance_tasks.md
          test/policies/maintenance_task_policy_test.rb
          test/controllers/admin/maintenance_tasks_controller_test.rb
          test/support/maintenance_tasks/safe_test_task.rb
        ])
      end
      if configuration["job_operations"] == "enable"
        result.concat(%w[
          config/initializers/mission_control_jobs.rb
          app/controllers/admin/job_operations_controller.rb
          app/helpers/admin/job_operations_helper.rb
          app/policies/job_operation_policy.rb
          app/views/layouts/mission_control/jobs/application.html.erb
          app/views/layouts/mission_control/jobs/*.html.erb
          app/views/mission_control/jobs/**/*.html.erb
          config/locales/job_operations.ja.yml
          config/locales/job_operations.en.yml
          docs/job_operations.md
          test/policies/job_operation_policy_test.rb
          test/controllers/admin/job_operations_controller_test.rb
          test/models/solid_queue_cleanup_test.rb
        ])
      end
      result.concat(%w[
        Dockerfile
        .dockerignore
        .kamal/secrets
        .kamal/hooks/pre-deploy
        config/deploy.yml
        config/litestream.yml
        bin/docker-entrypoint
        bin/wait-for-litestream
        bin/kamal-restore
        bin/kamal-restore-volume
        docs/deployment.md
      ])
      result << "mise.local.toml" if configuration["web_push"] == "use"
      result.uniq
    end

    def build_processes
      result = ["web"]
      result << "worker" if configuration["active_job"] == "solid_queue"
      result
    end

    def build_production_requirements
      result = []
      if configuration["active_job"] == "solid_queue"
        result << "Solid Queue worker/dispatcher/scheduler"
        result << "finished jobs retained for 1 day; failed jobs retained until retry/discard"
      end
      result
    end
  end
end
