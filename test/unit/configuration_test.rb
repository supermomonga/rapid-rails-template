# frozen_string_literal: true

require_relative "../test_helper"

class ConfigurationTest < Minitest::Test
  def test_defaults_match_confirmed_product_decisions
    configuration = RapidRailsTemplate::Configuration.build({})

    assert_equal "skip", configuration["pwa"]
    assert_equal "skip", configuration["web_push"]
    assert_equal "skip", configuration["active_job"]
    assert_equal "use", configuration["solid_cache"]
    assert_equal "devise", configuration["account_authentication"]
    assert_equal %w[screen_name display_name avatar], configuration["profile_features"]
    assert_equal "enable", configuration["api"]
    assert_equal "skip", configuration["action_cable"]
    assert_equal "use", configuration["mail"]
  end

  def test_non_applicable_web_push_is_explicitly_normalized
    configuration = RapidRailsTemplate::Configuration.build("pwa" => "skip")

    assert_equal "skip", configuration["web_push"]
    assert_equal "PWAを使用しないため", configuration.reasons["web_push"]
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
