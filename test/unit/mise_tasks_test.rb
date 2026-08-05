# frozen_string_literal: true

require_relative "../test_helper"

class MiseTasksTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  def test_sample_generation_uses_one_all_features_task
    source = File.read(File.join(ROOT, "mise.toml"))
    task = source.split("[tasks.generate-sampleapp]", 2).fetch(1)

    assert_equal 1, source.scan(/^\[tasks\.generate-sampleapp\]$/).length
    refute_includes source, "[tasks.generate-sampleapp-siwe]"
    %w[
      --pwa=use
      --web-push=use
      --active-job=solid_queue
      --job-operations=enable
      --maintenance-tasks=enable
      --solid-cache=use
      --additional-login-methods=siwe
      --profile-features=screen_name,display_name,avatar
      --image-delivery=imgproxy
      --api=enable
      --action-cable=solid_cable
      --mail=use
      --deployment=dokploy
      --default-locale=ja
    ].each { |option| assert_includes task, %Q("#{option}") }

    %w[IMGPROXY_ENDPOINT IMGPROXY_KEY IMGPROXY_SALT IMGPROXY_SOURCE_ORIGIN].each do |name|
      assert_includes task, %Q("#{name}" =>)
    end
    assert_includes task, "exec imgproxy_environment, RbConfig.ruby"
  end
end
