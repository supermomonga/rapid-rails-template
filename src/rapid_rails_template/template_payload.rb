# frozen_string_literal: true

require "base64"

module RapidRailsTemplate
  module TemplatePayload
    def self.build(source_root)
      files = Dir[File.join(source_root, "billing/**/*")].select { |path| File.file?(path) }.sort.to_h do |path|
        [path.delete_prefix(File.join(source_root, "billing/")), Base64.strict_encode64(File.binread(path))]
      end
      [
        "require \"base64\"",
        "BILLING_FILES = #{files.inspect}.freeze",
        File.binread(File.join(source_root, "billing_template.rb")),
        File.binread(File.join(source_root, "rails_template.rb"))
      ].join("\n")
    end
  end
end
