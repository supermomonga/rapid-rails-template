# frozen_string_literal: true

require_relative "../test_helper"

class EntrypointTest < Minitest::Test
  class RecordingRunner
    class << self
      attr_accessor :arguments
    end

    def initialize(**arguments)
      self.class.arguments = arguments
    end

    def run
      0
    end
  end

  def test_individual_options_run_without_reading_input_when_all_are_specified
    input = StringIO.new
    output = StringIO.new
    arguments = RapidRailsTemplate::Configuration::DEFAULTS.map do |id, value|
      "--#{id.tr('_', '-')}=#{value}"
    end

    status = RapidRailsTemplate::Entrypoint.run(
      [*arguments, "sample"],
      input:,
      output:,
      error: StringIO.new,
      runner_class: RecordingRunner
    )

    assert_equal 0, status
    assert_equal "sample", RecordingRunner.arguments.fetch(:app_path)
    assert_equal RapidRailsTemplate::Configuration::DEFAULTS,
                 RecordingRunner.arguments.fetch(:plan).configuration.answers
    assert_includes output.string, "実行計画"
  end

  def test_defaults_option_is_rejected
    error = StringIO.new

    status = RapidRailsTemplate::Entrypoint.run(
      ["--defaults", "sample"],
      error:,
      runner_class: RecordingRunner
    )

    assert_equal 1, status
    assert_includes error.string, "不明なオプションです: --defaults"
  end

  def test_non_applicable_option_can_be_omitted_without_reading_input
    input = StringIO.new
    answers = RapidRailsTemplate::Configuration::DEFAULTS.reject { |id, _| id == "web_push" }
    arguments = answers.map { |id, value| "--#{id.tr('_', '-')}=#{value}" }

    status = RapidRailsTemplate::Entrypoint.run(
      [*arguments, "sample"],
      input:,
      output: StringIO.new,
      error: StringIO.new,
      runner_class: RecordingRunner
    )

    assert_equal 0, status
    assert_equal "skip", RecordingRunner.arguments.fetch(:plan).configuration["web_push"]
  end

  def test_rejects_unknown_option
    error = StringIO.new

    status = RapidRailsTemplate::Entrypoint.run(
      ["--unknown", "sample"],
      error:,
      runner_class: RecordingRunner
    )

    assert_equal 1, status
    assert_includes error.string, "[OPTIONS]"
    assert_includes error.string, "--account-authentication=devise|wallet_siwe"
  end
end
