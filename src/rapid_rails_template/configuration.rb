# frozen_string_literal: true

module RapidRailsTemplate
  class Configuration
    ADDITIONAL_LOGIN_METHODS = %w[siwe].freeze
    PROFILE_FEATURES = %w[screen_name display_name avatar].freeze
    MULTIPLE_VALUE_OPTIONS = %w[additional_login_methods profile_features].freeze

    VALID_VALUES = {
      "pwa" => %w[use skip],
      "web_push" => %w[use skip],
      "active_job" => %w[solid_queue skip],
      "job_operations" => %w[enable disable],
      "maintenance_tasks" => %w[enable disable],
      "solid_cache" => %w[use skip],
      "additional_login_methods" => ADDITIONAL_LOGIN_METHODS,
      "profile_features" => PROFILE_FEATURES,
      "api" => %w[enable disable],
      "action_cable" => %w[solid_cable skip],
      "mail" => %w[auto use skip],
      "deployment" => %w[dokploy none],
      "default_locale" => %w[ja en]
    }.freeze

    DEFAULTS = {
      "pwa" => "skip",
      "web_push" => "skip",
      "active_job" => "skip",
      "job_operations" => "disable",
      "maintenance_tasks" => "disable",
      "solid_cache" => "use",
      "additional_login_methods" => [].freeze,
      "profile_features" => PROFILE_FEATURES,
      "api" => "enable",
      "action_cable" => "skip",
      "mail" => "auto",
      "deployment" => "dokploy",
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
      validate_explicit_dependencies!(provided_answers)
      resolved_defaults = DEFAULTS.dup
      if !provided_answers.key?("maintenance_tasks") &&
          (provided_answers["web_push"] == "use" || provided_answers["active_job"] == "solid_queue")
        resolved_defaults["maintenance_tasks"] = "enable"
      end
      if !provided_answers.key?("job_operations") &&
          (provided_answers["web_push"] == "use" || provided_answers["active_job"] == "solid_queue")
        resolved_defaults["job_operations"] = "enable"
      end
      @answers = resolved_defaults.merge(provided_answers).transform_values do |value|
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

      if @values["web_push"] == "use"
        @values["active_job"] = "solid_queue"
        @reasons["active_job"] = "Web Pushの非同期送信に必要なため"
      end

      unless @values["active_job"] == "solid_queue"
        @values["job_operations"] = "disable"
        @reasons["job_operations"] = "Solid Queueを使用しないため"
        @values["maintenance_tasks"] = "disable"
        @reasons["maintenance_tasks"] = "Solid Queueを使用しないため"
      end

      return unless @values["mail"] == "auto"

      @values["mail"] = "skip"
      @reasons["mail"] = "自動的にメールを必要とする機能がないため"
    end

    def validate_explicit_dependencies!(provided_answers)
      if provided_answers["pwa"] == "skip" && provided_answers["web_push"] == "use"
        raise InvalidConfiguration, "PWA無効時にWeb Pushは使用できません"
      end

      if provided_answers["web_push"] == "use" && provided_answers["active_job"] == "skip"
        raise InvalidConfiguration, "Web Push使用時にActive Jobを無効化できません"
      end
      if provided_answers["job_operations"] == "enable" &&
          provided_answers["web_push"] != "use" && provided_answers["active_job"] != "solid_queue"
        raise InvalidConfiguration, "ジョブ運用画面使用時はSolid Queueが必要です"
      end
      return unless provided_answers["maintenance_tasks"] == "enable"
      return if provided_answers["web_push"] == "use" || provided_answers["active_job"] == "solid_queue"

      raise InvalidConfiguration, "Maintenance Tasks使用時はSolid Queueが必要です"
    end
  end
end
