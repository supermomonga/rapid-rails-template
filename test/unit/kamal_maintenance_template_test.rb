# frozen_string_literal: true

require_relative "../test_helper"
require "json"
require "stringio"
require "yaml"

class KamalMaintenanceTemplateTest < Minitest::Test
  TEMPLATE_PATH = File.expand_path("../../src/rapid_rails_template/rails_template.rb", __dir__)

  class TTYIO < StringIO
    def tty?
      true
    end
  end

  class FakePrompt
    attr_reader :confirmations, :inputs

    def initialize(confirm: true, input: nil)
      @confirm = confirm
      @input = input
      @confirmations = []
      @inputs = []
    end

    def confirm(message, **options)
      @confirmations << [message, options]
      @confirm
    end

    def input(**options)
      @inputs << options
      @input || options.fetch(:value)
    end
  end

  class FakeRunner
    attr_reader :commands

    def initialize(fail_when: nil)
      @commands = []
      @fail_when = fail_when
    end

    def run!(*arguments)
      command = arguments.last(2) == %w[-d production] ? arguments.first(arguments.length - 2) : arguments
      @commands << command
      raise KamalMaintenance::Error, "expected failure" if @fail_when&.call(command)

      ""
    end

    def ignore_failure(*arguments)
      command = arguments.last(2) == %w[-d production] ? arguments.first(arguments.length - 2) : arguments
      @commands << command
      ""
    end
  end

  class FakeStateStore
    attr_accessor :state, :restore_active
    attr_reader :calls

    def initialize(state: nil, restore_active: false)
      @state = deep_copy(state)
      @restore_active = restore_active
      @calls = []
    end

    def maintenance
      @calls << :maintenance
      deep_copy(@state)
    end

    def write_maintenance(state)
      @calls << :write
      @state = deep_copy(state)
      ""
    end

    def delete_maintenance
      @calls << :delete
      @state = nil
      ""
    end

    def restore_active?
      @calls << :restore_active
      @restore_active
    end

    def acquire_lock(message)
      @calls << [:acquire_lock, message]
    end

    def release_lock
      @calls << :release_lock
    end

    private

    def deep_copy(value)
      value && JSON.parse(JSON.generate(value))
    end
  end

  class FakeInspector
    attr_accessor :roles, :litestream, :response
    attr_reader :calls

    def initialize(roles:, litestream:, response:)
      @roles = roles
      @litestream = litestream
      @response = response
      @calls = []
    end

    def running_roles
      @calls << :running_roles
      @roles
    end

    def litestream_running?
      @calls << :litestream_running
      @litestream.is_a?(Array) ? @litestream.shift : @litestream
    end

    def public_response(path: nil)
      @calls << [:public_response, path]
      @response
    end
  end

  def setup
    @databases = [
      { "name" => "primary", "path" => "/rails/storage/production.sqlite3" },
      { "name" => "storage", "path" => "/rails/storage/production_storage.sqlite3" },
      { "name" => "queue", "path" => "/rails/storage/production_queue.sqlite3" }
    ]
    load_generated_cli(default_locale: "ja", databases: @databases)
  end

  def teardown
    Object.send(:remove_const, :KamalMaintenance) if Object.const_defined?(:KamalMaintenance)
    Object.send(:remove_const, :Deployment) if Object.const_defined?(:Deployment)
  end

  def test_generated_cli_and_common_support_compile
    RubyVM::InstructionSequence.compile(@files.fetch("bin/kamal-maintenance"))
    RubyVM::InstructionSequence.compile(@files.fetch("lib/deployment/kamal_operation.rb"))
    assert_equal 0o755, @modes.fetch("bin/kamal-maintenance")
  end

  def test_start_stops_all_app_roles_syncs_only_litestream_databases_and_activates_state
    runner = FakeRunner.new
    store = FakeStateStore.new
    inspector = FakeInspector.new(
      roles: [],
      litestream: false,
      response: { "code" => 503, "body" => "<p>#{KamalMaintenance::DEFAULT_MESSAGE}</p>" }
    )

    status = run_cli(
      ["start", "--destination=production", "--message=#{KamalMaintenance::DEFAULT_MESSAGE}"],
      runner:,
      store:,
      inspector:
    )

    assert_equal 0, status
    assert_equal "active", store.state.fetch("phase")
    assert_equal "active", store.state.fetch("last_successful_step")
    assert_equal KamalMaintenance::DEFAULT_MESSAGE, store.state.fetch("message")
    assert_includes runner.commands, ["app", "maintenance", "--message", KamalMaintenance::DEFAULT_MESSAGE]
    assert_includes runner.commands, %w[app stop]
    assert_includes runner.commands, %w[accessory stop litestream]
    sync_paths = runner.commands.filter_map do |command|
      command.last if command.first(5) == %w[accessory exec litestream --reuse litestream]
    end
    assert_equal @databases.map { |database| database.fetch("path") }, sync_paths
    refute sync_paths.any? { |path| path.include?("cache") }
  end

  def test_start_passes_shell_metacharacters_as_one_argument
    message = %q[DB <read-only> $HOME `uname` "quoted" & safe]
    runner = FakeRunner.new
    store = FakeStateStore.new
    inspector = FakeInspector.new(
      roles: [],
      litestream: false,
      response: { "code" => 503, "body" => CGI.escapeHTML(message) }
    )

    status = run_cli(
      ["start", "--destination=production", "--message=#{message}"],
      runner:,
      store:,
      inspector:
    )

    assert_equal 0, status
    command = runner.commands.find { |candidate| candidate.first(2) == %w[app maintenance] }
    assert_equal ["app", "maintenance", "--message", message], command
  end

  def test_mutating_actions_require_tty_and_default_no_confirmation
    runner = FakeRunner.new
    store = FakeStateStore.new
    inspector = FakeInspector.new(roles: [], litestream: false, response: { "code" => 503, "body" => "" })
    error = StringIO.new

    status = KamalMaintenance::CLI.new(
      ["start", "--destination=production", "--message=maintenance"],
      input: StringIO.new,
      output: StringIO.new,
      error:,
      runner:,
      prompt: FakePrompt.new,
      state_store: store,
      inspector:
    ).run

    assert_equal 1, status
    assert_includes error.string, "interactive terminal"
    assert_empty runner.commands

    prompt = FakePrompt.new(confirm: false)
    status = run_cli(
      ["start", "--destination=production", "--message=maintenance"],
      runner:,
      store:,
      inspector:,
      prompt:
    )
    assert_equal 1, status
    assert_equal false, prompt.confirmations.fetch(0).last.fetch(:default)
    assert_empty runner.commands
  end

  def test_rejects_invalid_arguments_and_messages
    invalid_argv = [
      ["status"],
      ["status", "--destination=other"],
      ["start", "--destination=production", "--force"],
      ["status", "--destination=production", "--message=no"],
      ["start", "--destination=production", "--message=line1\nline2"],
      ["start", "--destination=production", "--message=#{"x" * 501}"],
      ["start", "--destination=production", "--message="]
    ]

    invalid_argv.each do |argv|
      runner = FakeRunner.new
      status = KamalMaintenance::CLI.new(argv, runner:, error: StringIO.new).run
      assert_equal 1, status, argv.inspect
      assert_empty runner.commands
    end
  end

  def test_restore_conflict_does_not_create_maintenance_state
    runner = FakeRunner.new
    store = FakeStateStore.new(restore_active: true)
    inspector = FakeInspector.new(roles: [], litestream: false, response: { "code" => 503, "body" => "" })

    status = run_cli(
      ["start", "--destination=production", "--message=maintenance"],
      runner:,
      store:,
      inspector:
    )

    assert_equal 1, status
    assert_nil store.state
    assert_includes store.calls, :restore_active
    assert_includes store.calls, :release_lock
    assert_empty runner.commands
  end

  def test_failed_start_keeps_state_and_same_command_continues_after_last_successful_step
    runner = FakeRunner.new(fail_when: lambda do |command|
      command.last == "/rails/storage/production_storage.sqlite3"
    end)
    store = FakeStateStore.new
    inspector = FakeInspector.new(
      roles: [],
      litestream: false,
      response: { "code" => 503, "body" => "maintenance" }
    )

    first_status = run_cli(
      ["start", "--destination=production", "--message=maintenance"],
      runner:,
      store:,
      inspector:
    )

    assert_equal 1, first_status
    assert_equal "start_failed", store.state.fetch("phase")
    assert_equal "litestream_synced_primary", store.state.fetch("last_successful_step")
    assert_equal "litestream_synced_storage", store.state.fetch("failed_step")

    inspector.litestream = [true, false]
    retry_runner = FakeRunner.new
    second_status = run_cli(
      ["start", "--destination=production", "--message=maintenance"],
      runner: retry_runner,
      store:,
      inspector:
    )

    assert_equal 0, second_status
    refute retry_runner.commands.any? { |command| command.first(2) == %w[app maintenance] }
    refute_includes retry_runner.commands, %w[app stop]
    refute retry_runner.commands.any? { |command| command.last == "/rails/storage/production.sqlite3" }
    assert retry_runner.commands.any? { |command| command.last == "/rails/storage/production_storage.sqlite3" }
    assert_equal "active", store.state.fetch("phase")
  end

  def test_message_updates_proxy_and_remote_state_without_starting_services
    state = active_state(message: "old")
    store = FakeStateStore.new(state:)
    runner = FakeRunner.new
    inspector = FakeInspector.new(
      roles: [],
      litestream: false,
      response: { "code" => 503, "body" => "new message" }
    )

    status = run_cli(
      ["message", "--destination=production", "--message=new message"],
      runner:,
      store:,
      inspector:
    )

    assert_equal 0, status
    assert_equal "new message", store.state.fetch("message")
    assert_equal [["app", "maintenance", "--message", "new message"]], runner.commands
  end

  def test_finish_starts_litestream_and_roles_checks_health_then_goes_live_and_deletes_state
    store = FakeStateStore.new(state: active_state)
    runner = FakeRunner.new
    inspector = FakeInspector.new(
      roles: %w[web worker],
      litestream: true,
      response: { "code" => 200, "body" => "OK" }
    )

    status = run_cli(
      ["finish", "--destination=production"],
      runner:,
      store:,
      inspector:
    )

    assert_equal 0, status
    assert_nil store.state
    assert_includes store.calls, :delete
    assert_order runner.commands, %w[accessory start litestream], %w[app start -r web]
    assert_order runner.commands, %w[app start -r web], %w[app start -r worker]
    internal_health = runner.commands.find { |command| command.first(5) == %w[app exec -p -r web] }
    refute_nil internal_health
    assert_operator runner.commands.index(internal_health), :<, runner.commands.index(%w[app live])
    assert_includes inspector.calls, [:public_response, "/up"]
  end

  def test_finish_failure_after_live_restores_maintenance_response_and_keeps_state
    store = FakeStateStore.new(state: active_state)
    runner = FakeRunner.new
    inspector = FakeInspector.new(
      roles: %w[web worker],
      litestream: true,
      response: { "code" => 503, "body" => "maintenance" }
    )

    status = run_cli(
      ["finish", "--destination=production"],
      runner:,
      store:,
      inspector:
    )

    assert_equal 1, status
    assert_equal "finish_failed", store.state.fetch("phase")
    assert_equal "public_health_verified", store.state.fetch("failed_step")
    assert_equal "internal_health_verified", store.state.fetch("last_successful_step")
    assert runner.commands.any? do |command|
      command == ["app", "maintenance", "--message", store.state.fetch("message")]
    end
    refute_includes store.calls, :delete
  end

  def test_finish_without_worker_does_not_start_worker
    load_generated_cli(
      default_locale: "en",
      databases: @databases.reject { |database| database.fetch("name") == "queue" }
    )
    store = FakeStateStore.new(state: active_state(message: KamalMaintenance::DEFAULT_MESSAGE))
    runner = FakeRunner.new
    inspector = FakeInspector.new(roles: %w[web], litestream: true, response: { "code" => 200, "body" => "OK" })

    status = run_cli(
      ["finish", "--destination=production"],
      runner:,
      store:,
      inspector:
    )

    assert_equal 0, status
    refute runner.commands.any? { |command| command == %w[app start -r worker] }
    assert_equal "We are currently performing maintenance. Please try again later.", KamalMaintenance::DEFAULT_MESSAGE
  end

  def test_status_does_not_require_tty_or_boot_rails_and_rejects_inconsistent_remote_state
    store = FakeStateStore.new(state: active_state)
    runner = FakeRunner.new
    inspector = FakeInspector.new(
      roles: [],
      litestream: false,
      response: { "code" => 503, "body" => "maintenance" }
    )
    output = StringIO.new

    status = KamalMaintenance::CLI.new(
      ["status", "--destination=production"],
      input: StringIO.new,
      output:,
      error: StringIO.new,
      runner:,
      state_store: store,
      inspector:
    ).run

    assert_equal 0, status
    assert_includes output.string, "Phase: active"
    assert_empty runner.commands
    refute_includes @files.fetch("bin/kamal-maintenance"), "rails runner"

    inspector.roles = %w[web]
    assert_equal 1, KamalMaintenance::CLI.new(
      ["status", "--destination=production"],
      input: StringIO.new,
      output: StringIO.new,
      error: StringIO.new,
      runner:,
      state_store: store,
      inspector:
    ).run
  end

  private

  def load_generated_cli(default_locale:, databases:)
    Object.send(:remove_const, :KamalMaintenance) if Object.const_defined?(:KamalMaintenance)
    Object.send(:remove_const, :Deployment) if Object.const_defined?(:Deployment)
    @files, @modes = build_files(default_locale:, databases:)
    eval(@files.fetch("lib/deployment/kamal_operation.rb"), TOPLEVEL_BINDING, "generated/lib/deployment/kamal_operation.rb")
    eval(@files.fetch("bin/kamal-maintenance"), TOPLEVEL_BINDING, "generated/bin/kamal-maintenance")
  end

  def build_files(default_locale:, databases:)
    source = File.binread(TEMPLATE_PATH)
    start_index = source.index("def kamal_restore_cli_body") || raise("Kamal source start not found")
    end_index = source.index("def configure_deployment", start_index) || raise("Kamal source end not found")
    builder_class = Class.new
    builder_class.const_set(:VALUES, { "default_locale" => default_locale })
    builder_class.class_eval(source.byteslice(start_index...end_index), TEMPLATE_PATH, 1)
    files = {}
    modes = {}
    builder = builder_class.new
    builder.define_singleton_method(:create_file) do |path, content, force:|
      raise "force must be true" unless force

      files[path] = content
    end
    builder.define_singleton_method(:chmod) { |path, mode| modes[path] = mode }
    builder.send(:configure_kamal_operation_support, "sample")
    builder.send(:configure_kamal_maintenance, "sample", databases)
    [files, modes]
  end

  def run_cli(argv, runner:, store:, inspector:, prompt: FakePrompt.new)
    KamalMaintenance::CLI.new(
      argv,
      input: TTYIO.new,
      output: TTYIO.new,
      error: StringIO.new,
      runner:,
      prompt:,
      state_store: store,
      inspector:,
      now: -> { Time.utc(2026, 9, 1, 0, 0, 0) }
    ).run
  end

  def active_state(message: "maintenance")
    {
      "schema_version" => 1,
      "phase" => "active",
      "destination" => "production",
      "message" => message,
      "started_at" => "2026-09-01T00:00:00Z",
      "updated_at" => "2026-09-01T00:00:00Z",
      "last_successful_step" => "active",
      "failed_step" => nil,
      "error" => nil
    }
  end

  def assert_order(collection, first, second)
    assert_operator collection.index(first), :<, collection.index(second)
  end
end
