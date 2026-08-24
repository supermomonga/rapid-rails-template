# frozen_string_literal: true

require_relative "../test_helper"

class EntrypointTest < Minitest::Test
  class UnexpectedPrompt
    def self.input(*)
      raise "Gum.inputは呼ばれないはずです"
    end

    def self.choose(*)
      raise "Gum.chooseは呼ばれないはずです"
    end

    def self.confirm(*)
      raise "Gum.confirmは呼ばれないはずです"
    end
  end

  class IdentityPrompt
    attr_reader :confirm_calls, :input_calls

    def initialize(input_answers:, confirmation:)
      @input_answers = input_answers.dup
      @confirmation = confirmation
      @input_calls = []
      @confirm_calls = []
    end

    def input(**options)
      @input_calls << options
      @input_answers.shift
    end

    def choose(*)
      raise "Gum.chooseは呼ばれないはずです"
    end

    def confirm(message, **options)
      @confirm_calls << [message, options]
      @confirmation
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

  class UnexpectedRunner
    def initialize(**)
      raise "Runnerは初期化されないはずです"
    end
  end

  def test_individual_options_run_without_reading_input_when_all_are_specified
    output = StringIO.new
    arguments = RapidRailsTemplate::Configuration::DEFAULTS.map do |id, value|
      serialized = value.is_a?(Array) ? value.join(",") : value
      "--#{id.tr('_', '-')}=#{serialized}"
    end
    arguments.unshift("--app-id=sample", "--app-name=Sample App")

    status = RapidRailsTemplate::Entrypoint.run(
      [*arguments, "sample"],
      output:,
      error: StringIO.new,
      runner_class: RecordingRunner,
      prompt: UnexpectedPrompt
    )

    assert_equal 0, status
    assert_equal "sample", RecordingRunner.arguments.fetch(:app_path)
    assert_equal "sample", RecordingRunner.arguments.fetch(:plan).app_id
    assert_equal "Sample App", RecordingRunner.arguments.fetch(:plan).app_name
    assert_equal RapidRailsTemplate::Configuration::DEFAULTS,
                 RecordingRunner.arguments.fetch(:plan).configuration.answers
    assert_includes output.string, "実行計画"
  end

  def test_missing_identity_asks_in_order_and_requires_confirmation
    arguments = RapidRailsTemplate::Configuration::DEFAULTS.map do |id, value|
      serialized = value.is_a?(Array) ? value.join(",") : value
      "--#{id.tr('_', '-')}=#{serialized}"
    end
    prompt = IdentityPrompt.new(input_answers: ["custom_app", "  Custom App & Service  "], confirmation: true)

    status = RapidRailsTemplate::Entrypoint.run(
      [*arguments, "/tmp/generated-app"],
      output: StringIO.new,
      error: StringIO.new,
      runner_class: RecordingRunner,
      prompt:
    )

    assert_equal 0, status
    assert_equal [
      { header: "RailsアプリIDを入力してください。", value: "generated-app" },
      { header: "表示用アプリ名を入力してください。", value: "custom_app" }
    ], prompt.input_calls
    assert_equal 1, prompt.confirm_calls.length
    plan = RecordingRunner.arguments.fetch(:plan)
    assert_equal "custom_app", plan.app_id
    assert_equal "Custom App & Service", plan.app_name
    assert_includes plan.generator_options, "--name=custom_app"
    refute_includes plan.generator_options, "Custom App & Service"
  end

  def test_rejects_missing_blank_and_duplicate_identity_values
    [
      ["--app-id", "sample"],
      ["--app-id=", "sample"],
      ["--app-id=first", "--app-id=second", "sample"],
      ["--app-name", "sample"],
      ["--app-name=", "sample"],
      ["--app-name=   ", "sample"],
      ["--app-name=First", "--app-name=Second", "sample"]
    ].each do |arguments|
      error = StringIO.new

      status = RapidRailsTemplate::Entrypoint.run(
        arguments,
        error:,
        runner_class: RecordingRunner,
        prompt: UnexpectedPrompt
      )

      assert_equal 1, status
      assert_match(/--app-(?:id|name)(?:には値が必要|が複数回指定)/, error.string)
    end
  end

  def test_cancelled_or_empty_interactive_identity_does_not_run
    arguments = RapidRailsTemplate::Configuration::DEFAULTS.map do |id, value|
      serialized = value.is_a?(Array) ? value.join(",") : value
      "--#{id.tr('_', '-')}=#{serialized}"
    end

    [[nil], [""], ["sample", nil], ["sample", " \t "]].each do |input_answers|
      error = StringIO.new
      prompt = IdentityPrompt.new(input_answers:, confirmation: true)

      status = RapidRailsTemplate::Entrypoint.run(
        [*arguments, "sample"],
        output: StringIO.new,
        error:,
        runner_class: UnexpectedRunner,
        prompt:
      )

      assert_equal 1, status
      assert_match(/アプリ(?:ID|名)/, error.string)
      assert_empty prompt.confirm_calls
    end
  end

  def test_rejected_confirmation_after_interactive_identity_does_not_run
    arguments = RapidRailsTemplate::Configuration::DEFAULTS.map do |id, value|
      serialized = value.is_a?(Array) ? value.join(",") : value
      "--#{id.tr('_', '-')}=#{serialized}"
    end
    prompt = IdentityPrompt.new(input_answers: ["sample", "Sample App"], confirmation: false)

    status = RapidRailsTemplate::Entrypoint.run(
      [*arguments, "sample"],
      output: StringIO.new,
      error: StringIO.new,
      runner_class: UnexpectedRunner,
      prompt:
    )

    assert_equal 0, status
    assert_equal 1, prompt.confirm_calls.length
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

  def test_removed_name_option_is_rejected
    error = StringIO.new

    status = RapidRailsTemplate::Entrypoint.run(
      ["--name=sample", "sample"],
      error:,
      runner_class: RecordingRunner,
      prompt: UnexpectedPrompt
    )

    assert_equal 1, status
    assert_includes error.string, "不明なオプションです: --name"
  end

  def test_removed_action_text_option_is_rejected
    error = StringIO.new

    status = RapidRailsTemplate::Entrypoint.run(
      ["--action-text=use", "sample"],
      error:,
      runner_class: RecordingRunner,
      prompt: UnexpectedPrompt
    )

    assert_equal 1, status
    assert_includes error.string, "不明なオプションです: --action-text"
  end

  def test_removed_deployment_option_is_rejected
    error = StringIO.new

    status = RapidRailsTemplate::Entrypoint.run(
      ["--deployment=dokploy", "sample"],
      error:,
      runner_class: RecordingRunner,
      prompt: UnexpectedPrompt
    )

    assert_equal 1, status
    assert_includes error.string, "不明なオプションです: --deployment"
  end

  def test_rejects_maintenance_tasks_without_solid_queue_before_runner_initialization
    error = StringIO.new
    arguments = RapidRailsTemplate::Configuration::DEFAULTS.merge(
      "maintenance_tasks" => "enable",
      "active_job" => "skip",
      "web_push" => "skip",
      "job_operations" => "disable"
    ).map do |id, value|
      serialized = value.is_a?(Array) ? value.join(",") : value
      "--#{id.tr('_', '-')}=#{serialized}"
    end

    status = RapidRailsTemplate::Entrypoint.run(
      ["--app-id=sample", "--app-name=Sample App", *arguments, "sample"],
      output: StringIO.new,
      error:,
      runner_class: UnexpectedRunner,
      prompt: UnexpectedPrompt
    )

    assert_equal 1, status
    assert_includes error.string, "Maintenance Tasks使用時はSolid Queueが必要です"
  end

  def test_rejects_job_operations_without_solid_queue_before_runner_initialization
    error = StringIO.new
    arguments = RapidRailsTemplate::Configuration::DEFAULTS.merge(
      "job_operations" => "enable",
      "active_job" => "skip",
      "web_push" => "skip"
    ).map do |id, value|
      serialized = value.is_a?(Array) ? value.join(",") : value
      "--#{id.tr('_', '-')}=#{serialized}"
    end

    status = RapidRailsTemplate::Entrypoint.run(
      ["--app-id=sample", "--app-name=Sample App", *arguments, "sample"],
      output: StringIO.new,
      error:,
      runner_class: UnexpectedRunner,
      prompt: UnexpectedPrompt
    )

    assert_equal 1, status
    assert_includes error.string, "ジョブ運用画面使用時はSolid Queueが必要です"
  end

  def test_non_applicable_option_can_be_omitted_without_reading_input
    answers = RapidRailsTemplate::Configuration::DEFAULTS.merge("pwa" => "skip").reject { |id, _| id == "web_push" }
    arguments = answers.map do |id, value|
      serialized = value.is_a?(Array) ? value.join(",") : value
      "--#{id.tr('_', '-')}=#{serialized}"
    end
    arguments.unshift("--app-id=sample", "--app-name=Sample App")

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

  def test_additional_login_methods_accept_empty_and_siwe_values
    [[], %w[siwe]].each do |methods|
      arguments = RapidRailsTemplate::Configuration::DEFAULTS.map do |id, value|
        selected = id == "additional_login_methods" ? methods : value
        serialized = selected.is_a?(Array) ? selected.join(",") : selected
        "--#{id.tr('_', '-')}=#{serialized}"
      end
      arguments.unshift("--app-id=sample", "--app-name=Sample App")

      status = RapidRailsTemplate::Entrypoint.run(
        [*arguments, "sample"],
        output: StringIO.new,
        error: StringIO.new,
        runner_class: RecordingRunner,
        prompt: UnexpectedPrompt
      )

      assert_equal 0, status
      assert_equal methods, RecordingRunner.arguments.fetch(:plan).configuration["additional_login_methods"]
    end
  end

  def test_rejects_unknown_duplicate_and_blank_additional_login_methods
    ["passkey", "siwe,siwe", "siwe,"].each do |value|
      error = StringIO.new
      status = RapidRailsTemplate::Entrypoint.run(
        ["--additional-login-methods=#{value}", "sample"],
        error:,
        runner_class: RecordingRunner,
        prompt: UnexpectedPrompt
      )

      assert_equal 1, status
      assert_includes error.string, "--additional-login-methodsの値が不正です"
    end
  end

  def test_rejects_removed_profile_features_option
    error = StringIO.new
    status = RapidRailsTemplate::Entrypoint.run(
      ["--profile-features=screen_name,display_name,avatar", "sample"],
      error:,
      runner_class: RecordingRunner,
      prompt: UnexpectedPrompt
    )

    assert_equal 1, status
    assert_includes error.string, "不明なオプションです: --profile-features"
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
    assert_includes error.string, "--additional-login-methods=siwe"
  end

  def test_rejects_removed_image_delivery_option
    output = StringIO.new
    error = StringIO.new

    status = RapidRailsTemplate::Entrypoint.run(
      ["--image-delivery=rails", "sample"],
      output:,
      error:,
      runner_class: RecordingRunner,
      prompt: UnexpectedPrompt
    )

    assert_equal 1, status
    assert_includes error.string, "不明なオプションです: --image-delivery"
  end
end
