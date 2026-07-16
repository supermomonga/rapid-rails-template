# frozen_string_literal: true

require_relative "../test_helper"

class QuestionnaireTest < Minitest::Test
  class RecordingPrompt
    attr_reader :choose_calls, :confirm_calls

    def initialize(answers: [], confirmation: false)
      @answers = answers
      @confirmation = confirmation
      @choose_calls = []
      @confirm_calls = []
    end

    def choose(choices, **options)
      @choose_calls << [choices, options]
      return @answers.shift unless @answers.empty?

      options.fetch(:selected).fetch(0)
    end

    def confirm(message, **options)
      @confirm_calls << [message, options]
      @confirmation
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
