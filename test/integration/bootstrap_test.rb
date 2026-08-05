# frozen_string_literal: true

require_relative "../test_helper"
require "open3"
require "pty"
require "tmpdir"

class BootstrapTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  def test_generated_bootstrap_is_valid_ruby
    system(File.join(ROOT, "bin", "build-bootstrap"), out: File::NULL)
    _stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-c", File.join(ROOT, "bootstrap.rb"))

    assert status.success?, stderr
  end

  def test_rejected_confirmation_does_not_create_destination
    system(File.join(ROOT, "bin", "build-bootstrap"), out: File::NULL)
    Dir.mktmpdir do |directory|
      destination = File.join(directory, "path with spaces & metacharacters")
      gum_directory = File.join(directory, "gum")
      Dir.mkdir(gum_directory)
      gum_executable = File.join(gum_directory, "gum")
      File.write(gum_executable, <<~RUBY)
        #!/usr/bin/env ruby
        command = ARGV.shift
        if command == "choose"
          selected = ARGV.find { |argument| argument.start_with?("--selected=") }
          puts selected.split("=", 2).fetch(1) if selected
        elsif command == "confirm"
          exit 1
        else
          abort "unexpected Gum command: \#{command}"
        end
      RUBY
      File.chmod(0o755, gum_executable)

      output = +""
      status = nil
      PTY.spawn(
        { "GUM_INSTALL_DIR" => gum_directory },
        RbConfig.ruby,
        File.join(ROOT, "bootstrap.rb"),
        "--app-id=generated_app",
        "--app-name=Generated App",
        "--default-locale=ja",
        destination
      ) do |reader, writer, child_pid|
        writer.close
        begin
          loop { output << reader.readpartial(4096) }
        rescue EOFError, Errno::EIO
          nil
        end
        _pid, status = Process.wait2(child_pid)
      end

      assert status.success?, output
      refute_path_exists destination
    end
  end
end
