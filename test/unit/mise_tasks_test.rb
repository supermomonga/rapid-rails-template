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
      --api=enable
      --action-cable=solid_cable
      --mail=use
      --deployment=dokploy
      --default-locale=ja
    ].each { |option| assert_includes task, %Q("#{option}") }

    assert_includes task, "generated = system RbConfig.ruby"
    assert_includes task, 'abort "sampleアプリの生成に失敗しました" unless generated'
    assert_includes task, 'sample_template = File.join(root, "bin/sample-app-template")'
    assert_includes task, 'sample_template_runner = File.join(root, "bin/apply-sample-app-template")'
    assert_includes task, 'exec({ "BUNDLE_GEMFILE" => File.join(sample, "Gemfile") },'
    assert_includes task, '"bundle", "exec", RbConfig.ruby, sample_template_runner, sample, sample_template'

    bootstrap_index = task.index("generated = system").then { |index| refute_nil(index); index }
    template_index = task.index('exec({ "BUNDLE_GEMFILE"').then do |index|
      refute_nil index
      index
    end
    assert_operator bootstrap_index, :<, template_index
  end
end
