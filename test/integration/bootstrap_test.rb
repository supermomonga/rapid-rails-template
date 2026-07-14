# frozen_string_literal: true

require_relative "../test_helper"
require "open3"
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
      input = "\n" * 8 + "n\n"
      _stdout, stderr, status = Open3.capture3(RbConfig.ruby, File.join(ROOT, "bootstrap.rb"), destination, stdin_data: input)

      assert status.success?, stderr
      refute_path_exists destination
    end
  end
end
