# frozen_string_literal: true

module RapidRailsTemplate
  class Configuration
    ADDITIONAL_LOGIN_METHODS = %w[siwe].freeze
    MULTIPLE_VALUE_OPTIONS = %w[additional_login_methods].freeze

    VALID_VALUES = {
      "pwa" => %w[use skip],
      "web_push" => %w[use skip],
      "job_operations" => %w[enable disable],
      "maintenance_tasks" => %w[enable disable],
      "solid_cache" => %w[use skip],
      "additional_login_methods" => ADDITIONAL_LOGIN_METHODS,
      "api" => %w[enable disable],
      "action_cable" => %w[solid_cable skip],
      "mail" => %w[auto use skip],
      "default_locale" => %w[ja en]
    }.freeze

    DEFAULTS = {
      "pwa" => "use",
      "web_push" => "use",
      "job_operations" => "enable",
      "maintenance_tasks" => "enable",
      "solid_cache" => "use",
      "additional_login_methods" => ADDITIONAL_LOGIN_METHODS,
      "api" => "enable",
      "action_cable" => "solid_cable",
      "mail" => "auto",
      "default_locale" => "ja"
    }.freeze

    attr_reader :answers, :values, :reasons

    def self.build(answers)
      new(answers).tap(&:validate!)
    end

    def self.multiple_value_option?(key)
      MULTIPLE_VALUE_OPTIONS.include?(key.to_s)
    end

    def initialize(answers)
      provided_answers = answers.transform_keys(&:to_s)
      unknown_keys = provided_answers.keys - VALID_VALUES.keys
      raise InvalidConfiguration, "不明な設定です: #{unknown_keys.join(', ')}" if unknown_keys.any?

      validate_explicit_dependencies!(provided_answers)
      @answers = DEFAULTS.merge(provided_answers).transform_values do |value|
        value.is_a?(Array) ? value.dup.freeze : value
      end.freeze
      @values = @answers.dup
      @reasons = {}
      normalize!
      @values.freeze
      @reasons.freeze
      freeze
    end

    def [](key)
      values.fetch(key.to_s)
    end

    def to_h
      { "answers" => answers, "values" => values, "reasons" => reasons }
    end

    def validate!
      VALID_VALUES.each do |key, allowed|
        value = answers[key]
        raise InvalidConfiguration, "#{key}が未回答です" if value.nil?
        if self.class.multiple_value_option?(key)
          valid = value.is_a?(Array) && value.uniq == value && (value - allowed).empty?
          raise InvalidConfiguration, "#{key}の値が不正です: #{value.inspect}" unless valid
        else
          raise InvalidConfiguration, "#{key}の値が不正です: #{value}" unless allowed.include?(value)
        end
      end
      raise InvalidConfiguration, "PWA無効時にWeb Pushは使用できません" if self["pwa"] == "skip" && self["web_push"] == "use"

      self
    end

    private

    def normalize!
      if @values["pwa"] == "skip"
        @values["web_push"] = "skip"
        @reasons["web_push"] = "PWAを使用しないため"
      end

      return unless @values["mail"] == "auto"

      @values["mail"] = "skip"
      @reasons["mail"] = "自動的にメールを必要とする機能がないため"
    end

    def validate_explicit_dependencies!(provided_answers)
      if provided_answers["pwa"] == "skip" && provided_answers["web_push"] == "use"
        raise InvalidConfiguration, "PWA無効時にWeb Pushは使用できません"
      end
    end
  end
end
