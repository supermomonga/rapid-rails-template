# frozen_string_literal: true

module Billing
  class Engine < ::Rails::Engine
    isolate_namespace Billing

    initializer "billing.migrations" do |app|
      app.config.paths["db/migrate"].concat(config.paths["db/migrate"].expanded)
    end

    initializer "billing.importmap", before: "importmap" do |app|
      app.config.importmap.cache_sweepers << root.join("app/assets/javascripts")
    end
  end
end
