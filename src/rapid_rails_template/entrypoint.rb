# frozen_string_literal: true

module RapidRailsTemplate
  class Entrypoint
    APP_ID_OPTION = "--app-id"
    APP_NAME_OPTION = "--app-name"
    CLI_OPTIONS = Configuration::VALID_VALUES.to_h do |id, allowed|
      ["--#{id.tr('_', '-')}", [id, allowed]]
    end.freeze

    def self.run(argv, output: $stdout, error: $stderr, runner_class: Runner, prompt: nil)
      argument_answers, app_id, app_name, app_path = parse_arguments(argv)

      Environment.validate!
      questionnaire = Questionnaire.new(prompt: prompt || Environment.gum, output:)
      app_id ||= questionnaire.ask_app_id(File.basename(app_path))
      app_name ||= questionnaire.ask_app_name(app_id)
      configuration = Configuration.build(questionnaire.ask_all(argument_answers))
      plan = ExecutionPlan.build(configuration, app_id:, app_name:)
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
      app_id = nil
      app_name = nil
      paths = []

      argv.each do |argument|
        unless argument.start_with?("--")
          paths << argument
          next
        end

        option, value = argument.split("=", 2)
        if option == APP_ID_OPTION
          raise Error, "#{option}が複数回指定されています" unless app_id.nil?
          raise Error, "#{option}には値が必要です\n#{usage}" if value.nil? || value.empty?

          app_id = value
          next
        end

        if option == APP_NAME_OPTION
          raise Error, "#{option}が複数回指定されています" unless app_name.nil?
          raise Error, "#{option}には値が必要です\n#{usage}" if value.nil? || value.empty?

          app_name = value.strip
          raise Error, "#{option}には値が必要です\n#{usage}" if app_name.empty?
          next
        end

        definition = CLI_OPTIONS[option]
        raise Error, "不明なオプションです: #{option}\n#{usage}" if definition.nil?
        id, allowed = definition
        raise Error, "#{option}が複数回指定されています" if answers.key?(id)

        answers[id] = parse_option_value(option, id, allowed, value)
      end

      raise Error, usage unless paths.length == 1

      [answers, app_id, app_name, paths.fetch(0)]
    end

    def self.usage
      options = ["  #{APP_ID_OPTION}=ID", "  #{APP_NAME_OPTION}=NAME"]
      options.concat(CLI_OPTIONS.map do |option, (id, allowed)|
        separator = Configuration.multiple_value_option?(id) ? "," : "|"
        "  #{option}=#{allowed.join(separator)}"
      end)
      (["使用方法: ruby bootstrap.rb [OPTIONS] APP_PATH", "オプション:"] + options).join("\n")
    end

    def self.parse_option_value(option, id, allowed, value)
      raise Error, "#{option}には値が必要です\n#{usage}" if value.nil?

      unless Configuration.multiple_value_option?(id)
        raise Error, "#{option}には値が必要です\n#{usage}" if value.empty?
        raise Error, "#{option}の値が不正です: #{value}（#{allowed.join('/')}から選択してください）" unless allowed.include?(value)

        return value
      end

      features = value.split(",", -1)
      features = [] if value.empty?
      valid = features.uniq == features && features.none?(&:empty?) && (features - allowed).empty?
      unless valid
        raise Error, "#{option}の値が不正です: #{value}（#{allowed.join(',')}をカンマ区切りで指定してください）"
      end

      allowed.select { |feature| features.include?(feature) }
    end

    private_class_method :parse_arguments, :parse_option_value, :usage
  end
end

exit RapidRailsTemplate::Entrypoint.run(ARGV) if $PROGRAM_NAME == __FILE__
