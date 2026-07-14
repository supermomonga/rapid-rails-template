# frozen_string_literal: true

require "rubygems"

module RapidRailsTemplate
  class Environment
    RUBY_RANGE = Gem::Requirement.new(">= 4.0", "< 4.1")
    RAILS_RANGE = Gem::Requirement.new(">= 8.1", "< 8.2")

    def self.validate!
      ruby_version = Gem::Version.new(RUBY_VERSION)
      raise EnvironmentError, "Ruby #{RUBY_VERSION}は対象外です（4.0.xが必要）" unless RUBY_RANGE.satisfied_by?(ruby_version)

      rails_spec = Gem::Specification.find_all_by_name("rails").select { |spec| RAILS_RANGE.satisfied_by?(spec.version) }.max_by(&:version)
      raise EnvironmentError, "Rails 8.1.xがインストールされていません" if rails_spec.nil?

      rails_spec
    end
  end
end
