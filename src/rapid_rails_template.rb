# frozen_string_literal: true

require_relative "rapid_rails_template/errors"
require_relative "rapid_rails_template/environment"
require_relative "rapid_rails_template/configuration"
require_relative "rapid_rails_template/questionnaire"
require_relative "rapid_rails_template/generator_options"
require_relative "rapid_rails_template/execution_plan"
require_relative "rapid_rails_template/runner"
require_relative "rapid_rails_template/template_payload"

module RapidRailsTemplate
  APPLICATION_TEMPLATE = TemplatePayload.build(File.expand_path("rapid_rails_template", __dir__)).freeze
end

require_relative "rapid_rails_template/entrypoint"
