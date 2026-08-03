# frozen_string_literal: true

require_relative "../test_helper"

class QuestionnaireTest < Minitest::Test
  class RecordingPrompt
    attr_reader :choose_calls, :confirm_calls, :input_calls

    def initialize(answers: [], confirmation: false, input_answer: nil)
      @answers = answers
      @confirmation = confirmation
      @input_answer = input_answer
      @choose_calls = []
      @confirm_calls = []
      @input_calls = []
    end

    def input(**options)
      @input_calls << options
      @input_answer
    end

    def choose(choices, **options)
      @choose_calls << [choices, options]
      return @answers.shift unless @answers.empty?

      options[:no_limit] ? options.fetch(:selected) : options.fetch(:selected).fetch(0)
    end

    def confirm(message, **options)
      @confirm_calls << [message, options]
      @confirmation
    end
  end

  def test_asks_app_id_with_path_basename_as_initial_value
    prompt = RecordingPrompt.new(input_answer: "custom_app")
    questionnaire = RapidRailsTemplate::Questionnaire.new(prompt:, output: StringIO.new)

    assert_equal "custom_app", questionnaire.ask_app_id("sample")
    assert_equal [
      { header: "RailsアプリIDを入力してください。", value: "sample" }
    ], prompt.input_calls
    assert questionnaire.asked_any?
  end

  def test_asks_trimmed_app_name_with_app_id_as_initial_value
    prompt = RecordingPrompt.new(input_answer: "  Sample App & Service  ")
    questionnaire = RapidRailsTemplate::Questionnaire.new(prompt:, output: StringIO.new)

    assert_equal "Sample App & Service", questionnaire.ask_app_name("sample")
    assert_equal [
      { header: "表示用アプリ名を入力してください。", value: "sample" }
    ], prompt.input_calls
    assert questionnaire.asked_any?
  end

  def test_rejects_cancelled_or_empty_app_id
    [nil, ""].each do |answer|
      prompt = RecordingPrompt.new(input_answer: answer)
      questionnaire = RapidRailsTemplate::Questionnaire.new(prompt:, output: StringIO.new)

      assert_raises(RapidRailsTemplate::PromptError) { questionnaire.ask_app_id("sample") }
    end
  end

  def test_rejects_cancelled_or_blank_app_name
    [nil, "", " \t "].each do |answer|
      prompt = RecordingPrompt.new(input_answer: answer)
      questionnaire = RapidRailsTemplate::Questionnaire.new(prompt:, output: StringIO.new)

      assert_raises(RapidRailsTemplate::PromptError) { questionnaire.ask_app_name("sample") }
    end
  end

  def test_skips_web_push_question_when_pwa_is_disabled
    prompt = RecordingPrompt.new
    output = StringIO.new
    answers = RapidRailsTemplate::Questionnaire.new(prompt:, output:).ask_all

    refute prompt.choose_calls.any? { |(_, options)| options.fetch(:header).include?("Web Push") }
    refute prompt.choose_calls.any? { |(_, options)| options.fetch(:header).include?("Action Text") }
    refute answers.key?("web_push")
    assert_equal "skip", answers["pwa"]
  end

  def test_uses_gum_choices_and_preselects_the_default
    prompt = RecordingPrompt.new(answers: ["use", "skip"])
    output = StringIO.new
    answers = RapidRailsTemplate::Questionnaire.new(prompt:, output:).ask_all

    assert_equal "use", answers["pwa"]
    assert_equal "skip", answers["web_push"]
    assert_equal [
      %w[use skip],
      { header: "PWAを使用しますか？", selected: ["skip"] }
    ], prompt.choose_calls.fetch(0)
  end

  def test_skips_active_job_question_when_web_push_is_enabled
    prompt = RecordingPrompt.new(answers: ["use", "use"])
    answers = RapidRailsTemplate::Questionnaire.new(prompt:, output: StringIO.new).ask_all

    assert_equal "use", answers["web_push"]
    refute answers.key?("active_job")
    refute prompt.choose_calls.any? { |(_, options)| options.fetch(:header).include?("ジョブ管理") }
  end

  def test_asks_maintenance_tasks_with_enable_preselected_when_solid_queue_is_selected
    initial_answers = RapidRailsTemplate::Configuration::DEFAULTS.merge(
      "active_job" => "solid_queue"
    ).reject { |key, _| key == "maintenance_tasks" }
    prompt = RecordingPrompt.new(answers: ["enable"])

    answers = RapidRailsTemplate::Questionnaire.new(prompt:, output: StringIO.new).ask_all(initial_answers)

    assert_equal "enable", answers["maintenance_tasks"]
    assert_equal [
      %w[enable disable],
      { header: "管理者向け運用タスクを使用しますか？", selected: ["enable"] }
    ], prompt.choose_calls.fetch(0)
  end

  def test_asks_job_operations_with_enable_preselected_when_solid_queue_is_selected
    initial_answers = RapidRailsTemplate::Configuration::DEFAULTS.merge(
      "active_job" => "solid_queue"
    ).reject { |key, _| key == "job_operations" }
    prompt = RecordingPrompt.new(answers: ["enable"])

    answers = RapidRailsTemplate::Questionnaire.new(prompt:, output: StringIO.new).ask_all(initial_answers)

    assert_equal "enable", answers["job_operations"]
    assert_equal [
      %w[enable disable],
      { header: "管理者向けジョブ運用画面を使用しますか？", selected: ["enable"] }
    ], prompt.choose_calls.fetch(0)
  end

  def test_skips_job_operations_without_solid_queue
    prompt = RecordingPrompt.new
    answers = RapidRailsTemplate::Questionnaire.new(prompt:, output: StringIO.new).ask_all

    refute answers.key?("job_operations")
    refute prompt.choose_calls.any? { |(_, options)| options.fetch(:header).include?("ジョブ運用画面") }
  end

  def test_asks_maintenance_tasks_when_web_push_requires_solid_queue
    initial_answers = RapidRailsTemplate::Configuration::DEFAULTS.merge(
      "pwa" => "use",
      "web_push" => "use"
    ).reject { |key, _| %w[active_job maintenance_tasks].include?(key) }
    prompt = RecordingPrompt.new(answers: ["enable"])

    answers = RapidRailsTemplate::Questionnaire.new(prompt:, output: StringIO.new).ask_all(initial_answers)

    refute answers.key?("active_job")
    assert_equal "enable", answers["maintenance_tasks"]
  end

  def test_skips_maintenance_tasks_without_solid_queue
    prompt = RecordingPrompt.new
    answers = RapidRailsTemplate::Questionnaire.new(prompt:, output: StringIO.new).ask_all

    refute answers.key?("maintenance_tasks")
    refute prompt.choose_calls.any? { |(_, options)| options.fetch(:header).include?("運用タスク") }
  end

  def test_asks_only_applicable_options_missing_from_initial_answers
    initial_answers = RapidRailsTemplate::Configuration::DEFAULTS.reject { |key, _| key == "mail" }
    prompt = RecordingPrompt.new(answers: ["skip"])
    output = StringIO.new
    questionnaire = RapidRailsTemplate::Questionnaire.new(prompt:, output:)

    answers = questionnaire.ask_all(initial_answers)

    assert_equal "skip", answers["mail"]
    assert questionnaire.asked_any?
    assert_equal ["メール機能を使用しますか？"], prompt.choose_calls.map { |(_, options)| options.fetch(:header) }
  end

  def test_uses_unlimited_gum_multiple_selection_for_profile_features
    initial_answers = RapidRailsTemplate::Configuration::DEFAULTS.reject { |key, _| key == "profile_features" }
    prompt = RecordingPrompt.new(answers: [%w[avatar screen_name]])
    questionnaire = RapidRailsTemplate::Questionnaire.new(prompt:, output: StringIO.new)

    answers = questionnaire.ask_all(initial_answers)

    assert_equal %w[screen_name avatar], answers["profile_features"]
    assert_equal [
      %w[screen_name display_name avatar],
      {
        header: "プロフィール機能を選択してください。",
        selected: %w[screen_name display_name avatar],
        no_limit: true
      }
    ], prompt.choose_calls.fetch(0)
  end

  def test_accepts_no_selected_profile_features
    initial_answers = RapidRailsTemplate::Configuration::DEFAULTS.reject { |key, _| key == "profile_features" }
    prompt = RecordingPrompt.new(answers: [[]])

    answers = RapidRailsTemplate::Questionnaire.new(prompt:, output: StringIO.new).ask_all(initial_answers)

    assert_empty answers["profile_features"]
  end

  def test_always_asks_image_delivery_when_it_is_not_prefilled
    initial_answers = RapidRailsTemplate::Configuration::DEFAULTS.reject { |key, _| key == "image_delivery" }
    prompt = RecordingPrompt.new(answers: ["imgproxy"])

    answers = RapidRailsTemplate::Questionnaire.new(prompt:, output: StringIO.new).ask_all(initial_answers)

    assert_equal "imgproxy", answers["image_delivery"]
    assert_equal [
      %w[rails imgproxy],
      { header: "画像配信方式を選択してください。", selected: ["rails"] }
    ], prompt.choose_calls.fetch(0)
  end

  def test_cancelled_selection_fails_before_configuration_is_built
    prompt = RecordingPrompt.new(answers: [nil])
    questionnaire = RapidRailsTemplate::Questionnaire.new(prompt:, output: StringIO.new)

    error = assert_raises(RapidRailsTemplate::PromptError) { questionnaire.ask_all }

    assert_includes error.message, "選択がキャンセルされました"
  end

  def test_uses_gum_confirmation_with_rejection_as_default
    prompt = RecordingPrompt.new(confirmation: true)
    output = StringIO.new
    questionnaire = RapidRailsTemplate::Questionnaire.new(prompt:, output:)

    assert questionnaire.confirm?("実行計画")
    assert_equal "実行計画\n", output.string
    assert_equal [
      "この内容で実行しますか？",
      { default: false, affirmative: "実行", negative: "中止" }
    ], prompt.confirm_calls.fetch(0)
  end
end
