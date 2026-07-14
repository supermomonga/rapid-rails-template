# frozen_string_literal: true

module RapidRailsTemplate
  class Entrypoint
    CLI_OPTIONS = Configuration::VALID_VALUES.to_h do |id, allowed|
      ["--#{id.tr('_', '-')}", [id, allowed]]
    end.freeze

    def self.run(argv, input: $stdin, output: $stdout, error: $stderr, runner_class: Runner)
      argument_answers, app_path = parse_arguments(argv)

      Environment.validate!
      questionnaire = Questionnaire.new(input:, output:)
      configuration = Configuration.build(questionnaire.ask_all(argument_answers))
      plan = ExecutionPlan.build(configuration)
      if questionnaire.asked_any?
        return 0 unless questionnaire.confirm?(plan.summary)
      else
        output.puts plan.summary
      end

      runner_class.new(app_path:, plan:, template_payload: APPLICATION_TEMPLATE, output:, error:).run
    rescue Error => e
      error.puts "エラー: #{e.message}"
      1
    end

    def self.parse_arguments(argv)
      answers = {}
      paths = []

      argv.each do |argument|
        unless argument.start_with?("--")
          paths << argument
          next
        end

        option, value = argument.split("=", 2)
        definition = CLI_OPTIONS[option]
        raise Error, "不明なオプションです: #{option}\n#{usage}" if definition.nil?
        raise Error, "#{option}には値が必要です\n#{usage}" if value.nil? || value.empty?

        id, allowed = definition
        raise Error, "#{option}の値が不正です: #{value}（#{allowed.join('/')}から選択してください）" unless allowed.include?(value)
        raise Error, "#{option}が複数回指定されています" if answers.key?(id)

        answers[id] = value
      end

      raise Error, usage unless paths.length == 1

      [answers, paths.fetch(0)]
    end

    def self.usage
      options = CLI_OPTIONS.map do |option, (_, allowed)|
        "  #{option}=#{allowed.join('|')}"
      end
      (["使用方法: ruby bootstrap.rb [OPTIONS] APP_PATH", "オプション:"] + options).join("\n")
    end

    private_class_method :parse_arguments, :usage
  end
end

exit RapidRailsTemplate::Entrypoint.run(ARGV) if $PROGRAM_NAME == __FILE__
