# frozen_string_literal: true

module RapidRailsTemplate
  class ExecutionPlan
    attr_reader :app_name, :configuration, :generator_options, :gems, :steps, :artifacts, :processes

    def self.build(configuration, app_name:)
      new(configuration, app_name:)
    end

    def initialize(configuration, app_name:)
      @app_name = app_name
      @configuration = configuration
      @generator_options = ["--name=#{app_name}", *GeneratorOptions.build(configuration)].freeze
      @gems = build_gems.freeze
      @steps = build_steps.freeze
      @artifacts = build_artifacts.freeze
      @processes = build_processes.freeze
      freeze
    end

    def to_h
      {
        "app_name" => app_name,
        "configuration" => configuration.to_h,
        "generator_options" => generator_options,
        "gems" => gems,
        "steps" => steps,
        "artifacts" => artifacts,
        "processes" => processes
      }
    end

    def summary
      lines = ["\n実行計画", "========", "アプリ名: #{app_name}", "実効値:"]
      configuration.values.each { |key, value| lines << "  #{key}: #{value}" }
      configuration.reasons.each { |key, reason| lines << "    (#{key}: #{reason})" }
      lines << "rails new options: #{generator_options.join(' ')}"
      lines << "Gem: #{gems.join(', ')}"
      lines << "Steps: #{steps.join(' -> ')}"
      lines << "生成物: #{artifacts.empty? ? '(なし)' : artifacts.join(', ')}"
      lines << "Production processes: #{processes.empty? ? '(未設定)' : processes.join(', ')}"
      lines.join("\n")
    end

    private

    def build_gems
      result = %w[pagy active_link_to action_policy sentry-ruby sentry-rails lexxy capybara capybara-playwright-driver factory_bot factory_bot_rails annotaterb ruby-lsp ruby-lsp-rails rubocop-rails rubocop-thread_safety momocop prism]
      result << "devise" if configuration["account_authentication"] == "devise"
      result << "siwe-rb" if configuration["account_authentication"] == "wallet_siwe"
      result << "haikunator" if (configuration["profile_features"] & %w[screen_name display_name]).any?
      result << "boring_avatars" if configuration["profile_features"].include?("avatar")
      result << "web-push" if configuration["web_push"] == "use"
      result << "solid_queue" if configuration["active_job"] == "solid_queue"
      result << "solid_cache" if configuration["solid_cache"] == "use"
      result << "solid_cable" if configuration["action_cable"] == "solid_cable"
      result << "foreman" if configuration["deployment"] == "dokploy"
      result
    end

    def build_steps
      result = %w[declare_gems install_action_text configure_lexxy install_daisyui configure_generator_view_templates configure_rubocop configure_test_stack configure_evidence_capture install_annotaterb configure_application_gems]
      result << (configuration["account_authentication"] == "devise" ? "install_devise" : "install_wallet_siwe")
      result << "configure_roles"
      result << "configure_content_management"
      result << "configure_profile" if configuration["profile_features"].any?
      result << "configure_api" if configuration["api"] == "enable"
      result << "configure_default_views"
      result << "configure_web_push" if configuration["web_push"] == "use"
      result << "install_solid_queue" if configuration["active_job"] == "solid_queue"
      result << "install_solid_cache" if configuration["solid_cache"] == "use"
      result << "install_solid_cable" if configuration["action_cable"] == "solid_cable"
      result << "configure_dokploy" if configuration["deployment"] == "dokploy"
      result << "prepare_database"
      result << "annotate_models"
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
        test/support/evidence_capture.rb
        lib/tasks/evidence.rake
        app/models/user_role.rb
        app/policies/application_policy.rb
        app/policies/user_policy.rb
        app/controllers/admin/base_controller.rb
        app/controllers/admin/users_controller.rb
        app/controllers/admin/user_roles_controller.rb
        app/views/admin/users/index.html.erb
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
        lib/tasks/roles.rake
        db/seeds.local.rb.example
        config/locales/roles.ja.yml
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
        app/views/layouts/account.html.erb
        app/views/layouts/admin.html.erb
        app/views/shared/_header.html.erb
        app/views/shared/_admin_navigation.html.erb
        app/views/shared/_flash.html.erb
        app/views/shared/_footer.html.erb
        app/views/home/index.html.erb
        app/views/accounts/show.html.erb
        test/integration/default_pages_test.rb
      ]
      if configuration["api"] == "enable"
        result.concat(%w[
          app/models/api_credential.rb
          app/controllers/api/api_controller.rb
          app/controllers/api/api_credentials_controller.rb
          app/controllers/api_credentials_controller.rb
          app/javascript/controllers/clipboard_controller.js
          app/views/api_credentials/index.html.erb
          app/views/api_credentials/show.html.erb
          app/views/api_credentials/new.html.erb
          app/views/api_credentials/edit.html.erb
          app/views/api_credentials/_form.html.erb
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
          config/locales/ja.yml
          test/models/profile_test.rb
        ])
      end
      if configuration["profile_features"].include?("avatar")
        result.concat(%w[
          app/helpers/avatar_helper.rb
          test/helpers/avatar_helper_test.rb
        ])
      end
      if configuration["account_authentication"] == "devise"
        result.concat(%w[
          app/controllers/users/registrations_controller.rb
          app/views/devise/sessions/new.html.erb
          app/views/devise/registrations/new.html.erb
          app/views/devise/registrations/edit.html.erb
          app/views/devise/passwords/new.html.erb
          app/views/devise/passwords/edit.html.erb
        ])
      else
        result << "app/views/sessions/new.html.erb"
        result << "app/javascript/controllers/siwe_sign_in_controller.js"
        result << "app/views/accounts/edit.html.erb"
        result << "config/locales/ja.yml"
      end
      result.concat(%w[Dockerfile.prod .dockerignore bin/docker-entrypoint Procfile.prod litestream.yml]) if configuration["deployment"] == "dokploy"
      result << "mise.local.toml" if configuration["web_push"] == "use"
      result.uniq
    end

    def build_processes
      return [] unless configuration["deployment"] == "dokploy"

      result = ["web"]
      result << "worker" if configuration["active_job"] == "solid_queue"
      result
    end
  end
end
