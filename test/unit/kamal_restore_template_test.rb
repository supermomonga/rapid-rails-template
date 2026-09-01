# frozen_string_literal: true

require_relative "../test_helper"
require "fileutils"
require "erb"
require "json"
require "open3"
require "pathname"
require "rbconfig"
require "tmpdir"
require "yaml"

class KamalRestoreTemplateTest < Minitest::Test
  TEMPLATE_PATH = File.expand_path("../../src/rapid_rails_template/rails_template.rb", __dir__)

  class TTYIO < StringIO
    def tty?
      true
    end
  end

  class ValidInitialTokenClient
    attr_reader :calls

    def initialize
      @calls = []
    end

    def verify_token(account_id)
      @calls << { method: :verify_token, account_id: }
      { "id" => "initial-token-id", "status" => "active" }
    end

    def permission_groups(account_id, name:)
      @calls << { method: :permission_groups, account_id:, name: }
      if name == "Account API Tokens Write"
        [{ "id" => "account-token-write", "name" => name, "scopes" => ["com.cloudflare.api.account"] }]
      else
        [{ "id" => "r2-write", "name" => name, "scopes" => ["com.cloudflare.edge.r2.bucket"] }]
      end
    end

    def token_details(account_id, token_id)
      @calls << { method: :token_details, account_id:, token_id: }
      {
        "id" => token_id,
        "status" => "active",
        "policies" => [{
          "effect" => "allow",
          "resources" => { "com.cloudflare.api.account.#{account_id}" => "*" },
          "permission_groups" => [{ "id" => "account-token-write" }]
        }]
      }
    end

    def tokens(account_id)
      @calls << { method: :tokens, account_id: }
      []
    end

    def create_token(*)
      raise "unexpected Cloudflare token creation"
    end
  end

  class FakeRunner
    attr_reader :commands, :raw_commands

    def initialize(fail_when: nil, output_when: nil)
      @commands = []
      @raw_commands = []
      @fail_when = fail_when
      @output_when = output_when
    end

    def run!(*arguments)
      @raw_commands << arguments
      command = arguments.last(2) == %w[-d production] ? arguments.first(arguments.length - 2) : arguments
      @commands << command
      raise KamalRestore::Error, "expected failure" if @fail_when&.call(command)

      @output_when&.call(command) || ""
    end

    def ignore_failure(*arguments)
      @raw_commands << arguments
      @commands << (arguments.last(2) == %w[-d production] ? arguments.first(arguments.length - 2) : arguments)
      ""
    end
  end

  def setup
    @databases = [
      { "name" => "primary", "path" => "/rails/storage/production.sqlite3" },
      { "name" => "storage", "path" => "/rails/storage/production_storage.sqlite3" },
      { "name" => "queue", "path" => "/rails/storage/production_queue.sqlite3" }
    ]
    @files = build_restore_files(@databases)
    RubyVM::InstructionSequence.compile(@files.fetch("bin/kamal-restore"))
    RubyVM::InstructionSequence.compile(@files.fetch("bin/kamal-restore-volume"))
    Object.send(:remove_const, :KamalRestore) if Object.const_defined?(:KamalRestore)
    Object.send(:remove_const, :Deployment) if Object.const_defined?(:Deployment)
    eval(
      @files.fetch("lib/deployment/kamal_operation.rb"),
      TOPLEVEL_BINDING,
      "generated/lib/deployment/kamal_operation.rb"
    )
    eval(@files.fetch("bin/kamal-restore"), TOPLEVEL_BINDING, "generated/bin/kamal-restore")
  end

  def teardown
    Object.send(:remove_const, :KamalRestore) if Object.const_defined?(:KamalRestore)
    Object.send(:remove_const, :Deployment) if Object.const_defined?(:Deployment)
  end

  def test_litestream_readiness_script_compiles
    files = build_kamal_files(
      "active_job" => "solid_queue",
      "action_cable" => "solid_cable",
      "web_push" => "use"
    )

    RubyVM::InstructionSequence.compile(files.fetch("bin/wait-for-litestream"))
    RubyVM::InstructionSequence.compile(files.fetch("bin/kamal-maintenance"))
    RubyVM::InstructionSequence.compile(files.fetch("lib/deployment/kamal_operation.rb"))
    RubyVM::InstructionSequence.compile(files.fetch("lib/deployment/configurator.rb"))
    RubyVM::InstructionSequence.compile(files.fetch("lib/deployment/server_setup.rb"))
    RubyVM::InstructionSequence.compile(files.fetch("test/lib/deployment/configurator_test.rb"))
    RubyVM::InstructionSequence.compile(files.fetch("test/lib/deployment/server_setup_test.rb"))
  end

  def test_docker_build_packages_follow_siwe_selection
    common_values = {
      "active_job" => "solid_queue",
      "action_cable" => "solid_cable",
      "web_push" => "use"
    }
    common_packages = %w[build-essential git nodejs npm pkg-config libsqlite3-dev libyaml-dev]
    siwe_packages = %w[autoconf automake libffi-dev libgmp-dev libssl-dev libtool python3-dev]
    without_siwe = build_kamal_files(common_values).fetch("Dockerfile")
    with_siwe = build_kamal_files(
      common_values.merge("additional_login_methods" => %w[siwe])
    ).fetch("Dockerfile")

    assert_includes without_siwe,
      "apt-get install --no-install-recommends -y #{common_packages.join(" ")} && \\"
    siwe_packages.each { |package| refute_includes without_siwe, package }
    assert_includes with_siwe,
      "apt-get install --no-install-recommends -y #{(common_packages + siwe_packages).join(" ")} && \\"

    runtime_stage = with_siwe.split("\nFROM base\n", 2).fetch(1)
    siwe_packages.each { |package| refute_includes runtime_stage, package }
  end

  def test_plan_only_uses_litestream_dry_run_without_mutating_kamal
    runner = FakeRunner.new

    status = KamalRestore::CLI.new(
      ["--destination=production", "--plan"],
      input: StringIO.new,
      output: StringIO.new,
      error: StringIO.new,
      runner:
    ).run

    assert_equal 0, status
    assert_equal @databases.length, runner.commands.length
    runner.commands.each do |command|
      assert_equal %w[accessory exec litestream restore], command.first(4)
      assert_includes command, "-dry-run"
      assert_includes command, "-json"
      refute_includes command, "-force"
      refute_includes command, "-if-replica-exists"
    end
    assert runner.raw_commands.all? { |command| command.last(2) == %w[-d production] }
  end

  def test_destination_is_required
    runner = FakeRunner.new

    status = KamalRestore::CLI.new(
      ["--plan"],
      input: StringIO.new,
      output: StringIO.new,
      error: StringIO.new,
      runner:
    ).run

    assert_equal 1, status
    assert_empty runner.commands
  end

  def test_plan_normalizes_rfc3339_timestamp
    runner = FakeRunner.new

    status = KamalRestore::CLI.new(
      ["--destination=production", "--plan", "--timestamp=2026-08-16T09:00:00+09:00"],
      input: StringIO.new,
      output: StringIO.new,
      error: StringIO.new,
      runner:
    ).run

    assert_equal 0, status
    runner.commands.each do |command|
      timestamp_index = command.index("-timestamp")
      refute_nil timestamp_index
      assert_equal "2026-08-16T00:00:00Z", command.fetch(timestamp_index + 1)
    end
  end

  def test_missing_backup_during_preview_does_not_quiesce_or_create_a_marker
    runner = FakeRunner.new(fail_when: ->(command) { command.include?("-dry-run") })

    status = KamalRestore::CLI.new(
      ["--destination=production"],
      input: TTYIO.new("RESTORE sample production latest\n"),
      output: TTYIO.new,
      error: StringIO.new,
      runner:
    ).run

    assert_equal 1, status
    refute runner.commands.any? { |command| command.first(2) == %w[server exec] }
    refute runner.commands.any? { |command| command == %w[app maintenance] }
  end

  def test_write_operation_requires_tty_and_exact_confirmation
    non_tty_runner = FakeRunner.new
    non_tty_status = KamalRestore::CLI.new(
      ["--destination=production"],
      input: StringIO.new("RESTORE sample production latest\n"),
      output: StringIO.new,
      error: StringIO.new,
      runner: non_tty_runner
    ).run

    assert_equal 1, non_tty_status
    refute non_tty_runner.commands.any? { |command| command.first(2) == %w[server exec] }

    mismatch_runner = FakeRunner.new
    mismatch_status = KamalRestore::CLI.new(
      ["--destination=production"],
      input: TTYIO.new("yes\n"),
      output: TTYIO.new,
      error: StringIO.new,
      runner: mismatch_runner
    ).run

    assert_equal 1, mismatch_status
    refute mismatch_runner.commands.any? { |command| command.first(2) == %w[server exec] }
  end

  def test_removed_confirmation_bypass_is_rejected
    runner = FakeRunner.new

    status = KamalRestore::CLI.new(
      ["--destination=production", "--yes"],
      input: TTYIO.new,
      output: TTYIO.new,
      error: StringIO.new,
      runner:
    ).run

    assert_equal 1, status
    assert_empty runner.commands
  end

  def test_rollback_requires_confirmation_and_restores_the_saved_database_set
    operation_id = "20260816T000000Z-012345abcdef"
    runner = FakeRunner.new

    status = KamalRestore::CLI.new(
      ["--destination=production", "--rollback=#{operation_id}"],
      input: TTYIO.new("ROLLBACK sample production #{operation_id}\n"),
      output: TTYIO.new,
      error: StringIO.new,
      runner:
    ).run

    assert_equal 0, status
    assert_equal @databases.length, runner.commands.count { |command| command.include?("sync") }
    assert runner.commands.any? do |command|
      command.include?("bin/kamal-restore-volume") && command.include?("rollback") && command.include?(operation_id)
    end
    assert_operator runner.commands.index(%w[app start -r web]), :<, runner.commands.index(%w[app start -r worker])
  end

  def test_successful_restore_quiesces_syncs_checks_and_restarts
    runner = FakeRunner.new

    status = KamalRestore::CLI.new(
      ["--destination=production"],
      input: TTYIO.new("RESTORE sample production latest\n"),
      output: TTYIO.new,
      error: StringIO.new,
      runner:
    ).run

    assert_equal 0, status
    assert runner.commands.any? { |command| command == %w[app maintenance] }
    assert runner.commands.any? { |command| command == %w[app stop] }
    assert_equal @databases.length, runner.commands.count { |command| command.include?("sync") }
    assert runner.commands.any? { |command| command.include?("-integrity-check") && command.include?("full") }
    assert runner.commands.any? { |command| command.include?("install") && command.include?("bin/kamal-restore-volume") }
    assert runner.commands.any? { |command| command == %w[accessory start litestream] }
    web_start = runner.commands.index(%w[app start -r web])
    worker_start = runner.commands.index(%w[app start -r worker])
    refute_nil web_start
    refute_nil worker_start
    assert_operator web_start, :<, worker_start
    assert runner.commands.any? { |command| command == %w[app live] }
    assert runner.commands.any? { |command| command.last == "rm -f .kamal/sample-production-restore-in-progress" }
  end

  def test_failure_before_install_restarts_original_services_without_install
    runner = FakeRunner.new(fail_when: ->(command) { command.include?("-integrity-check") })

    status = KamalRestore::CLI.new(
      ["--destination=production"],
      input: TTYIO.new("RESTORE sample production latest\n"),
      output: TTYIO.new,
      error: StringIO.new,
      runner:
    ).run

    assert_equal 1, status
    refute runner.commands.any? { |command| command.include?("install") }
    assert runner.commands.any? { |command| command == %w[accessory start litestream] }
    assert runner.commands.any? { |command| command == %w[app start -r web] }
    assert runner.commands.any? { |command| command.last == "rm -f .kamal/sample-production-restore-in-progress" }
  end

  def test_lock_conflict_aborts_before_application_stop
    runner = FakeRunner.new(fail_when: lambda do |command|
      command.first(2) == %w[lock acquire]
    end)

    status = KamalRestore::CLI.new(
      ["--destination=production"],
      input: TTYIO.new("RESTORE sample production latest\n"),
      output: TTYIO.new,
      error: StringIO.new,
      runner:
    ).run

    assert_equal 1, status
    refute runner.commands.any? { |command| command == %w[app stop] }
    refute runner.commands.any? { |command| command.last == "touch .kamal/sample-production-restore-in-progress" }
  end

  def test_maintenance_state_blocks_restore_before_marker_or_application_stop
    runner = FakeRunner.new(output_when: lambda do |command|
      next unless command.first(2) == %w[server exec]
      next unless command.last.include?("sample-production-maintenance.json")

      JSON.generate("phase" => "active")
    end)

    status = KamalRestore::CLI.new(
      ["--destination=production"],
      input: TTYIO.new("RESTORE sample production latest\n"),
      output: TTYIO.new,
      error: StringIO.new,
      runner:
    ).run

    assert_equal 1, status
    refute runner.commands.any? { |command| command == %w[app stop] }
    refute runner.commands.any? { |command| command.last == "touch .kamal/sample-production-restore-in-progress" }
    assert runner.commands.any? { |command| command == %w[lock release] }
  end

  def test_install_failure_keeps_services_stopped_and_marker_present
    runner = FakeRunner.new(fail_when: lambda do |command|
      command.include?("bin/kamal-restore-volume") && command.include?("install")
    end)

    status = KamalRestore::CLI.new(
      ["--destination=production"],
      input: TTYIO.new("RESTORE sample production latest\n"),
      output: TTYIO.new,
      error: StringIO.new,
      runner:
    ).run

    assert_equal 1, status
    assert runner.commands.any? { |command| command == %w[app stop] }
    assert runner.commands.any? { |command| command == %w[accessory stop litestream] }
    refute runner.commands.any? { |command| command == %w[app start -r web] }
    refute runner.commands.any? { |command| command.last == "rm -f .kamal/sample-production-restore-in-progress" }
  end

  def test_volume_helper_installs_and_rolls_back_the_database_set
    Dir.mktmpdir("kamal-restore") do |directory|
      databases = [
        { "name" => "primary", "path" => File.join(directory, "production.sqlite3"), "replica_env" => "PRIMARY" },
        { "name" => "storage", "path" => File.join(directory, "production_storage.sqlite3"), "replica_env" => "STORAGE" }
      ]
      files = build_restore_files(databases)
      script = File.join(directory, "kamal-restore-volume")
      File.write(script, files.fetch("bin/kamal-restore-volume"))
      operation_id = "20260816T000000Z-012345abcdef"
      databases.each do |database|
        File.write(database.fetch("path"), "old-#{database.fetch("name")}")
        File.write("#{database.fetch("path")}-wal", "wal-#{database.fetch("name")}")
      end

      run_helper!(script, "prepare", operation_id)
      staged = File.join(directory, ".restore", operation_id, "staged")
      databases.each { |database| File.write(File.join(staged, "#{database.fetch("name")}.sqlite3"), "new-#{database.fetch("name")}") }
      run_helper!(script, "install", operation_id)

      databases.each do |database|
        assert_equal "new-#{database.fetch("name")}", File.read(database.fetch("path"))
        previous = File.join(directory, ".restore", operation_id, "previous", File.basename(database.fetch("path")))
        assert_equal "old-#{database.fetch("name")}", File.read(previous)
        assert File.file?("#{previous}-wal")
      end

      run_helper!(script, "rollback", operation_id)
      databases.each do |database|
        assert_equal "old-#{database.fetch("name")}", File.read(database.fetch("path"))
        assert_equal "wal-#{database.fetch("name")}", File.read("#{database.fetch("path")}-wal")
      end
    end
  end

  def test_volume_helper_compensates_when_install_fails_after_file_renames
    Dir.mktmpdir("kamal-restore") do |directory|
      databases = [
        { "name" => "primary", "path" => File.join(directory, "production.sqlite3"), "replica_env" => "PRIMARY" },
        { "name" => "storage", "path" => File.join(directory, "production_storage.sqlite3"), "replica_env" => "STORAGE" }
      ]
      files = build_restore_files(databases)
      script = File.join(directory, "kamal-restore-volume")
      File.write(script, files.fetch("bin/kamal-restore-volume"))
      operation_id = "20260816T000000Z-fedcba543210"
      databases.each do |database|
        File.write(database.fetch("path"), "old-#{database.fetch("name")}")
        File.write("#{database.fetch("path")}-wal", "wal-#{database.fetch("name")}")
      end

      run_helper!(script, "prepare", operation_id)
      operation_directory = File.join(directory, ".restore", operation_id)
      staged = File.join(operation_directory, "staged")
      databases.each { |database| File.write(File.join(staged, "#{database.fetch("name")}.sqlite3"), "new-#{database.fetch("name")}") }
      FileUtils.mkdir(File.join(operation_directory, "manifest.json.tmp"))

      _stdout, _stderr, status = Open3.capture3(RbConfig.ruby, script, "install", operation_id)

      refute status.success?
      databases.each do |database|
        assert_equal "old-#{database.fetch("name")}", File.read(database.fetch("path"))
        assert_equal "wal-#{database.fetch("name")}", File.read("#{database.fetch("path")}-wal")
        assert_equal "new-#{database.fetch("name")}", File.read(File.join(staged, "#{database.fetch("name")}.sqlite3"))
      end
    end
  end

  def test_generated_kamal_configuration_is_valid_and_keeps_cache_out_of_litestream
    files = build_kamal_files(
      "active_job" => "solid_queue",
      "action_cable" => "solid_cable",
      "web_push" => "use"
    )
    original_environment = %w[KAMAL_DEPLOY_HOST KAMAL_PROXY_HOST KAMAL_DESTINATION].to_h { |name| [name, ENV[name]] }
    ENV.update(
      "KAMAL_DEPLOY_HOST" => "192.0.2.10",
      "KAMAL_PROXY_HOST" => "app.example.com",
      "KAMAL_DESTINATION" => "production"
    )
    deploy = YAML.safe_load(ERB.new(files.fetch("config/deploy.yml")).result, aliases: true)
    litestream = YAML.safe_load(files.fetch("config/litestream.yml"), aliases: true)

    assert_equal "sample", deploy.fetch("service")
    assert_equal "2.11.0", deploy.fetch("minimum_version")
    assert_equal true, deploy.fetch("require_destination")
    assert_equal "web", deploy.fetch("primary_role")
    assert_equal "amd64", deploy.dig("builder", "arch")
    assert_equal [], deploy.dig("servers", "web")
    assert_nil deploy.dig("proxy", "host")
    assert_nil deploy.dig("env", "clear", "APPLICATION_ORIGIN")
    assert_nil deploy.dig("accessories", "litestream", "host")
    assert_equal "bin/jobs --mode async", deploy.dig("servers", "worker", "cmd")
    assert_equal "litestream/litestream:0.5.15", deploy.dig("accessories", "litestream", "image")
    assert_equal ["sample_production_storage:/rails/storage"], deploy.dig("accessories", "litestream", "volumes")
    assert_equal "1000:1000", deploy.dig("accessories", "litestream", "options", "user")
    assert_equal %w[primary storage queue cable], litestream.fetch("dbs").map { |database| File.basename(database.fetch("path")).sub(/\Aproduction_?/, "").sub(".sqlite3", "").then { |name| name.empty? ? "primary" : name } }
    assert litestream.fetch("dbs").all? { |database| database.fetch("restore-if-db-not-exists") }
    assert_equal %w[primary storage queue cable], litestream.fetch("dbs").map { |database| database.dig("replica", "path") }
    litestream.fetch("dbs").each do |database|
      replica = database.fetch("replica")
      assert_equal "s3", replica.fetch("type")
      assert_equal "${LITESTREAM_R2_BUCKET}", replica.fetch("bucket")
      assert_equal "${CF_ACCOUNT_ID}.r2.cloudflarestorage.com", replica.fetch("endpoint")
      assert_equal "auto", replica.fetch("region")
      assert_equal "${R2_ACCESS_KEY}", replica.fetch("access-key-id")
      assert_equal "${R2_SECRET_KEY}", replica.fetch("secret-access-key")
    end
    refute files.fetch("config/litestream.yml").include?("production_cache.sqlite3")
    refute_match(/AWS_|LITESTREAM_(?:REPLICA|STORAGE_REPLICA|QUEUE_REPLICA|CABLE_REPLICA)_URL/, files.fetch("config/litestream.yml"))
    assert_includes files.fetch(".kamal/secrets-common"), "RAILS_MASTER_KEY=$(cat config/master.key)"
    refute files.key?(".kamal/secrets")
    assert_equal "--- {}\n", files.fetch("config/deploy.production.yml")
    assert_equal "--- {}\n", files.fetch("config/deploy.staging.yml")
    assert_includes files.fetch("lib/tasks/deployment.rake"), "Deployment::Configurator.new(root: Rails.root).run!"
    assert_includes files.fetch(".kamal/hooks/pre-deploy"), "sample-${KAMAL_DESTINATION}-restore-in-progress"
    assert_includes files.fetch(".kamal/hooks/pre-deploy"), "sample-${KAMAL_DESTINATION}-maintenance.json"
    assert_includes files.fetch("docs/deployment.md"), "## Database maintenance mode"
    assert_includes files.fetch("docs/deployment.md"), "bin/kamal-maintenance status --destination=production"

    minimal_files = build_kamal_files(
      "active_job" => "skip",
      "action_cable" => "async",
      "web_push" => "skip"
    )
    minimal_deploy = YAML.safe_load(ERB.new(minimal_files.fetch("config/deploy.yml")).result, aliases: true)
    minimal_litestream = YAML.safe_load(minimal_files.fetch("config/litestream.yml"), aliases: true)
    refute minimal_deploy.fetch("servers").key?("worker")
    assert_equal 2, minimal_litestream.fetch("dbs").length
    assert_includes minimal_files.fetch("bin/kamal-maintenance"), "HAS_WORKER = false"
  ensure
    original_environment&.each do |name, value|
      value.nil? ? ENV.delete(name) : ENV[name] = value
    end
  end

  def test_deployment_configurator_artifacts_compile_and_use_environment_specific_names
    files = build_kamal_files(
      "active_job" => "solid_queue",
      "action_cable" => "solid_cable",
      "web_push" => "skip"
    )

    %w[
      lib/deployment/command_runner.rb
      lib/deployment/cloudflare_client.rb
      lib/deployment/one_password_client.rb
      lib/deployment/kamal_secrets_writer.rb
      lib/deployment/configurator.rb
      lib/deployment/server_setup.rb
      lib/tasks/deployment.rake
      test/lib/deployment/configurator_test.rb
      test/lib/deployment/server_setup_test.rb
    ].each do |path|
      assert files.key?(path), "missing generated artifact: #{path}"
      RubyVM::InstructionSequence.compile(files.fetch(path)) if path.end_with?(".rb")
    end

    eval_deployment_files(files)
    assert_equal "deploy:sample:production", Deployment::Configurator.service_account_name("Sample!", "production")
    assert_equal "sample-staging", Deployment::Configurator.destination_vault_name("Sample!", "staging")
    assert_includes files.fetch("lib/tasks/deployment.rake"), "namespace :deployment"
    assert_includes files.fetch("lib/tasks/deployment.rake"), 'task :"setup-server" => :environment'
    refute files.fetch("lib/tasks/deployment.rake").include?("litestream:configure:r2")
  ensure
    Object.send(:remove_const, :Deployment) if Object.const_defined?(:Deployment)
  end

  def test_deployment_configurator_rejects_service_account_and_connect_authentication_before_commands
    files = build_kamal_files(
      "active_job" => "solid_queue",
      "action_cable" => "solid_cable",
      "web_push" => "skip"
    )
    eval_deployment_files(files)
    runner = Class.new do
      attr_reader :calls

      def initialize
        @calls = []
      end

      def capture(*)
        @calls << true
        raise "must stop before executing commands"
      end
    end.new

    %w[OP_SERVICE_ACCOUNT_TOKEN OP_CONNECT_HOST OP_CONNECT_TOKEN].each do |name|
      error = assert_raises(Deployment::Error) do
        Deployment::Configurator.new(
          runner:,
          environment: {
            "CLOUDFLARE_INITIAL_API_TOKEN" => "initial-token",
            name => "configured"
          }
        ).run!
      end
      assert_includes error.message, name
    end
    assert_empty runner.calls
  ensure
    Object.send(:remove_const, :Deployment) if Object.const_defined?(:Deployment)
  end

  def test_deployment_configurator_without_initial_token_has_no_external_side_effects
    files = build_kamal_files(
      "active_job" => "solid_queue",
      "action_cable" => "solid_cable",
      "web_push" => "skip"
    )
    eval_deployment_files(files)
    runner = Class.new do
      def capture(*)
        raise "missing-token instructions must not execute commands"
      end
    end.new
    output = StringIO.new

    Deployment::Configurator.new(
      runner:,
      output:,
      environment: {}
    ).run!

    assert_includes output.string, "CLOUDFLARE_INITIAL_API_TOKENが設定されていません"
    assert_includes output.string, "Account API Tokens Write"
  ensure
    Object.send(:remove_const, :Deployment) if Object.const_defined?(:Deployment)
  end

  def test_one_password_client_scopes_every_operation_to_the_selected_human_account
    files = build_kamal_files(
      "active_job" => "solid_queue",
      "action_cable" => "solid_cable",
      "web_push" => "skip"
    )
    eval_deployment_files(files)
    result = Deployment::Result
    runner = Class.new do
      attr_reader :calls

      def initialize(result)
        @result = result
        @calls = []
      end

      def capture(command, environment:, stdin_data:)
        @calls << { command:, environment:, stdin_data: }
        stdout = case command
        when ["op", "--version"]
          "2.31.0\n"
        when ["op", "account", "list", "--format=json"]
          JSON.generate([{ id: "op-account", name: "Example" }])
        when ["op", "user", "get", "--me", "--format=json", "--account", "op-account"]
          JSON.generate(id: "person", name: "Person", type: "MEMBER", state: "ACTIVE")
        when ["op", "vault", "list", "--format=json", "--account", "op-account"]
          JSON.generate([{ id: "vault", name: "sample-production" }])
        when ["op", "item", "list", "--include-archive", "--format=json", "--vault", "vault", "--account", "op-account"]
          "[]"
        when ["op", "service-account", "create", "deploy:sample:production", "--vault", "sample-production:read_items", "--raw", "--account", "op-account"]
          "service-token\n"
        else
          raise "unexpected command: #{command.inspect}"
        end
        @result.new(stdout:, stderr: "", success: true, exitstatus: 0)
      end
    end.new(result)
    client = Deployment::OnePasswordClient.new(runner:)

    assert_equal "2.31.0\n", client.version
    client.accounts
    assert_equal "person", client.current_user("op-account").fetch("id")
    client.vaults("op-account")
    client.items(vault_id: "vault", account_id: "op-account")
    assert_equal "service-token", client.create_service_account(
      "deploy:sample:production",
      vault_name: "sample-production",
      account_id: "op-account"
    )

    scoped = runner.calls.filter { |call| call.fetch(:command).first == "op" }.drop(2)
    assert scoped.all? { |call| call.fetch(:command).each_cons(2).include?(["--account", "op-account"]) }
    service_command = runner.calls.last.fetch(:command)
    assert_includes service_command, "sample-production:read_items"
    refute service_command.any? { |argument| argument.include?("write_items") || argument.include?("create_vault") }
    refute_includes service_command, "service-token"
  ensure
    Object.send(:remove_const, :Deployment) if Object.const_defined?(:Deployment)
  end

  def test_human_one_password_identity_must_be_active_and_not_a_service_account
    files = build_kamal_files(
      "active_job" => "solid_queue",
      "action_cable" => "solid_cable",
      "web_push" => "skip"
    )
    eval_deployment_files(files)
    configurator = Deployment::Configurator.new(environment: {})
    client = Object.new
    configurator.instance_variable_set(:@one_password, client)

    client.define_singleton_method(:current_user) do |_account_id|
      { "id" => "service", "type" => "SERVICE_ACCOUNT", "state" => "ACTIVE" }
    end
    error = assert_raises(Deployment::Error) do
      configurator.send(:validate_human_one_password_user!, "op-account")
    end
    assert_includes error.message, "人間ユーザー".b

    client.define_singleton_method(:current_user) do |_account_id|
      { "id" => "person", "type" => "MEMBER", "state" => "SUSPENDED" }
    end
    error = assert_raises(Deployment::Error) do
      configurator.send(:validate_human_one_password_user!, "op-account")
    end
    assert_includes error.message, "activeではありません".b
  ensure
    Object.send(:remove_const, :Deployment) if Object.const_defined?(:Deployment)
  end

  def test_vault_planning_reuses_one_exact_match_creates_missing_and_rejects_duplicates
    files = build_kamal_files(
      "active_job" => "solid_queue",
      "action_cable" => "solid_cable",
      "web_push" => "skip"
    )
    eval_deployment_files(files)
    configurator = Deployment::Configurator.new(environment: {})
    client = Object.new
    client.define_singleton_method(:vaults) do |_account_id|
      [
        { "id" => "production", "name" => "sample-production", "items" => 2 },
        { "id" => "similar", "name" => "sample-production-old", "items" => 0 }
      ]
    end
    configurator.instance_variable_set(:@one_password, client)

    plans = configurator.send(:plan_destination_vaults, %w[production staging], "op-account")
    assert_equal "reuse", plans.dig("production", "action")
    assert_equal "production", plans.dig("production", "record", "id")
    assert_equal "create", plans.dig("staging", "action")

    client.define_singleton_method(:vaults) do |_account_id|
      [
        { "id" => "first", "name" => "sample-production", "items" => 1 },
        { "id" => "second", "name" => "sample-production", "items" => 3 }
      ]
    end
    error = assert_raises(Deployment::Error) do
      configurator.send(:plan_destination_vaults, ["production"], "op-account")
    end
    assert_includes error.message, "同名の1Password vaultが複数".b
    assert_includes error.message, "first"
    assert_includes error.message, "second"
  ensure
    Object.send(:remove_const, :Deployment) if Object.const_defined?(:Deployment)
  end

  def test_service_account_token_item_is_reused_only_when_unique_active_and_complete
    files = build_kamal_files(
      "active_job" => "solid_queue",
      "action_cable" => "solid_cable",
      "web_push" => "skip"
    )
    eval_deployment_files(files)
    configurator = Deployment::Configurator.new(environment: {})
    client = Object.new
    item = {
      "id" => "service-item",
      "title" => "deploy:sample:production",
      "category" => "API_CREDENTIAL",
      "fields" => [{
        "id" => "OP_SERVICE_ACCOUNT_TOKEN",
        "label" => "OP_SERVICE_ACCOUNT_TOKEN",
        "type" => "CONCEALED",
        "value" => "service-token"
      }]
    }
    client.define_singleton_method(:item) { |_item_id, **| item }
    configurator.instance_variable_set(:@one_password, client)

    plan = configurator.send(
      :plan_service_account_item,
      "production",
      [{ "id" => "service-item", "title" => "deploy:sample:production" }],
      account_id: "op-account",
      vault_id: "vault"
    )
    assert_equal "reuse", plan.fetch("action")

    [
      [{ "id" => "one", "title" => "deploy:sample:production" }, { "id" => "two", "title" => "deploy:sample:production" }],
      [{ "id" => "archived", "title" => "deploy:sample:production", "state" => "ARCHIVED" }]
    ].each do |records|
      assert_raises(Deployment::Error) do
        configurator.send(
          :plan_service_account_item,
          "production",
          records,
          account_id: "op-account",
          vault_id: "vault"
        )
      end
    end

    item["fields"] = []
    error = assert_raises(Deployment::Error) do
      configurator.send(
        :plan_service_account_item,
        "production",
        [{ "id" => "service-item", "title" => "deploy:sample:production" }],
        account_id: "op-account",
        vault_id: "vault"
      )
    end
    assert_includes error.message, "OP_SERVICE_ACCOUNT_TOKENがありません".b

    item["fields"] = [{ "label" => "OP_SERVICE_ACCOUNT_TOKEN", "value" => "service-token" }]
    item["category"] = "LOGIN"
    error = assert_raises(Deployment::Error) do
      configurator.send(
        :plan_service_account_item,
        "production",
        [{ "id" => "service-item", "title" => "deploy:sample:production" }],
        account_id: "op-account",
        vault_id: "vault"
      )
    end
    assert_includes error.message, "API Credential".b
  ensure
    Object.send(:remove_const, :Deployment) if Object.const_defined?(:Deployment)
  end

  def test_r2_credentials_are_created_or_reused_as_one_consistent_pair
    files = build_kamal_files(
      "active_job" => "solid_queue",
      "action_cable" => "solid_cable",
      "web_push" => "skip"
    )
    eval_deployment_files(files)
    configurator = Deployment::Configurator.new(environment: {})
    account_id = "cf-account"
    bucket = "sample-db-production"
    permission_group = { "id" => "r2-write" }
    policy = configurator.send(:cloudflare_token_policy, account_id, bucket, "r2-write")
    raw_token = "cloudflare-secret"
    item = {
      "id" => "r2-item",
      "title" => "sample Litestream R2 production",
      "category" => "API_CREDENTIAL",
      "fields" => [
        { "id" => "CLOUDFLARE_R2_API_TOKEN", "label" => "CLOUDFLARE_R2_API_TOKEN", "type" => "CONCEALED", "value" => raw_token },
        { "id" => "CF_ACCOUNT_ID", "label" => "CF_ACCOUNT_ID", "type" => "STRING", "value" => account_id },
        { "id" => "LITESTREAM_R2_BUCKET", "label" => "LITESTREAM_R2_BUCKET", "type" => "STRING", "value" => bucket },
        { "id" => "R2_ACCESS_KEY", "label" => "R2_ACCESS_KEY", "type" => "CONCEALED", "value" => "token-id" },
        { "id" => "R2_SECRET_KEY", "label" => "R2_SECRET_KEY", "type" => "CONCEALED", "value" => Digest::SHA256.hexdigest(raw_token) },
        { "id" => "notesPlain", "label" => "notesPlain", "type" => "STRING", "value" => "preserved" }
      ]
    }
    item_plan = { "title" => item.fetch("title"), "id" => item.fetch("id"), "item" => item }
    token = {
      "id" => "token-id",
      "name" => "sample-r2-production",
      "status" => "active",
      "policies" => [policy]
    }

    reused = configurator.send(
      :plan_r2_credentials,
      "production",
      account_id:,
      bucket:,
      permission_group:,
      cloudflare_tokens: [token],
      item_plan:
    )
    assert_equal "reuse", reused.dig("token", "action")
    assert_equal "reuse", reused.dig("item", "action")
    assert_equal "r2-item", reused.dig("item", "id")

    created = configurator.send(
      :plan_r2_credentials,
      "production",
      account_id:,
      bucket:,
      permission_group:,
      cloudflare_tokens: [],
      item_plan: { "title" => item.fetch("title"), "id" => nil, "item" => nil }
    )
    assert_equal "create", created.dig("token", "action")
    assert_equal "create", created.dig("item", "action")

    [
      [
        { "id" => "one", "title" => item.fetch("title") },
        { "id" => "two", "title" => item.fetch("title") }
      ],
      [{ "id" => "archived", "title" => item.fetch("title"), "state" => "ARCHIVED" }]
    ].each do |items|
      assert_raises(Deployment::Error) do
        configurator.send(
          :plan_item,
          "production",
          items,
          account_id: "op-account",
          vault_id: "vault-id"
        )
      end
    end

    error = assert_raises(Deployment::Error) do
      configurator.send(
        :plan_r2_credentials,
        "production",
        account_id:,
        bucket:,
        permission_group:,
        cloudflare_tokens: [],
        item_plan:
      )
    end
    assert_includes error.message, "Cloudflare API tokenがありませんが".b

    error = assert_raises(Deployment::Error) do
      configurator.send(
        :plan_r2_credentials,
        "production",
        account_id:,
        bucket:,
        permission_group:,
        cloudflare_tokens: [token],
        item_plan: { "title" => item.fetch("title"), "id" => nil, "item" => nil }
      )
    end
    assert_includes error.message, "対応する1Password itemがありません".b
  ensure
    Object.send(:remove_const, :Deployment) if Object.const_defined?(:Deployment)
  end

  def test_new_r2_credential_pair_creates_and_saves_once
    files = build_kamal_files(
      "active_job" => "solid_queue",
      "action_cable" => "solid_cable",
      "web_push" => "skip"
    )
    eval_deployment_files(files)
    account_id = "cf-account"
    bucket = "sample-db-production"
    permission_group_id = "r2-write"
    api = Object.new
    create_calls = 0
    api.define_singleton_method(:create_token) do |requested_account_id, name:, policy:|
      create_calls += 1
      raise "unexpected account" unless requested_account_id == account_id

      {
        "id" => "token-id",
        "name" => name,
        "status" => "active",
        "value" => "cloudflare-secret",
        "policies" => [policy]
      }
    end
    configurator = Deployment::Configurator.new(environment: {}, cloudflare_client: api)
    policy = configurator.send(:cloudflare_token_policy, account_id, bucket, permission_group_id)
    token_plan = { "name" => "sample-r2-production", "action" => "create", "policy" => policy }
    credentials = configurator.send(:cloudflare_credentials, token_plan, account_id:, bucket:)

    one_password = Object.new
    save_calls = 0
    one_password.define_singleton_method(:api_credential_template) { |**| { "fields" => [] } }
    one_password.define_singleton_method(:save_item) do |item, **|
      save_calls += 1
      fields = item.fetch("fields").to_h { |field| [field.fetch("label"), field.fetch("value")] }
      raise "unexpected credentials" unless fields.fetch("CLOUDFLARE_R2_API_TOKEN") == "cloudflare-secret"

      { "id" => "r2-item" }
    end
    configurator.instance_variable_set(:@one_password, one_password)
    item_id = configurator.send(
      :apply_r2_item_plan,
      { "title" => "sample Litestream R2 production", "id" => nil, "item" => nil, "action" => "create" },
      account_id: "op-account",
      vault_id: "vault-id",
      fields: credentials.merge("CF_ACCOUNT_ID" => account_id, "LITESTREAM_R2_BUCKET" => bucket),
      concealed_fields: %w[CLOUDFLARE_R2_API_TOKEN R2_ACCESS_KEY R2_SECRET_KEY]
    )

    assert_equal "r2-item", item_id
    assert_equal 1, create_calls
    assert_equal 1, save_calls
  ensure
    Object.send(:remove_const, :Deployment) if Object.const_defined?(:Deployment)
  end

  def test_r2_credentials_reject_drift_before_apply
    files = build_kamal_files(
      "active_job" => "solid_queue",
      "action_cable" => "solid_cable",
      "web_push" => "skip"
    )
    eval_deployment_files(files)
    configurator = Deployment::Configurator.new(environment: {})
    account_id = "cf-account"
    bucket = "sample-db-production"
    permission_group = { "id" => "r2-write" }
    policy = configurator.send(:cloudflare_token_policy, account_id, bucket, "r2-write")
    raw_token = "cloudflare-secret"
    base_item = {
      "id" => "r2-item",
      "title" => "sample Litestream R2 production",
      "category" => "API_CREDENTIAL",
      "fields" => [
        { "id" => "CLOUDFLARE_R2_API_TOKEN", "label" => "CLOUDFLARE_R2_API_TOKEN", "type" => "CONCEALED", "value" => raw_token },
        { "id" => "CF_ACCOUNT_ID", "label" => "CF_ACCOUNT_ID", "type" => "STRING", "value" => account_id },
        { "id" => "LITESTREAM_R2_BUCKET", "label" => "LITESTREAM_R2_BUCKET", "type" => "STRING", "value" => bucket },
        { "id" => "R2_ACCESS_KEY", "label" => "R2_ACCESS_KEY", "type" => "CONCEALED", "value" => "token-id" },
        { "id" => "R2_SECRET_KEY", "label" => "R2_SECRET_KEY", "type" => "CONCEALED", "value" => Digest::SHA256.hexdigest(raw_token) }
      ]
    }
    base_token = {
      "id" => "token-id",
      "name" => "sample-r2-production",
      "status" => "active",
      "policies" => [policy]
    }
    cases = {
      "activeではありません" => [base_token.merge("status" => "disabled"), base_item],
      "権限またはbucketが期待値と一致しません" => [base_token.merge("policies" => []), base_item],
      "R2_ACCESS_KEYが一致しません" => [base_token, changed_r2_item(base_item, "R2_ACCESS_KEY", value: "other-id")],
      "R2_SECRET_KEYが一致しません" => [base_token, changed_r2_item(base_item, "R2_SECRET_KEY", value: "wrong")],
      "CF_ACCOUNT_IDが一致しません" => [base_token, changed_r2_item(base_item, "CF_ACCOUNT_ID", value: "other-account")],
      "LITESTREAM_R2_BUCKETが一致しません" => [base_token, changed_r2_item(base_item, "LITESTREAM_R2_BUCKET", value: "other-bucket")],
      "field typeが一致しません" => [base_token, changed_r2_item(base_item, "R2_SECRET_KEY", type: "STRING")],
      "API Credentialではありません" => [base_token, base_item.merge("category" => "LOGIN")]
    }

    cases.each do |message, (token, item)|
      error = assert_raises(Deployment::Error) do
        configurator.send(
          :plan_r2_credentials,
          "production",
          account_id:,
          bucket:,
          permission_group:,
          cloudflare_tokens: [token],
          item_plan: { "title" => item.fetch("title"), "id" => item.fetch("id"), "item" => item }
        )
      end
      assert_includes error.message, message.b
    end

    error = assert_raises(Deployment::Error) do
      configurator.send(
        :plan_r2_credentials,
        "production",
        account_id:,
        bucket:,
        permission_group:,
        cloudflare_tokens: [base_token, base_token],
        item_plan: { "title" => base_item.fetch("title"), "id" => base_item.fetch("id"), "item" => base_item }
      )
    end
    assert_includes error.message, "同名のCloudflare API tokenが複数".b
  ensure
    Object.send(:remove_const, :Deployment) if Object.const_defined?(:Deployment)
  end

  def test_reused_r2_item_is_not_saved_and_is_described_as_existing
    files = build_kamal_files(
      "active_job" => "solid_queue",
      "action_cable" => "solid_cable",
      "web_push" => "skip"
    )
    eval_deployment_files(files)
    output = StringIO.new
    configurator = Deployment::Configurator.new(output:, environment: {})
    one_password = Object.new
    one_password.define_singleton_method(:save_item) { |*, **| raise "must not save a reused item" }
    configurator.instance_variable_set(:@one_password, one_password)
    item_plan = {
      "title" => "sample Litestream R2 production",
      "id" => "r2-item",
      "item" => {},
      "action" => "reuse"
    }
    fields = {
      "CLOUDFLARE_R2_API_TOKEN" => "cloudflare-secret",
      "CF_ACCOUNT_ID" => "cf-account",
      "LITESTREAM_R2_BUCKET" => "sample-db-production",
      "R2_ACCESS_KEY" => "token-id",
      "R2_SECRET_KEY" => Digest::SHA256.hexdigest("cloudflare-secret")
    }

    assert_equal "r2-item", configurator.send(
      :apply_r2_item_plan,
      item_plan,
      account_id: "op-account",
      vault_id: "vault-id",
      fields:,
      concealed_fields: %w[CLOUDFLARE_R2_API_TOKEN R2_ACCESS_KEY R2_SECRET_KEY]
    )

    configurator.send(
      :print_plan,
      { "user" => { "email" => "person@example.com" }, "authType" => "OAuth" },
      { "id" => "cf-account", "name" => "Cloudflare" },
      { "id" => "op-account", "name" => "Example" },
      { "id" => "person", "name" => "Person" },
      { "production" => { "record" => { "id" => "vault-id", "name" => "sample-production" } } },
      ["production"],
      { "production" => "sample-db-production" },
      ["sample-db-production"],
      {
        "production" => {
          "r2" => item_plan,
          "service_account" => { "title" => "deploy:sample:production", "action" => "reuse" }
        }
      },
      {
        "production" => {
          "name" => "sample-r2-production",
          "action" => "reuse"
        }
      }
    )
    assert_includes output.string, "1Password item=sample Litestream R2 production (既存を使用)"
    refute_includes output.string, "更新"
    refute_includes output.string, "cloudflare-secret"
  ensure
    Object.send(:remove_const, :Deployment) if Object.const_defined?(:Deployment)
  end

  def test_default_no_finishes_all_discovery_without_mutating_selected_or_unselected_environment
    files = build_kamal_files(
      "active_job" => "solid_queue",
      "action_cable" => "solid_cable",
      "web_push" => "skip"
    )
    eval_deployment_files(files)

    Dir.mktmpdir("deployment-configurator") do |directory|
      root = Pathname(directory)
      wrangler = root.join("node_modules/.bin/wrangler")
      FileUtils.mkdir_p(wrangler.dirname)
      wrangler.write("#!/bin/sh\n")
      wrangler.chmod(0o755)
      result = Deployment::Result
      runner = Class.new do
        attr_reader :calls

        def initialize(result)
          @result = result
          @calls = []
        end

        def capture(command, environment:, stdin_data:)
          @calls << { command:, environment:, stdin_data: }
          stdout, stderr, success = case command
          when [command.first, "--version"]
            command.first == "op" ? ["2.31.0\n", "", true] : ["wrangler 4.30.0\n", "", true]
          when [command.first, "whoami", "--json"]
            [JSON.generate(loggedIn: true, authType: "OAuth Token", user: { email: "person@example.com" }, accounts: [{ id: "cf-account", name: "Cloudflare" }]), "", true]
          when ["op", "account", "list", "--format=json"]
            [JSON.generate([{ id: "op-account", name: "Example" }]), "", true]
          when ["op", "user", "get", "--me", "--format=json", "--account", "op-account"]
            [JSON.generate(id: "person", name: "Person", type: "MEMBER", state: "ACTIVE"), "", true]
          when ["op", "vault", "list", "--format=json", "--account", "op-account"]
            [JSON.generate([{ id: "production-vault", name: "sample-production" }]), "", true]
          when ["op", "item", "list", "--include-archive", "--format=json", "--vault", "production-vault", "--account", "op-account"]
            ["[]", "", true]
          else
            if command.include?("bucket") && command.include?("info")
              ["", "The specified bucket does not exist. [code: 10006]", false]
            else
              raise "unexpected command: #{command.inspect}"
            end
          end
          @result.new(stdout:, stderr:, success:, exitstatus: success ? 0 : 1)
        end
      end.new(result)
      prompt = Class.new do
        def choose(choices, header:, selected:, no_limit: false)
          return ["production"] if no_limit

          [header, selected]
          choices.fetch(0)
        end

        def input(header:, value:)
          [header, value]
          value
        end

        def confirm(*, **)
          false
        end
      end.new
      output = StringIO.new

      Deployment::Configurator.new(
        root:,
        prompt:,
        runner:,
        output:,
        environment: { "CLOUDFLARE_INITIAL_API_TOKEN" => "initial-token" },
        cloudflare_client: ValidInitialTokenClient.new
      ).run!

      assert_includes output.string, "適用予定"
      assert_includes output.string, "中止しました"
      refute runner.calls.any? { |call| call.fetch(:command).include?("create") }
      refute runner.calls.any? { |call| call.fetch(:command).include?("staging") }
      refute_path_exists root.join(".kamal/secrets.production")
      refute_path_exists root.join(".kamal/secrets.staging")
    end
  ensure
    Object.send(:remove_const, :Deployment) if Object.const_defined?(:Deployment)
  end

  def test_service_account_creation_uses_read_only_scope_and_saves_token_as_concealed_item
    files = build_kamal_files(
      "active_job" => "solid_queue",
      "action_cable" => "solid_cable",
      "web_push" => "skip"
    )
    eval_deployment_files(files)
    result = Deployment::Result
    runner = Class.new do
      attr_reader :calls

      def initialize(result)
        @result = result
        @calls = []
      end

      def capture(command, environment:, stdin_data:)
        @calls << { command:, environment:, stdin_data: }
        stdout = case command
        when ["op", "service-account", "create", "deploy:sample:production", "--vault", "sample-production:read_items", "--raw", "--account", "op-account"]
          "service-token"
        when ["op", "item", "template", "get", "API Credential", "--account", "op-account"]
          JSON.generate(fields: [])
        when ["op", "item", "create", "--format=json", "--vault", "vault", "--account", "op-account", "-"]
          JSON.generate(id: "service-item")
        else
          raise "unexpected command: #{command.inspect}"
        end
        @result.new(stdout:, stderr: "", success: true, exitstatus: 0)
      end
    end.new(result)
    output = StringIO.new
    configurator = Deployment::Configurator.new(runner:, output:, environment: {})
    plan = {
      "title" => "deploy:sample:production",
      "id" => nil,
      "item" => nil,
      "action" => "create"
    }

    assert configurator.send(
      :apply_service_account_plan,
      plan,
      account_id: "op-account",
      vault: { "id" => "vault", "name" => "sample-production" }
    )

    service_call = runner.calls.fetch(0)
    assert_includes service_call.fetch(:command), "sample-production:read_items"
    refute_includes service_call.fetch(:command), "service-token"
    saved = JSON.parse(String(runner.calls.fetch(2).fetch(:stdin_data)))
    token_field = saved.fetch("fields").find { |field| field["label"] == "OP_SERVICE_ACCOUNT_TOKEN" }
    assert_equal "CONCEALED", token_field.fetch("type")
    assert_equal "service-token", token_field.fetch("value")
    refute_includes output.string, "service-token"
  ensure
    Object.send(:remove_const, :Deployment) if Object.const_defined?(:Deployment)
  end

  def test_item_save_failure_reconciles_ambiguous_success_without_exposing_secret
    files = build_kamal_files(
      "active_job" => "solid_queue",
      "action_cable" => "solid_cable",
      "web_push" => "skip"
    )
    eval_deployment_files(files)
    output = StringIO.new
    configurator = Deployment::Configurator.new(output:, environment: {})
    client = Object.new
    client.define_singleton_method(:api_credential_template) { |**| { "fields" => [] } }
    client.define_singleton_method(:save_item) { |*, **| raise Deployment::Error, "write failed" }
    client.define_singleton_method(:items) do |**|
      [{ "id" => "saved-item", "title" => "deploy:sample:production" }]
    end
    client.define_singleton_method(:item) do |*, **|
      {
        "fields" => [{
          "label" => "OP_SERVICE_ACCOUNT_TOKEN",
          "value" => "service-token"
        }]
      }
    end
    configurator.instance_variable_set(:@one_password, client)

    item_id = configurator.send(
      :persist_item_with_retry,
      { "title" => "deploy:sample:production", "id" => nil, "item" => nil },
      account_id: "op-account",
      vault_id: "vault",
      fields: { "OP_SERVICE_ACCOUNT_TOKEN" => "service-token" },
      concealed_fields: ["OP_SERVICE_ACCOUNT_TOKEN"],
      label: "1Password service account token"
    )

    assert_equal "saved-item", item_id
    refute_includes output.string, "service-token"
  ensure
    Object.send(:remove_const, :Deployment) if Object.const_defined?(:Deployment)
  end

  def test_item_save_failure_retries_after_reconciliation_finds_nothing
    files = build_kamal_files(
      "active_job" => "solid_queue",
      "action_cable" => "solid_cable",
      "web_push" => "skip"
    )
    eval_deployment_files(files)
    output = StringIO.new
    prompt = Class.new do
      attr_reader :calls

      def initialize
        @calls = 0
      end

      def confirm(*) # rubocop:disable Naming/PredicateMethod
        @calls += 1
        true
      end
    end.new
    configurator = Deployment::Configurator.new(prompt:, output:, environment: {})
    client = Object.new
    save_calls = 0
    client.define_singleton_method(:api_credential_template) { |**| { "fields" => [] } }
    client.define_singleton_method(:save_item) do |*, **|
      save_calls += 1
      raise Deployment::Error, "write failed" if save_calls == 1

      { "id" => "saved-item" }
    end
    client.define_singleton_method(:items) { |**| [] }
    configurator.instance_variable_set(:@one_password, client)

    item_id = configurator.send(
      :persist_item_with_retry,
      { "title" => "deploy:sample:production", "id" => nil, "item" => nil },
      account_id: "op-account",
      vault_id: "vault",
      fields: { "OP_SERVICE_ACCOUNT_TOKEN" => "service-token" },
      concealed_fields: ["OP_SERVICE_ACCOUNT_TOKEN"],
      label: "1Password service account token"
    )

    assert_equal "saved-item", item_id
    assert_equal 2, save_calls
    assert_equal 1, prompt.calls
    refute_includes output.string, "service-token"
  ensure
    Object.send(:remove_const, :Deployment) if Object.const_defined?(:Deployment)
  end

  def test_missing_service_account_token_response_stops_without_recreating_account
    files = build_kamal_files(
      "active_job" => "solid_queue",
      "action_cable" => "solid_cable",
      "web_push" => "skip"
    )
    eval_deployment_files(files)
    configurator = Deployment::Configurator.new(prompt: Object.new, output: StringIO.new, environment: {})
    client = Object.new
    create_calls = 0
    client.define_singleton_method(:create_service_account) do |*, **|
      create_calls += 1
      ""
    end
    configurator.instance_variable_set(:@one_password, client)

    error = assert_raises(Deployment::Error) do
      configurator.send(
        :apply_service_account_plan,
        { "title" => "deploy:sample:production", "action" => "create" },
        account_id: "op-account",
        vault: { "id" => "vault", "name" => "sample-production" }
      )
    end

    assert_equal 1, create_calls
    assert_includes error.message, "再作成せず".b
  ensure
    Object.send(:remove_const, :Deployment) if Object.const_defined?(:Deployment)
  end

  def test_item_save_terminal_recovery_requires_two_confirmations_and_never_leaks_to_normal_output
    files = build_kamal_files(
      "active_job" => "solid_queue",
      "action_cable" => "solid_cable",
      "web_push" => "skip"
    )
    eval_deployment_files(files)
    output = StringIO.new
    terminal = StringIO.new
    prompt = Class.new do
      attr_reader :calls

      def initialize
        @answers = [false, true]
        @calls = []
      end

      def confirm(message, **options)
        @calls << { message:, options: }
        @answers.shift
      end
    end.new
    configurator = Deployment::Configurator.new(prompt:, output:, terminal:, environment: {})
    client = Object.new
    client.define_singleton_method(:api_credential_template) { |**| { "fields" => [] } }
    client.define_singleton_method(:save_item) { |*, **| raise Deployment::Error, "write failed" }
    client.define_singleton_method(:items) { |**| [] }
    configurator.instance_variable_set(:@one_password, client)

    item_id = configurator.send(
      :persist_item_with_retry,
      { "title" => "sample Litestream R2 production", "id" => nil, "item" => nil },
      account_id: "op-account",
      vault_id: "vault",
      fields: { "CLOUDFLARE_R2_API_TOKEN" => "cloudflare-secret" },
      concealed_fields: ["CLOUDFLARE_R2_API_TOKEN"],
      label: "Cloudflare API token"
    )

    assert_nil item_id
    assert_equal 2, prompt.calls.length
    assert_equal true, prompt.calls.fetch(0).dig(:options, :default)
    assert_equal false, prompt.calls.fetch(1).dig(:options, :default)
    assert_includes terminal.string, "cloudflare-secret"
    refute_includes output.string, "cloudflare-secret"
  ensure
    Object.send(:remove_const, :Deployment) if Object.const_defined?(:Deployment)
  end

  def test_kamal_secrets_writer_is_atomic_id_based_and_excludes_service_account_token
    files = build_kamal_files(
      "active_job" => "solid_queue",
      "action_cable" => "solid_cable",
      "web_push" => "skip"
    )
    eval_deployment_files(files)

    Dir.mktmpdir("kamal-secrets-writer") do |directory|
      root = Pathname(directory)
      Deployment::KamalSecretsWriter.new(root:).write(
        destination: "production",
        account_id: "op-account",
        vault_id: "vault-id",
        item_id: "r2-item-id"
      )
      path = root.join(".kamal/secrets.production")
      content = path.read
      assert_equal 0o600, path.stat.mode & 0o777
      assert_includes content, "--account op-account"
      assert_includes content, "--from vault-id/r2-item-id"
      assert_includes content, "R2_ACCESS_KEY"
      refute_includes content, "OP_SERVICE_ACCOUNT_TOKEN"
    end
  ensure
    Object.send(:remove_const, :Deployment) if Object.const_defined?(:Deployment)
  end

  def test_cloudflare_client_uses_account_token_api_and_redacts_bearer_secret
    files = build_kamal_files(
      "active_job" => "solid_queue",
      "action_cable" => "solid_cable",
      "web_push" => "skip"
    )
    eval_deployment_files(files)
    requests = []
    response = Struct.new(:code, :body)
    factory = lambda do |_host, _port|
      Class.new do
        attr_accessor :use_ssl, :open_timeout, :read_timeout, :write_timeout

        define_method(:initialize) do |requests, response|
          @requests = requests
          @response = response
        end

        define_method(:request) do |request|
          @requests << request
          @response
        end
      end.new(
        requests,
        response.new(
          "403",
          JSON.generate(success: false, errors: [{ code: 9109, message: "Bearer initial-secret rejected" }])
        )
      )
    end
    client = Deployment::CloudflareClient.new(token: "initial-secret", http_factory: factory)

    error = assert_raises(Deployment::CloudflareClient::RequestError) do
      client.permission_groups("cf-account", name: "Workers R2 Storage Bucket Item Write")
    end

    assert_equal 403, error.status
    assert_equal [9109], error.codes
    refute_includes error.message, "initial-secret"
    assert_equal "Bearer initial-secret", requests.fetch(0)["Authorization"]
    assert_equal "/client/v4/accounts/cf-account/tokens/permission_groups", requests.fetch(0).uri.path
  ensure
    Object.send(:remove_const, :Deployment) if Object.const_defined?(:Deployment)
  end

  def test_wrangler_bucket_errors_are_not_misclassified_as_missing
    files = build_kamal_files(
      "active_job" => "solid_queue",
      "action_cable" => "solid_cable",
      "web_push" => "skip"
    )
    eval_deployment_files(files)

    Dir.mktmpdir("wrangler-client") do |directory|
      root = Pathname(directory)
      wrangler = root.join("node_modules/.bin/wrangler")
      FileUtils.mkdir_p(wrangler.dirname)
      wrangler.write("#!/bin/sh\n")
      wrangler.chmod(0o755)
      result = Deployment::Result
      runner = Class.new do
        def initialize(result)
          @result = result
        end

        def capture(*)
          @result.new(stdout: "", stderr: "Authentication error [code: 10000]", success: false, exitstatus: 1)
        end
      end.new(result)
      client = Deployment::CloudflareClient.new(token: "initial-token", root:, runner:)

      error = assert_raises(Deployment::Error) do
        client.existing_buckets("cf-account", ["sample-db-production"])
      end
      assert_includes error.message, "Authentication error"
    end
  ensure
    Object.send(:remove_const, :Deployment) if Object.const_defined?(:Deployment)
  end
  private

  def changed_r2_item(item, field_name, value: nil, type: nil)
    changed = JSON.parse(JSON.generate(item))
    field = changed.fetch("fields").find { |candidate| candidate["id"] == field_name }
    field["value"] = value if value
    field["type"] = type if type
    changed
  end

  def eval_deployment_files(files)
    Object.send(:remove_const, :Deployment) if Object.const_defined?(:Deployment)
    paths = %w[
      lib/deployment/command_runner.rb
      lib/deployment/cloudflare_client.rb
      lib/deployment/one_password_client.rb
      lib/deployment/kamal_secrets_writer.rb
      lib/deployment/configurator.rb
      lib/deployment/server_setup.rb
    ]
    features = paths.map { |path| path.delete_prefix("lib/") }
    added_features = features.reject { |feature| $LOADED_FEATURES.include?(feature) }
    $LOADED_FEATURES.concat(added_features)
    paths.each do |path|
      eval(files.fetch(path), TOPLEVEL_BINDING, "generated/#{path}")
    end
  ensure
    added_features&.each { |feature| $LOADED_FEATURES.delete(feature) }
  end

  def build_restore_files(databases)
    source = File.binread(TEMPLATE_PATH)
    start_index = source.index("def kamal_restore_cli_body") || raise("restore source start not found")
    end_index = source.index("def configure_kamal\n", start_index) || raise("restore source end not found")
    builder_class = Class.new
    builder_class.class_eval(source.byteslice(start_index...end_index), TEMPLATE_PATH, 1)
    files = {}
    builder = builder_class.new
    builder.define_singleton_method(:create_file) do |path, content, force:|
      raise "force must be true" unless force

      files[path] = content
    end
    builder.define_singleton_method(:chmod) { |_path, _mode| nil }
    builder.send(:configure_kamal_restore, "sample", databases)
    files
  end

  def build_kamal_files(values)
    source = File.binread(TEMPLATE_PATH)
    start_index = source.index("def kamal_restore_cli_body") || raise("kamal source start not found")
    end_index = source.index("after_bundle do", start_index) || raise("kamal source end not found")
    builder_class = Class.new
    builder_class.const_set(:PLAN, { "app_id" => "sample" })
    builder_class.const_set(:VALUES, {
      "additional_login_methods" => [],
      "default_locale" => "ja"
    }.merge(values))
    builder_class.const_set(:YAML, YAML)
    builder_class.class_eval(source.byteslice(start_index...end_index), TEMPLATE_PATH, 1)
    files = {}
    builder = builder_class.new
    builder.define_singleton_method(:create_file) do |path, content, force:|
      raise "force must be true" unless force

      files[path] = content
    end
    builder.define_singleton_method(:append_to_file) do |path, content|
      files[path] = files.fetch(path, "") + content
    end
    builder.define_singleton_method(:remove_file) { |path| files.delete(path) }
    builder.define_singleton_method(:chmod) { |_path, _mode| nil }
    builder.send(:configure_kamal)
    files
  end

  def run_helper!(script, *arguments)
    _stdout, stderr, status = Open3.capture3(RbConfig.ruby, script, *arguments)
    assert status.success?, stderr
  end
end
