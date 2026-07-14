# frozen_string_literal: true

module RapidRailsTemplate
  class GeneratorOptions
    FIXED = %w[
      --database=sqlite3
      --asset-pipeline=propshaft
      --javascript=importmap
      --css=tailwind
      --skip-rubocop
      --skip-docker
      --skip-kamal
      --skip-thruster
      --skip-system-test
    ].freeze

    def self.build(configuration)
      options = FIXED.dup
      options.concat(%w[--skip-action-mailer --skip-action-mailbox]) if configuration["mail"] == "skip"
      options << "--skip-action-text" if configuration["action_text"] == "skip"
      options << "--skip-action-cable" if configuration["action_cable"] == "skip"
      options << "--skip-solid" # Solid components are installed individually from the confirmed plan.
      options.freeze
    end
  end
end
