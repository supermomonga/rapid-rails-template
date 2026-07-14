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

  def test_defaults_mode_runs_without_reading_input
    input = StringIO.new
    output = StringIO.new

    status = RapidRailsTemplate::Entrypoint.run(
      ["--defaults", "sample"],
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

  def test_rejects_unknown_option
    error = StringIO.new

    status = RapidRailsTemplate::Entrypoint.run(
      ["--unknown", "sample"],
      error:,
      runner_class: RecordingRunner
    )

    assert_equal 1, status
    assert_includes error.string, "[--defaults]"
  end
end
