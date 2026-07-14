# frozen_string_literal: true

require_relative "../test_helper"

class ExecutionPlanTest < Minitest::Test
  def test_default_plan_installs_only_selected_solid_component
    plan = RapidRailsTemplate::ExecutionPlan.build(RapidRailsTemplate::Configuration.build({}))

    assert_includes plan.gems, "solid_cache"
    refute_includes plan.gems, "solid_queue"
    refute_includes plan.gems, "solid_cable"
    assert_includes plan.gems, "devise"
  end

  def test_wallet_plan_uses_siwe_and_not_devise
    plan = RapidRailsTemplate::ExecutionPlan.build(
      RapidRailsTemplate::Configuration.build("account_authentication" => "wallet_siwe", "deployment" => "none")
    )

    assert_includes plan.gems, "siwe-rb"
    refute_includes plan.gems, "devise"
    assert_empty plan.artifacts
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
