# frozen_string_literal: true

require_relative "../test_helper"

class ConfigurationTest < Minitest::Test
  def test_defaults_match_confirmed_product_decisions
    configuration = RapidRailsTemplate::Configuration.build({})

    assert_equal "skip", configuration["pwa"]
    assert_equal "skip", configuration["web_push"]
    assert_equal "skip", configuration["active_job"]
    assert_equal "disable", configuration["job_operations"]
    assert_equal "Solid Queueを使用しないため", configuration.reasons["job_operations"]
    assert_equal "disable", configuration["maintenance_tasks"]
    assert_equal "Solid Queueを使用しないため", configuration.reasons["maintenance_tasks"]
    assert_equal "use", configuration["solid_cache"]
    assert_equal "devise", configuration["account_authentication"]
    assert_equal %w[screen_name display_name avatar], configuration["profile_features"]
    assert_equal "rails", configuration["image_delivery"]
    assert_equal "enable", configuration["api"]
    assert_equal "skip", configuration["action_cable"]
    assert_equal "use", configuration["mail"]
    assert_equal "ja", configuration["default_locale"]
    refute_includes configuration.answers, "action_text"
  end

  def test_non_applicable_web_push_is_explicitly_normalized
    configuration = RapidRailsTemplate::Configuration.build("pwa" => "skip")

    assert_equal "skip", configuration["web_push"]
    assert_equal "PWAを使用しないため", configuration.reasons["web_push"]
  end

  def test_web_push_requires_pwa_and_normalizes_active_job_to_solid_queue
    configuration = RapidRailsTemplate::Configuration.build("pwa" => "use", "web_push" => "use")

    assert_equal "solid_queue", configuration["active_job"]
    assert_equal "enable", configuration["job_operations"]
    assert_equal "enable", configuration["maintenance_tasks"]
    assert_equal "Web Pushの非同期送信に必要なため", configuration.reasons["active_job"]

    assert_raises(RapidRailsTemplate::InvalidConfiguration) do
      RapidRailsTemplate::Configuration.build("pwa" => "skip", "web_push" => "use")
    end
    assert_raises(RapidRailsTemplate::InvalidConfiguration) do
      RapidRailsTemplate::Configuration.build("pwa" => "use", "web_push" => "use", "active_job" => "skip")
    end
  end

  def test_job_operations_defaults_to_enabled_with_solid_queue
    configuration = RapidRailsTemplate::Configuration.build("active_job" => "solid_queue")

    assert_equal "enable", configuration["job_operations"]
    refute configuration.reasons.key?("job_operations")
  end

  def test_job_operations_requires_solid_queue_when_explicitly_enabled
    error = assert_raises(RapidRailsTemplate::InvalidConfiguration) do
      RapidRailsTemplate::Configuration.build(
        "active_job" => "skip",
        "job_operations" => "enable"
      )
    end

    assert_equal "ジョブ運用画面使用時はSolid Queueが必要です", error.message
  end

  def test_maintenance_tasks_requires_solid_queue
    configuration = RapidRailsTemplate::Configuration.build(
      "active_job" => "solid_queue",
      "maintenance_tasks" => "enable"
    )

    assert_equal "enable", configuration["maintenance_tasks"]

    error = assert_raises(RapidRailsTemplate::InvalidConfiguration) do
      RapidRailsTemplate::Configuration.build(
        "active_job" => "skip",
        "maintenance_tasks" => "enable"
      )
    end
    assert_equal "Maintenance Tasks使用時はSolid Queueが必要です", error.message
  end

  def test_mail_auto_is_disabled_for_wallet_siwe
    configuration = RapidRailsTemplate::Configuration.build("account_authentication" => "wallet_siwe")

    assert_equal "skip", configuration["mail"]
  end

  def test_rejects_invalid_choice
    assert_raises(RapidRailsTemplate::InvalidConfiguration) do
      RapidRailsTemplate::Configuration.build("pwa" => "maybe")
    end
  end

  def test_accepts_only_explicit_image_delivery_modes
    assert_equal "rails", RapidRailsTemplate::Configuration.build("image_delivery" => "rails")["image_delivery"]
    assert_equal "imgproxy", RapidRailsTemplate::Configuration.build("image_delivery" => "imgproxy")["image_delivery"]
    assert_raises(RapidRailsTemplate::InvalidConfiguration) do
      RapidRailsTemplate::Configuration.build("image_delivery" => "auto")
    end
  end

  def test_accepts_supported_default_locales
    assert_equal "ja", RapidRailsTemplate::Configuration.build("default_locale" => "ja")["default_locale"]
    assert_equal "en", RapidRailsTemplate::Configuration.build("default_locale" => "en")["default_locale"]
  end

  def test_accepts_an_empty_profile_feature_selection
    configuration = RapidRailsTemplate::Configuration.build("profile_features" => [])

    assert_empty configuration["profile_features"]
  end

  def test_rejects_unknown_or_duplicate_profile_features
    assert_raises(RapidRailsTemplate::InvalidConfiguration) do
      RapidRailsTemplate::Configuration.build("profile_features" => %w[screen_name unknown])
    end
    assert_raises(RapidRailsTemplate::InvalidConfiguration) do
      RapidRailsTemplate::Configuration.build("profile_features" => %w[avatar avatar])
    end
  end
end
