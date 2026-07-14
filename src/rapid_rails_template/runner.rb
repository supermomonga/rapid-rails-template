# frozen_string_literal: true

require "json"
require "open3"
require "rbconfig"
require "tempfile"

module RapidRailsTemplate
  class Runner
    def initialize(app_path:, plan:, template_payload:, output: $stdout, error: $stderr, process_runner: Open3)
      @app_path = app_path
      @plan = plan
      @template_payload = template_payload
      @output = output
      @error = error
      @process_runner = process_runner
    end

    def run
      template_file = secure_tempfile(["rapid-rails-template", ".rb"], template_payload)
      config_file = secure_tempfile(["rapid-rails-configuration", ".json"], JSON.generate(plan.to_h))
      command = rails_command(template_file.path)
      environment = { "RAPID_RAILS_TEMPLATE_CONFIG" => config_file.path }
      status = stream_process(environment, command)
      status.exitstatus || 1
    ensure
      template_file&.close!
      config_file&.close!
    end

    private

    attr_reader :app_path, :plan, :template_payload, :output, :error, :process_runner

    def secure_tempfile(basename, content)
      file = Tempfile.new(basename)
      file.chmod(0o600)
      file.binmode
      file.write(content)
      file.flush
      file
    end

    def rails_command(template_path)
      rails = Gem.bin_path("railties", "rails", ">= 8.1", "< 8.2")
      [RbConfig.ruby, rails, "new", app_path, *plan.generator_options, "--template", template_path]
    end

    def stream_process(environment, command)
      process_runner.popen3(environment, *command) do |stdin, stdout, stderr, wait_thread|
        stdin.close
        readers = [Thread.new { IO.copy_stream(stdout, output) }, Thread.new { IO.copy_stream(stderr, error) }]
        readers.each(&:join)
        wait_thread.value
      end
    rescue SystemCallError => e
      raise Error, "rails newを起動できません: #{e.message}"
    end
  end
end
