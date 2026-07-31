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

  def test_asks_app_name_with_path_basename_as_initial_value
    prompt = RecordingPrompt.new(input_answer: "custom_app")
    questionnaire = RapidRailsTemplate::Questionnaire.new(prompt:, output: StringIO.new)

    assert_equal "custom_app", questionnaire.ask_app_name("sample")
    assert_equal [
      { header: "アプリ名を入力してください。", value: "sample" }
    ], prompt.input_calls
    assert questionnaire.asked_any?
  end

  def test_rejects_cancelled_or_empty_app_name
    [nil, ""].each do |answer|
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
