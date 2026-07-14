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
end
