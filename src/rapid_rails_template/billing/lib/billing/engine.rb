# frozen_string_literal: true

module Billing
  class Engine < ::Rails::Engine
    isolate_namespace Billing

    initializer "billing.migrations" do |app|
      app.config.paths["db/migrate"].concat(config.paths["db/migrate"].expanded)
    end
  end
end
