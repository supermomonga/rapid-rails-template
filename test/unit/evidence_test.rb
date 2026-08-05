# frozen_string_literal: true

require_relative "../test_helper"
require "tmpdir"
require_relative "../../src/rapid_rails_template/evidence"

class EvidenceTest < Minitest::Test
  def test_verifies_fingerprint_images_and_generated_markdown
    with_evidence_repository do |root|
      assert RapidRailsTemplate::Evidence.verify(root: root)
    end
  end

  def test_rejects_stale_source_fingerprint
    with_evidence_repository do |root|
      File.write(File.join(root, "src/rapid_rails_template/template.rb"), "changed\n")

      error = assert_raises(RuntimeError) { RapidRailsTemplate::Evidence.verify(root: root) }

      assert_includes error.message, "エビデンスが古くなっています"
    end
  end

  def test_rejects_changed_or_extra_screenshots
    with_evidence_repository do |root|
      screenshot = File.join(root, "docs/evidence/full-ja/home--desktop.png")
      File.binwrite(screenshot, fake_png(1400, 901))

      error = assert_raises(RuntimeError) { RapidRailsTemplate::Evidence.verify(root: root) }
      assert_includes error.message, "スクリーンショットが変更されています"
    end

    with_evidence_repository do |root|
      File.binwrite(File.join(root, "docs/evidence/full-ja/extra.png"), fake_png(1400, 900))

      error = assert_raises(RuntimeError) { RapidRailsTemplate::Evidence.verify(root: root) }
      assert_includes error.message, "スクリーンショット一覧がmanifestと一致しません"
    end
  end

  def test_rejects_readme_that_does_not_match_manifest
    with_evidence_repository do |root|
      File.write(File.join(root, "docs/evidence/full-ja/README.md"), "stale\n")

      error = assert_raises(RuntimeError) { RapidRailsTemplate::Evidence.verify(root: root) }

      assert_includes error.message, "READMEがmanifestと一致しません"
    end
  end

  def test_rejects_duplicate_capture_id_and_viewport
    Dir.mktmpdir do |directory|
      File.binwrite(File.join(directory, "first.png"), fake_png(1400, 900))
      File.binwrite(File.join(directory, "second.png"), fake_png(1400, 900))
      captures = [
        { "id" => "home", "viewport" => "desktop", "path" => "first.png" },
        { "id" => "home", "viewport" => "desktop", "path" => "second.png" }
      ]

      error = assert_raises(RuntimeError) do
        RapidRailsTemplate::Evidence.validate_capture_set!(directory, captures)
      end

      assert_includes error.message, "capture IDとviewportの組み合わせが重複しています"
    end
  end

  def test_rejects_unexpected_evidence_variant
    with_evidence_repository do |root|
      FileUtils.mkdir_p(File.join(root, "docs/evidence/legacy"))

      error = assert_raises(RuntimeError) { RapidRailsTemplate::Evidence.verify(root: root) }

      assert_includes error.message, "エビデンス構成が一致しません"
    end
  end

  private
    def with_evidence_repository
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "src/rapid_rails_template"))
        FileUtils.mkdir_p(File.join(root, "bin"))
        File.write(File.join(root, "src/rapid_rails_template/template.rb"), "template\n")
        File.write(File.join(root, "bin/update-evidence"), "update\n")
        fingerprint = RapidRailsTemplate::Evidence.fingerprint(root)
        manifests = RapidRailsTemplate::Evidence::VARIANTS.to_h do |variant, metadata|
          directory = File.join(root, "docs/evidence", variant)
          FileUtils.mkdir_p(directory)
          File.binwrite(File.join(directory, "home--desktop.png"), fake_png(1400, 900))
          File.write(
            File.join(directory, "captures.json"),
            JSON.pretty_generate(
              "scenario_set" => metadata.fetch("scenario_set"),
              "additional_login_methods" => metadata.fetch("additional_login_methods"),
              "locale" => metadata.fetch("locale"),
              "image_delivery" => metadata.fetch("image_delivery"),
              "viewports" => { "desktop" => { "width" => 1400, "height" => 900 } },
              "captures" => [
                {
                  "id" => "#{metadata.fetch("scenario_set")}-home",
                  "title" => "ホーム",
                  "viewport" => "desktop",
                  "path" => "home--desktop.png"
                }
              ]
            )
          )
          manifest = RapidRailsTemplate::Evidence.finalize_variant(
            directory: directory,
            scenario_set: metadata.fetch("scenario_set"),
            additional_login_methods: metadata.fetch("additional_login_methods"),
            locale: metadata.fetch("locale"),
            image_delivery: metadata.fetch("image_delivery"),
            source_fingerprint: fingerprint,
            base_commit: "abc123"
          )
          [variant, manifest]
        end
        RapidRailsTemplate::Evidence.write_index(File.join(root, "docs/evidence"), manifests)
        yield root
      end
    end

    def fake_png(width, height)
      RapidRailsTemplate::Evidence::PNG_SIGNATURE + "\0\0\0\rIHDR" + [width, height].pack("NN")
    end
end
