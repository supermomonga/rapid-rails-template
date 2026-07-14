# frozen_string_literal: true

require_relative "../test_helper"

class QuestionnaireTest < Minitest::Test
  def test_skips_web_push_question_when_pwa_is_disabled
    input = StringIO.new("\n\n\n\n\n\n\n\n")
    output = StringIO.new
    answers = RapidRailsTemplate::Questionnaire.new(input:, output:).ask_all

    refute_includes output.string, "Web Push"
    refute answers.key?("web_push")
    assert_equal "skip", answers["pwa"]
  end

  def test_reprompts_invalid_value_without_side_effects
    input = StringIO.new("invalid\nuse\nskip\n\n\n\n\n\n\n\n")
    output = StringIO.new
    answers = RapidRailsTemplate::Questionnaire.new(input:, output:).ask_all

    assert_includes output.string, "無効な値"
    assert_equal "use", answers["pwa"]
    assert_equal "skip", answers["web_push"]
  end

  def test_asks_only_applicable_options_missing_from_initial_answers
    initial_answers = RapidRailsTemplate::Configuration::DEFAULTS.reject { |key, _| key == "mail" }
    input = StringIO.new("skip\n")
    output = StringIO.new
    questionnaire = RapidRailsTemplate::Questionnaire.new(input:, output:)

    answers = questionnaire.ask_all(initial_answers)

    assert_equal "skip", answers["mail"]
    assert questionnaire.asked_any?
    assert_includes output.string, "メール機能"
    refute_includes output.string, "PWAを使用"
  end
end
