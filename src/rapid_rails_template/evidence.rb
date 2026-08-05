# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"

module RapidRailsTemplate
  module Evidence
    VARIANTS = {
      "full-ja" => { "scenario_set" => "full", "additional_login_methods" => %w[siwe], "locale" => "ja", "image_delivery" => "imgproxy" }
    }.freeze
    PNG_SIGNATURE = "\x89PNG\r\n\x1A\n".b.freeze

    module_function

    def fingerprint(root)
      digest = Digest::SHA256.new
      fingerprint_paths(root).each do |path|
        relative = path.delete_prefix("#{root}/")
        digest << relative << "\0" << File.binread(path) << "\0"
      end
      digest.hexdigest
    end

    def fingerprint_paths(root)
      source_paths = Dir[File.join(root, "src/rapid_rails_template/**/*.rb")]
      (source_paths + [File.join(root, "bin/update-evidence")]).sort
    end

    def finalize_variant(directory:, scenario_set:, additional_login_methods:, locale:, image_delivery:, source_fingerprint:,
      base_commit:)
      report_path = File.join(directory, "captures.json")
      raise "撮影レポートがありません: #{report_path}" unless File.file?(report_path)

      report = JSON.parse(File.read(report_path))
      raise "scenario setが一致しません: #{report.fetch("scenario_set")}" unless report.fetch("scenario_set") == scenario_set
      unless report.fetch("additional_login_methods") == additional_login_methods
        raise "追加ログイン方法が一致しません: #{report.fetch("additional_login_methods").inspect}"
      end
      raise "localeが一致しません: #{report.fetch("locale")}" unless report.fetch("locale") == locale
      raise "画像配信方式が一致しません: #{report.fetch("image_delivery")}" unless report.fetch("image_delivery") == image_delivery

      captures = report.fetch("captures").map do |capture|
        path = capture.fetch("path")
        absolute_path = File.join(directory, path)
        raise "スクリーンショットがありません: #{absolute_path}" unless File.file?(absolute_path)

        width, height = png_dimensions(absolute_path)
        viewport = report.fetch("viewports").fetch(capture.fetch("viewport"))
        raise "スクリーンショット幅がviewportと一致しません: #{path}" unless width == viewport.fetch("width")
        raise "スクリーンショット高さがviewport未満です: #{path}" unless height >= viewport.fetch("height")

        capture.merge(
          "sha256" => Digest::SHA256.file(absolute_path).hexdigest,
          "pixel_width" => width,
          "pixel_height" => height
        )
      end

      validate_capture_set!(directory, captures)
      manifest = {
        "schema_version" => 5,
        "scenario_set" => scenario_set,
        "additional_login_methods" => additional_login_methods,
        "locale" => locale,
        "image_delivery" => image_delivery,
        "source_fingerprint" => source_fingerprint,
        "base_commit" => base_commit,
        "viewports" => report.fetch("viewports"),
        "captures" => captures
      }
      File.write(File.join(directory, "manifest.json"), JSON.pretty_generate(manifest) + "\n")
      File.write(File.join(directory, "README.md"), render_variant_readme(manifest))
      FileUtils.rm_f(report_path)
      manifest
    end

    def verify(root:, evidence_root: File.join(root, "docs/evidence"))
      expected_fingerprint = fingerprint(root)
      actual_variants = Dir.children(evidence_root).select do |entry|
        File.directory?(File.join(evidence_root, entry))
      end.sort
      unless actual_variants == VARIANTS.keys.sort
        raise "エビデンス構成が一致しません: #{actual_variants.inspect}"
      end

      manifests = VARIANTS.to_h do |variant, metadata|
        directory = File.join(evidence_root, variant)
        manifest_path = File.join(directory, "manifest.json")
        raise "manifestがありません: #{manifest_path}" unless File.file?(manifest_path)

        manifest = JSON.parse(File.read(manifest_path))
        raise "manifestのschema versionが一致しません: #{variant}" unless manifest.fetch("schema_version") == 5
        raise "manifestのscenario setが一致しません: #{variant}" unless manifest.fetch("scenario_set") == metadata.fetch("scenario_set")
        unless manifest.fetch("additional_login_methods") == metadata.fetch("additional_login_methods")
          raise "manifestの追加ログイン方法が一致しません: #{variant}"
        end
        raise "manifestのlocaleが一致しません: #{variant}" unless manifest.fetch("locale") == metadata.fetch("locale")
        raise "manifestの画像配信方式が一致しません: #{variant}" unless manifest.fetch("image_delivery") == metadata.fetch("image_delivery")
        unless manifest.fetch("source_fingerprint") == expected_fingerprint
          raise "#{variant}のエビデンスが古くなっています。rake evidence:updateを実行してください"
        end

        captures = manifest.fetch("captures")
        validate_capture_set!(directory, captures)
        captures.each do |capture|
          path = File.join(directory, capture.fetch("path"))
          raise "スクリーンショットがありません: #{path}" unless File.file?(path)
          raise "スクリーンショットが変更されています: #{path}" unless Digest::SHA256.file(path).hexdigest == capture.fetch("sha256")

          width, height = png_dimensions(path)
          raise "スクリーンショット寸法がmanifestと一致しません: #{path}" unless [width, height] == capture.values_at("pixel_width", "pixel_height")
        end

        readme_path = File.join(directory, "README.md")
        raise "READMEがありません: #{readme_path}" unless File.file?(readme_path)
        actual_readme = File.binread(readme_path)
        expected_readme = render_variant_readme(manifest)
        unless actual_readme == expected_readme.b
          raise "READMEがmanifestと一致しません: #{readme_path} " \
            "(actual=#{Digest::SHA256.hexdigest(actual_readme)}, expected=#{Digest::SHA256.hexdigest(expected_readme)})"
        end

        [variant, manifest]
      end

      index_path = File.join(evidence_root, "README.md")
      raise "エビデンス索引がありません: #{index_path}" unless File.file?(index_path)
      raise "エビデンス索引が古くなっています: #{index_path}" unless File.binread(index_path) == render_index(manifests).b

      true
    end

    def write_index(directory, manifests)
      File.write(File.join(directory, "README.md"), render_index(manifests))
    end

    def render_variant_readme(manifest)
      scenario_set = manifest.fetch("scenario_set")
      additional_login_methods = manifest.fetch("additional_login_methods")
      locale = manifest.fetch("locale")
      image_delivery = manifest.fetch("image_delivery")
      title = "#{scenario_set} / #{locale} / #{image_delivery}"
      lines = [
        "# #{title} エビデンス",
        "",
        "- Source fingerprint: `#{manifest.fetch("source_fingerprint")}`",
        "- Base commit: `#{manifest.fetch("base_commit")}`",
        "- Locale: `#{locale}`",
        "- Image delivery: `#{image_delivery}`",
        "- Additional login methods: `#{additional_login_methods.empty? ? '(none)' : additional_login_methods.join(', ')}`",
        "- 更新: `rake evidence:update`",
        ""
      ]
      manifest.fetch("captures").group_by { |capture| capture.fetch("title") }.each do |capture_title, captures|
        lines << "## #{capture_title}"
        lines << ""
        captures.each do |capture|
          viewport = capture.fetch("viewport")
          lines << "### #{viewport.capitalize}"
          lines << ""
          lines << "![#{capture_title} (#{viewport})](#{capture.fetch("path")})"
          lines << ""
        end
      end
      lines.join("\n")
    end

    def render_index(manifests)
      fingerprint = manifests.fetch(VARIANTS.keys.first).fetch("source_fingerprint")
      <<~MARKDOWN
        # UIエビデンス

        選択可能な機能をすべて有効化した日本語sampleを、CapybaraとPlaywrightで一括検証したエビデンスです。

        - [Full / ja](full-ja/README.md)
        - Source fingerprint: `#{fingerprint}`
        - 更新: `rake evidence:update`
        - 検証: `rake evidence:verify`
      MARKDOWN
    end

    def validate_capture_set!(directory, captures)
      raise "撮影結果が空です: #{directory}" if captures.empty?

      paths = captures.map { |capture| capture.fetch("path") }
      raise "スクリーンショット名が重複しています: #{directory}" unless paths.uniq == paths
      capture_keys = captures.map { |capture| capture.values_at("id", "viewport") }
      unless capture_keys.uniq == capture_keys
        raise "capture IDとviewportの組み合わせが重複しています: #{directory}"
      end
      expected_paths = paths.sort
      actual_paths = Dir[File.join(directory, "*.png")].map { |path| File.basename(path) }.sort
      raise "スクリーンショット一覧がmanifestと一致しません: #{directory}" unless actual_paths == expected_paths
    end

    def png_dimensions(path)
      header = File.binread(path, 24)
      raise "PNG形式ではありません: #{path}" unless header.start_with?(PNG_SIGNATURE) && header.byteslice(12, 4) == "IHDR"

      header.byteslice(16, 8).unpack("NN")
    end
  end
end
