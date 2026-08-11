# frozen_string_literal: true

module RapidRailsTemplate
  class Questionnaire
    Question = Data.define(:id, :prompt, :choices, :default, :condition, :multiple)

    QUESTIONS = [
      Question.new(:pwa, "PWAを使用しますか？", %w[use skip], "skip", nil, false),
      Question.new(:web_push, "PWAでWeb Pushを使用しますか？", %w[use skip], "skip", ->(a) { a["pwa"] == "use" }, false),
      Question.new(:active_job, "ジョブ管理を使用しますか？", %w[solid_queue skip], "skip", ->(a) { a["web_push"] != "use" }, false),
      Question.new(:job_operations, "管理者向けジョブ運用画面を使用しますか？", %w[enable disable], "enable", ->(a) { a["web_push"] == "use" || a["active_job"] == "solid_queue" }, false),
      Question.new(:maintenance_tasks, "管理者向け運用タスクを使用しますか？", %w[enable disable], "enable", ->(a) { a["web_push"] == "use" || a["active_job"] == "solid_queue" }, false),
      Question.new(:solid_cache, "Solid Cacheを使用しますか？", %w[use skip], "use", nil, false),
      Question.new(:additional_login_methods, "追加するログイン方法を選択してください。", Configuration::ADDITIONAL_LOGIN_METHODS, [], nil, true),
      Question.new(:profile_features, "プロフィール機能を選択してください。", Configuration::PROFILE_FEATURES, Configuration::PROFILE_FEATURES, nil, true),
      Question.new(:api, "API機能を有効にしますか？", %w[enable disable], "enable", nil, false),
      Question.new(:action_cable, "Action Cableを使用しますか？", %w[solid_cable skip], "skip", nil, false),
      Question.new(:mail, "メール機能を使用しますか？", %w[auto use skip], "auto", nil, false),
      Question.new(:deployment, "デプロイ方法を選択してください。", %w[dokploy none], "dokploy", nil, false),
      Question.new(:default_locale, "既定localeを選択してください。", %w[ja en], "ja", nil, false)
    ].freeze

    def initialize(prompt:, output: $stdout)
      @prompt = prompt
      @output = output
      @asked_question_ids = []
    end

    def ask_app_id(default)
      @asked_question_ids << "app_id"
      answer = with_prompt_error do
        @prompt.input(
          header: "RailsアプリIDを入力してください。",
          value: default
        )
      end
      raise PromptError, "RailsアプリIDの入力がキャンセルされました" if answer.nil?
      raise PromptError, "RailsアプリIDを空にすることはできません" if answer.empty?

      answer
    end

    def ask_app_name(default)
      @asked_question_ids << "app_name"
      answer = with_prompt_error do
        @prompt.input(
          header: "表示用アプリ名を入力してください。",
          value: default
        )
      end
      raise PromptError, "表示用アプリ名の入力がキャンセルされました" if answer.nil?

      answer = answer.strip
      raise PromptError, "表示用アプリ名を空にすることはできません" if answer.empty?

      answer
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
      options = { header: question.prompt, selected: Array(question.default) }
      options[:no_limit] = true if question.multiple
      answer = with_prompt_error do
        @prompt.choose(question.choices, **options)
      end
      raise PromptError, "選択がキャンセルされました: #{question.prompt}" if answer.nil?

      if question.multiple
        valid = answer.is_a?(Array) && answer.uniq == answer && (answer - question.choices).empty?
        raise PromptError, "選択UIが不正な値を返しました: #{answer.inspect}" unless valid

        return question.choices.select { |choice| answer.include?(choice) }
      end

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
