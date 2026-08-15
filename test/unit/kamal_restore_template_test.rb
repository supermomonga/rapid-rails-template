# frozen_string_literal: true

require_relative "../test_helper"
require "fileutils"
require "erb"
require "open3"
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
    attr_reader :commands

    def initialize(fail_when: nil)
      @commands = []
      @fail_when = fail_when
    end

    def run!(*arguments)
      @commands << arguments
      raise KamalRestore::Error, "expected failure" if @fail_when&.call(arguments)

      ""
    end

    def ignore_failure(*arguments)
      @commands << arguments
      ""
    end
  end

  def setup
    @databases = [
      { "name" => "primary", "path" => "/rails/storage/production.sqlite3", "replica_env" => "LITESTREAM_REPLICA_URL" },
      { "name" => "storage", "path" => "/rails/storage/production_storage.sqlite3", "replica_env" => "LITESTREAM_STORAGE_REPLICA_URL" },
      { "name" => "queue", "path" => "/rails/storage/production_queue.sqlite3", "replica_env" => "LITESTREAM_QUEUE_REPLICA_URL" }
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
  end

  def test_plan_only_uses_litestream_dry_run_without_mutating_kamal
    runner = FakeRunner.new

    status = KamalRestore::CLI.new(
      ["--plan"],
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
  end

  def test_plan_normalizes_rfc3339_timestamp
    runner = FakeRunner.new

    status = KamalRestore::CLI.new(
      ["--plan", "--timestamp=2026-08-16T09:00:00+09:00"],
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
      [],
      input: TTYIO.new("RESTORE sample latest\n"),
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
      [],
      input: StringIO.new("RESTORE sample latest\n"),
      output: StringIO.new,
      error: StringIO.new,
      runner: non_tty_runner
    ).run

    assert_equal 1, non_tty_status
    refute non_tty_runner.commands.any? { |command| command.first(2) == %w[server exec] }

    mismatch_runner = FakeRunner.new
    mismatch_status = KamalRestore::CLI.new(
      [],
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
      ["--yes"],
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
      ["--rollback=#{operation_id}"],
      input: TTYIO.new("ROLLBACK sample #{operation_id}\n"),
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
      [],
      input: TTYIO.new("RESTORE sample latest\n"),
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
    assert runner.commands.any? { |command| command.last == "rm -f .kamal/sample-restore-in-progress" }
  end

  def test_failure_before_install_restarts_original_services_without_install
    runner = FakeRunner.new(fail_when: ->(command) { command.include?("-integrity-check") })

    status = KamalRestore::CLI.new(
      [],
      input: TTYIO.new("RESTORE sample latest\n"),
      output: TTYIO.new,
      error: StringIO.new,
      runner:
    ).run

    assert_equal 1, status
    refute runner.commands.any? { |command| command.include?("install") }
    assert runner.commands.any? { |command| command == %w[accessory start litestream] }
    assert runner.commands.any? { |command| command == %w[app start -r web] }
    assert runner.commands.any? { |command| command.last == "rm -f .kamal/sample-restore-in-progress" }
  end

  def test_lock_conflict_aborts_before_application_stop
    runner = FakeRunner.new(fail_when: lambda do |command|
      command.first(2) == %w[lock acquire]
    end)

    status = KamalRestore::CLI.new(
      [],
      input: TTYIO.new("RESTORE sample latest\n"),
      output: TTYIO.new,
      error: StringIO.new,
      runner:
    ).run

    assert_equal 1, status
    refute runner.commands.any? { |command| command == %w[app stop] }
    assert runner.commands.any? { |command| command.last == "rm -f .kamal/sample-restore-in-progress" }
  end

  def test_install_failure_keeps_services_stopped_and_marker_present
    runner = FakeRunner.new(fail_when: lambda do |command|
      command.include?("bin/kamal-restore-volume") && command.include?("install")
    end)

    status = KamalRestore::CLI.new(
      [],
      input: TTYIO.new("RESTORE sample latest\n"),
      output: TTYIO.new,
      error: StringIO.new,
      runner:
    ).run

    assert_equal 1, status
    assert runner.commands.any? { |command| command == %w[app stop] }
    assert runner.commands.any? { |command| command == %w[accessory stop litestream] }
    refute runner.commands.any? { |command| command == %w[app start -r web] }
    refute runner.commands.any? { |command| command.last == "rm -f .kamal/sample-restore-in-progress" }
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
    original_environment = %w[KAMAL_DEPLOY_HOST KAMAL_PROXY_HOST AWS_REGION].to_h { |name| [name, ENV[name]] }
    ENV.update(
      "KAMAL_DEPLOY_HOST" => "192.0.2.10",
      "KAMAL_PROXY_HOST" => "app.example.com",
      "AWS_REGION" => "ap-northeast-1"
    )
    deploy = YAML.safe_load(ERB.new(files.fetch("config/deploy.yml")).result, aliases: true)
    litestream = YAML.safe_load(files.fetch("config/litestream.yml"), aliases: true)

    assert_equal "sample", deploy.fetch("service")
    assert_equal "2.11.0", deploy.fetch("minimum_version")
    assert_equal "web", deploy.fetch("primary_role")
    assert_equal "amd64", deploy.dig("builder", "arch")
    assert_equal ["192.0.2.10"], deploy.dig("servers", "web")
    assert_equal "bin/jobs --mode async", deploy.dig("servers", "worker", "cmd")
    assert_equal "litestream/litestream:0.5.15", deploy.dig("accessories", "litestream", "image")
    assert_equal ["sample_storage:/rails/storage"], deploy.dig("accessories", "litestream", "volumes")
    assert_equal "1000:1000", deploy.dig("accessories", "litestream", "options", "user")
    assert_equal %w[primary storage queue cable], litestream.fetch("dbs").map { |database| File.basename(database.fetch("path")).sub(/\Aproduction_?/, "").sub(".sqlite3", "").then { |name| name.empty? ? "primary" : name } }
    assert litestream.fetch("dbs").all? { |database| database.fetch("restore-if-db-not-exists") }
    refute files.fetch("config/litestream.yml").include?("production_cache.sqlite3")
    assert_includes files.fetch(".kamal/secrets"), "LITESTREAM_CABLE_REPLICA_URL=${LITESTREAM_CABLE_REPLICA_URL:?LITESTREAM_CABLE_REPLICA_URL is required}"

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
    builder.define_singleton_method(:chmod) { |_path, _mode| nil }
    builder.send(:configure_kamal)
    files
  end

  def run_helper!(script, *arguments)
    _stdout, stderr, status = Open3.capture3(RbConfig.ruby, script, *arguments)
    assert status.success?, stderr
  end
end
