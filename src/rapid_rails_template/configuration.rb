# frozen_string_literal: true

module RapidRailsTemplate
  class Configuration
    PROFILE_FEATURES = %w[screen_name display_name avatar].freeze

    VALID_VALUES = {
      "pwa" => %w[use skip],
      "web_push" => %w[use skip],
      "active_job" => %w[solid_queue skip],
      "solid_cache" => %w[use skip],
      "account_authentication" => %w[devise wallet_siwe],
      "profile_features" => PROFILE_FEATURES,
      "api" => %w[enable disable],
      "action_cable" => %w[solid_cable skip],
      "mail" => %w[auto use skip],
      "deployment" => %w[dokploy none]
    }.freeze

    DEFAULTS = {
      "pwa" => "skip",
      "web_push" => "skip",
      "active_job" => "skip",
      "solid_cache" => "use",
      "account_authentication" => "devise",
      "profile_features" => PROFILE_FEATURES,
      "api" => "enable",
      "action_cable" => "skip",
      "mail" => "auto",
      "deployment" => "dokploy"
    }.freeze

    attr_reader :answers, :values, :reasons

    def self.build(answers)
      new(answers).tap(&:validate!)
    end

    def initialize(answers)
      @answers = DEFAULTS.merge(answers.transform_keys(&:to_s)).transform_values do |value|
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
        if key == "profile_features"
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

      @values["mail"] = @values["account_authentication"] == "devise" ? "use" : "skip"
      @reasons["mail"] = "認証方式が#{@values['account_authentication']}のため"
    end
  end
end
