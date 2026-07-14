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
      Question.new(:action_cable, "Action Cableを使用しますか？", %w[solid_cable skip], "skip", nil),
      Question.new(:mail, "メール機能を使用しますか？", %w[auto use skip], "auto", nil),
      Question.new(:action_text, "Action Textを使用しますか？", %w[use skip], "use", nil),
      Question.new(:deployment, "デプロイ方法を選択してください。", %w[dokploy none], "dokploy", nil)
    ].freeze

    def initialize(input: $stdin, output: $stdout)
      @input = input
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
      @output.print "この内容で実行しますか？ [y/N]: "
      %w[y yes].include?(read_line.downcase)
    end

    private

    def ask(question)
      loop do
        @output.print "#{question.prompt} (#{question.choices.join('/')}) [#{question.default}]: "
        answer = read_line
        answer = question.default if answer.empty?
        return answer if question.choices.include?(answer)

        @output.puts "無効な値です: #{answer}"
      end
    end

    def read_line
      value = @input.gets
      raise Error, "入力が終了しました" if value.nil?

      value.strip
    end
  end
end
