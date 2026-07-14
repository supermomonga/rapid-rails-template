# frozen_string_literal: true

module RapidRailsTemplate
  class Entrypoint
    def self.run(argv, input: $stdin, output: $stdout, error: $stderr, runner_class: Runner)
      defaults_mode, app_path = parse_arguments(argv)

      Environment.validate!
      questionnaire = Questionnaire.new(input:, output:) unless defaults_mode
      configuration = defaults_mode ? Configuration.build({}) : Configuration.build(questionnaire.ask_all)
      plan = ExecutionPlan.build(configuration)
      if defaults_mode
        output.puts plan.summary
      else
        return 0 unless questionnaire.confirm?(plan.summary)
      end

      runner_class.new(app_path:, plan:, template_payload: APPLICATION_TEMPLATE, output:, error:).run
    rescue Error => e
      error.puts "エラー: #{e.message}"
      1
    end

    def self.parse_arguments(argv)
      return [false, argv.fetch(0)] if argv.length == 1
      return [true, argv.fetch(1)] if argv.length == 2 && argv.fetch(0) == "--defaults"

      raise Error, "使用方法: ruby bootstrap.rb [--defaults] APP_PATH"
    end

    private_class_method :parse_arguments
  end
end

exit RapidRailsTemplate::Entrypoint.run(ARGV) if $PROGRAM_NAME == __FILE__
