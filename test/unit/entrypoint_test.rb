# frozen_string_literal: true

require_relative "../test_helper"

class EntrypointTest < Minitest::Test
  class UnexpectedPrompt
    def self.choose(*)
      raise "Gum.chooseは呼ばれないはずです"
    end

    def self.confirm(*)
      raise "Gum.confirmは呼ばれないはずです"
    end
  end

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
    output = StringIO.new
    arguments = RapidRailsTemplate::Configuration::DEFAULTS.map do |id, value|
      serialized = value.is_a?(Array) ? value.join(",") : value
      "--#{id.tr('_', '-')}=#{serialized}"
    end

    status = RapidRailsTemplate::Entrypoint.run(
      [*arguments, "sample"],
      output:,
      error: StringIO.new,
      runner_class: RecordingRunner,
      prompt: UnexpectedPrompt
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
      runner_class: RecordingRunner,
      prompt: UnexpectedPrompt
    )

    assert_equal 1, status
    assert_includes error.string, "不明なオプションです: --defaults"
  end

  def test_non_applicable_option_can_be_omitted_without_reading_input
    answers = RapidRailsTemplate::Configuration::DEFAULTS.reject { |id, _| id == "web_push" }
    arguments = answers.map do |id, value|
      serialized = value.is_a?(Array) ? value.join(",") : value
      "--#{id.tr('_', '-')}=#{serialized}"
    end

    status = RapidRailsTemplate::Entrypoint.run(
      [*arguments, "sample"],
      output: StringIO.new,
      error: StringIO.new,
      runner_class: RecordingRunner,
      prompt: UnexpectedPrompt
    )

    assert_equal 0, status
    assert_equal "skip", RecordingRunner.arguments.fetch(:plan).configuration["web_push"]
  end

  def test_profile_features_accept_comma_separated_values
    arguments = RapidRailsTemplate::Configuration::DEFAULTS.map do |id, value|
      serialized = value.is_a?(Array) ? "avatar,screen_name" : value
      "--#{id.tr('_', '-')}=#{serialized}"
    end

    status = RapidRailsTemplate::Entrypoint.run(
      [*arguments, "sample"],
      output: StringIO.new,
      error: StringIO.new,
      runner_class: RecordingRunner,
      prompt: UnexpectedPrompt
    )

    assert_equal 0, status
    assert_equal %w[screen_name avatar], RecordingRunner.arguments.fetch(:plan).configuration["profile_features"]
  end

  def test_empty_profile_features_value_disables_profiles_without_prompting
    arguments = RapidRailsTemplate::Configuration::DEFAULTS.map do |id, value|
      serialized = id == "profile_features" ? "" : value
      "--#{id.tr('_', '-')}=#{serialized}"
    end

    status = RapidRailsTemplate::Entrypoint.run(
      [*arguments, "sample"],
      output: StringIO.new,
      error: StringIO.new,
      runner_class: RecordingRunner,
      prompt: UnexpectedPrompt
    )

    assert_equal 0, status
    assert_empty RecordingRunner.arguments.fetch(:plan).configuration["profile_features"]
  end

  def test_rejects_unknown_duplicate_and_blank_profile_features
    ["screen_name,unknown", "avatar,avatar", "screen_name,"].each do |value|
      error = StringIO.new

      status = RapidRailsTemplate::Entrypoint.run(
        ["--profile-features=#{value}", "sample"],
        error:,
        runner_class: RecordingRunner,
        prompt: UnexpectedPrompt
      )

      assert_equal 1, status
      assert_includes error.string, "--profile-featuresの値が不正です"
    end
  end

  def test_rejects_unknown_option
    error = StringIO.new

    status = RapidRailsTemplate::Entrypoint.run(
      ["--unknown", "sample"],
      error:,
      runner_class: RecordingRunner,
      prompt: UnexpectedPrompt
    )

    assert_equal 1, status
    assert_includes error.string, "[OPTIONS]"
    assert_includes error.string, "--account-authentication=devise|wallet_siwe"
  end
end
