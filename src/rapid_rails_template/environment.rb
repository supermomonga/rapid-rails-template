# frozen_string_literal: true

require "rubygems"

module RapidRailsTemplate
  class Environment
    RUBY_RANGE = Gem::Requirement.new(">= 4.0", "< 4.1")
    RAILS_RANGE = Gem::Requirement.new(">= 8.1", "< 8.2")
    GUM_VERSION = Gem::Version.new("0.3.2")

    def self.validate!
      ruby_version = Gem::Version.new(RUBY_VERSION)
      raise EnvironmentError, "Ruby #{RUBY_VERSION}は対象外です（4.0.xが必要）" unless RUBY_RANGE.satisfied_by?(ruby_version)

      rails_spec = Gem::Specification.find_all_by_name("rails").select { |spec| RAILS_RANGE.satisfied_by?(spec.version) }.max_by(&:version)
      raise EnvironmentError, "Rails 8.1.xがインストールされていません" if rails_spec.nil?

      load_gum!
      rails_spec
    end

    def self.gum
      Object.const_get(:Gum)
    end

    def self.load_gum!
      gum_spec = Gem::Specification.find_all_by_name("gum").find { |spec| spec.version == GUM_VERSION }
      raise EnvironmentError, "gum #{GUM_VERSION}がインストールされていません（gem install gum -v #{GUM_VERSION}を実行してください）" if gum_spec.nil?

      begin
        gum_spec.activate
        require "gum"
      rescue Gem::LoadError, LoadError => e
        raise EnvironmentError, "gum #{GUM_VERSION}を読み込めません: #{e.message}"
      end

      begin
        Gum.executable
      rescue Gum::Error => e
        raise EnvironmentError, "Gum実行可能ファイルを利用できません: #{e.message}"
      end
    end
    private_class_method :load_gum!
  end
end
