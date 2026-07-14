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
end
