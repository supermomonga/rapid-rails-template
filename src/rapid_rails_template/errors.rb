# frozen_string_literal: true

module RapidRailsTemplate
  class Error < StandardError; end
  class InvalidConfiguration < Error; end
  class EnvironmentError < Error; end
  class PromptError < Error; end
end
