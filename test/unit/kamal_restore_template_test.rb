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

  class FakeRunner
    attr_reader :commands, :raw_commands

    def initialize(fail_when: nil)
      @commands = []
      @raw_commands = []
      @fail_when = fail_when
    end

    def run!(*arguments)
      @raw_commands << arguments
      command = arguments.last(2) == %w[-d production] ? arguments.first(arguments.length - 2) : arguments
      @commands << command
      raise KamalRestore::Error, "expected failure" if @fail_when&.call(command)

      ""
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
    eval(@files.fetch("bin/kamal-restore"), TOPLEVEL_BINDING, "generated/bin/kamal-restore")
  end

  def teardown
    Object.send(:remove_const, :KamalRestore) if Object.const_defined?(:KamalRestore)
  end

  def test_litestream_readiness_script_compiles
    files = build_kamal_files(
      "active_job" => "solid_queue",
      "action_cable" => "solid_cable",
      "web_push" => "use"
    )

    RubyVM::InstructionSequence.compile(files.fetch("bin/wait-for-litestream"))
    RubyVM::InstructionSequence.compile(files.fetch("lib/litestream/r2_configurator.rb"))
    RubyVM::InstructionSequence.compile(files.fetch("test/lib/litestream/r2_configurator_test.rb"))
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
    assert runner.commands.any? { |command| command.last == "rm -f .kamal/sample-production-restore-in-progress" }
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
    assert_equal ["192.0.2.10"], deploy.dig("servers", "web")
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
    assert_includes files.fetch("lib/tasks/litestream.rake"), "Litestream::R2Configurator.new(root: Rails.root).run!"

    minimal_files = build_kamal_files(
      "active_job" => "skip",
      "action_cable" => "async",
      "web_push" => "skip"
    )
    minimal_deploy = YAML.safe_load(ERB.new(minimal_files.fetch("config/deploy.yml")).result, aliases: true)
    minimal_litestream = YAML.safe_load(minimal_files.fetch("config/litestream.yml"), aliases: true)
    refute minimal_deploy.fetch("servers").key?("worker")
    assert_equal 2, minimal_litestream.fetch("dbs").length
  ensure
    original_environment&.each do |name, value|
      value.nil? ? ENV.delete(name) : ENV[name] = value
    end
  end

  def test_r2_configurator_creates_only_missing_bucket_and_writes_id_based_secret_references
    files = build_kamal_files(
      "active_job" => "solid_queue",
      "action_cable" => "solid_cable",
      "web_push" => "skip"
    )
    Object.send(:remove_const, :Litestream) if Object.const_defined?(:Litestream)
    eval(files.fetch("lib/litestream/r2_configurator.rb"), TOPLEVEL_BINDING, "generated/lib/litestream/r2_configurator.rb")

    Dir.mktmpdir("r2-configurator") do |directory|
      root = Pathname(directory)
      wrangler = root.join("node_modules/.bin/wrangler")
      FileUtils.mkdir_p(wrangler.dirname)
      wrangler.write("#!/bin/sh\n")
      wrangler.chmod(0o755)
      result = Litestream::R2Configurator::Result
      responses = [
        result.new(stdout: "wrangler 4.30.0\n", stderr: "", success: true, exitstatus: 0),
        result.new(stdout: "2.31.0\n", stderr: "", success: true, exitstatus: 0),
        result.new(stdout: JSON.generate(loggedIn: true, authType: "OAuth Token", user: { email: "person@example.com" }, accounts: [{ id: "cf-other", name: "Other Cloudflare" }, { id: "cf-account", name: "Cloudflare" }]), stderr: "", success: true, exitstatus: 0),
        result.new(stdout: "", stderr: "The specified bucket does not exist. [code: 10006]", success: false, exitstatus: 1),
        result.new(stdout: JSON.generate(name: "sample-db-staging"), stderr: "", success: true, exitstatus: 0),
        result.new(stdout: JSON.generate([{ account_uuid: "op-other", name: "Other 1Password" }, { account_uuid: "op-account", name: "1Password" }]), stderr: "", success: true, exitstatus: 0),
        result.new(stdout: JSON.generate([{ id: "vault-other", name: "Other Vault" }, { id: "vault-id", name: "Deploy" }]), stderr: "", success: true, exitstatus: 0),
        result.new(stdout: JSON.generate([{ id: "staging-item", title: "sample Litestream R2 staging" }]), stderr: "", success: true, exitstatus: 0),
        result.new(stdout: "created\n", stderr: "", success: true, exitstatus: 0),
        result.new(stdout: JSON.generate(fields: []), stderr: "", success: true, exitstatus: 0),
        result.new(stdout: JSON.generate(id: "production-item"), stderr: "", success: true, exitstatus: 0),
        result.new(stdout: JSON.generate(id: "staging-item", title: "sample Litestream R2 staging", fields: []), stderr: "", success: true, exitstatus: 0),
        result.new(stdout: JSON.generate(id: "staging-item"), stderr: "", success: true, exitstatus: 0)
      ]
      runner = Class.new do
        attr_reader :calls

        define_method(:initialize) do |scripted|
          @scripted = scripted
          @calls = []
        end

        define_method(:capture) do |command, environment:, stdin_data:|
          @calls << { command:, environment:, stdin_data: }
          @scripted.fetch(@calls.length - 1)
        end
      end.new(responses)
      prompt = Class.new do
        def initialize
          @inputs = %w[
            sample-db-production sample-db-staging
            production-access production-secret staging-access staging-secret
          ]
        end

        def choose(choices, header:, selected:, no_limit: false)
          return choices if no_limit

          header.to_s
          choices.last || selected.fetch(0)
        end

        def input(**)
          @inputs.shift
        end

        def confirm(*)
          true
        end
      end.new

      output = StringIO.new
      Litestream::R2Configurator.new(root:, prompt:, runner:, output:).run!

      create_calls = runner.calls.select { |call| call.fetch(:command).include?("create") }
      assert_equal 2, create_calls.length
      assert create_calls.any? { |call| call.fetch(:command).include?("sample-db-production") }
      refute create_calls.any? { |call| call.fetch(:command).include?("sample-db-staging") && call.fetch(:command).include?("bucket") }
      assert runner.calls.grep_v(nil).all? do |call|
        (call.fetch(:command) & %w[production-access production-secret staging-access staging-secret]).empty?
      end
      refute_match(/production-access|production-secret|staging-access|staging-secret/, output.string)
      assert runner.calls.select { |call| call.fetch(:stdin_data)&.match?(/production-access|production-secret|staging-access|staging-secret/) }.all? do |call|
        call.fetch(:command).first(2) == %w[op item]
      end
      assert runner.calls.select { |call| call.fetch(:command).include?("bucket") }.all? do |call|
        call.fetch(:environment) == { "CLOUDFLARE_ACCOUNT_ID" => "cf-account" }
      end
      assert runner.calls.any? do |call|
        call.fetch(:command) == %w[op vault list --format json --account op-account]
      end
      production_secrets = root.join(".kamal/secrets.production").read
      staging_secrets = root.join(".kamal/secrets.staging").read
      assert_includes production_secrets, "vault-id/production-item"
      assert_includes staging_secrets, "vault-id/staging-item"
      refute_match(/production-access|production-secret|staging-access|staging-secret/, production_secrets + staging_secrets)
      assert_equal 0o600, root.join(".kamal/secrets.production").stat.mode & 0o777
    end
  ensure
    Object.send(:remove_const, :Litestream) if Object.const_defined?(:Litestream)
  end

  def test_r2_configurator_does_not_treat_wrangler_errors_as_a_missing_bucket
    files = build_kamal_files(
      "active_job" => "skip",
      "action_cable" => "async",
      "web_push" => "skip"
    )
    Object.send(:remove_const, :Litestream) if Object.const_defined?(:Litestream)
    eval(files.fetch("lib/litestream/r2_configurator.rb"), TOPLEVEL_BINDING, "generated/lib/litestream/r2_configurator.rb")

    %w[authentication permission network].each do |failure|
      Dir.mktmpdir("r2-configurator-error") do |directory|
        root = Pathname(directory)
        wrangler = root.join("node_modules/.bin/wrangler")
        FileUtils.mkdir_p(wrangler.dirname)
        wrangler.write("#!/bin/sh\n")
        wrangler.chmod(0o755)
        result = Litestream::R2Configurator::Result
        responses = [
          result.new(stdout: "wrangler 4.30.0\n", stderr: "", success: true, exitstatus: 0),
          result.new(stdout: "2.31.0\n", stderr: "", success: true, exitstatus: 0),
          result.new(stdout: JSON.generate(loggedIn: true, authType: "OAuth Token", accounts: [{ id: "cf-account", name: "Cloudflare" }]), stderr: "", success: true, exitstatus: 0),
          result.new(stdout: "", stderr: "#{failure} failure", success: false, exitstatus: 1)
        ]
        runner = Class.new do
          attr_reader :calls

          define_method(:initialize) do |scripted|
            @scripted = scripted
            @calls = []
          end

          define_method(:capture) do |command, environment:, stdin_data:|
            @calls << { command:, environment:, stdin_data: }
            @scripted.fetch(@calls.length - 1)
          end
        end.new(responses)
        prompt = Class.new do
          def choose(choices, **options)
            options.fetch(:no_limit, false) ? choices : options.fetch(:selected).fetch(0)
          end

          def input(header:, value:)
            [header, value]
            value
          end
        end.new

        error = assert_raises(Litestream::R2Configurator::Error) do
          Litestream::R2Configurator.new(root:, prompt:, runner:, output: StringIO.new).run!
        end

        assert_includes error.message, "#{failure} failure"
        refute runner.calls.any? { |call| call.fetch(:command).include?("create") }
        refute_path_exists root.join(".kamal/secrets.production")
      end
    end
  ensure
    Object.send(:remove_const, :Litestream) if Object.const_defined?(:Litestream)
  end

  private

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
    builder_class.const_set(:VALUES, values)
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
