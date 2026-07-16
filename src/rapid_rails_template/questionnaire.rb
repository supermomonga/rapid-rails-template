# frozen_string_literal: true

module RapidRailsTemplate
  class Questionnaire
    Question = Data.define(:id, :prompt, :choices, :default, :condition)

    QUESTIONS = [
      Question.new(:pwa, "PWAを使用しますか？", %w[use skip], "skip", nil),
      Question.new(:web_push, "PWAでWeb Pushを使用しますか？", %w[use skip], "skip", ->(a) { a["pwa"] == "use" }),
      Question.new(:active_job, "ジョブ管理を使用しますか？", %w[solid_queue skip], "skip", nil),
      Question.new(:solid_cache, "Solid Cacheを使用しますか？", %w[use skip], "use", nil),
      Question.new(:account_authentication, "アカウント管理方法を選択してください。", %w[devise wallet_siwe], "devise", nil),
      Question.new(:api, "API機能を有効にしますか？", %w[enable disable], "enable", nil),
      Question.new(:action_cable, "Action Cableを使用しますか？", %w[solid_cable skip], "skip", nil),
      Question.new(:mail, "メール機能を使用しますか？", %w[auto use skip], "auto", nil),
      Question.new(:action_text, "Action Textを使用しますか？", %w[use skip], "use", nil),
      Question.new(:deployment, "デプロイ方法を選択してください。", %w[dokploy none], "dokploy", nil)
    ].freeze

    def initialize(prompt:, output: $stdout)
      @prompt = prompt
      @output = output
      @asked_question_ids = []
    end

    def ask_all(initial_answers = {})
      answers = initial_answers.transform_keys(&:to_s).dup

      QUESTIONS.each do |question|
        next if answers.key?(question.id.to_s)
        next unless question.condition.nil? || question.condition.call(answers)

        @asked_question_ids << question.id.to_s
        answers[question.id.to_s] = ask(question)
      end

      answers
    end

    def asked_any?
      !@asked_question_ids.empty?
    end

    def confirm?(summary)
      @output.puts summary
      with_prompt_error do
        @prompt.confirm(
          "この内容で実行しますか？",
          default: false,
          affirmative: "実行",
          negative: "中止"
        )
      end
    end

    private

    def ask(question)
      answer = with_prompt_error do
        @prompt.choose(
          question.choices,
          header: question.prompt,
          selected: [question.default]
        )
      end
      raise PromptError, "選択がキャンセルされました: #{question.prompt}" if answer.nil?
      raise PromptError, "選択UIが不正な値を返しました: #{answer}" unless question.choices.include?(answer)

      answer
    end

    def with_prompt_error
      yield
    rescue StandardError => e
      raise unless gum_error?(e)

      raise PromptError, "Gumの実行に失敗しました: #{e.message}"
    end

    def gum_error?(error)
      @prompt.respond_to?(:const_defined?) && @prompt.const_defined?(:Error) && error.is_a?(@prompt.const_get(:Error))
    end
  end
end
