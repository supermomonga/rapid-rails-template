# frozen_string_literal: true

require_relative "../test_helper"

class RunnerTest < Minitest::Test
  FakeStatus = Data.define(:exitstatus)

  class FakeProcessRunner
    attr_reader :config_path, :template_path

    def popen3(environment, *command)
      @config_path = environment.fetch("RAPID_RAILS_TEMPLATE_CONFIG")
      @template_path = command.last
      yield StringIO.new, StringIO.new, StringIO.new, Thread.new { FakeStatus.new(0) }
    end
  end

  def test_rails_command_activates_supported_railties_and_preserves_path_as_one_argument
    app_path = "/tmp/path with spaces & metacharacters"
    plan = RapidRailsTemplate::ExecutionPlan.build(
      RapidRailsTemplate::Configuration.build({}),
      app_id: "custom_app", app_name: "Custom App & Service"
    )
    runner = RapidRailsTemplate::Runner.new(app_path:, plan:, template_payload: "")
    command = runner.send(:rails_command, "/tmp/template.rb")

    assert_equal RbConfig.ruby, command.fetch(0)
    assert_equal %w[-rrubygems -e], command[1, 2]
    assert_equal RapidRailsTemplate::Runner::RAILS_LAUNCHER, command.fetch(3)
    assert_equal "--", command.fetch(4)
    assert_equal "new", command.fetch(5)
    assert_equal app_path, command.fetch(6)
    assert_equal "--name=custom_app", command.fetch(7)
    refute_includes command, "Custom App & Service"
    assert_equal "/tmp/template.rb", command.last
  end

  def test_removes_configuration_and_template_tempfiles_after_process_finishes
    plan = RapidRailsTemplate::ExecutionPlan.build(
      RapidRailsTemplate::Configuration.build({}),
      app_id: "example", app_name: "Example"
    )
    process_runner = FakeProcessRunner.new
    runner = RapidRailsTemplate::Runner.new(
      app_path: "/tmp/example",
      plan:,
      template_payload: "payload",
      process_runner:
    )

    assert_equal 0, runner.run
    refute_path_exists process_runner.config_path
    refute_path_exists process_runner.template_path
  end
end
