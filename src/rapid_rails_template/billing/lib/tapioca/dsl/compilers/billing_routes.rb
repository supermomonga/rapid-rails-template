# frozen_string_literal: true

module Tapioca
  module Dsl
    module Compilers
      # The upstream UrlHelpers compiler reads only Rails.application.routes.
      # Generate these engine helpers from the same route set used at runtime.
      class BillingRoutes < Compiler
        ConstantType = type_member { { fixed: T.class_of(::ActionController::Base) } }

        def self.gather_constants
          [::Billing::ApplicationController, ::Billing::Admin::BaseController]
        end

        def decorate
          root.create_path(constant) do |scope|
            ::Billing::Engine.routes.named_routes.helper_names.sort.each do |name|
              scope.create_method(name, parameters: [create_rest_param("args", type: "T.untyped")], return_type: "String")
            end
          end
        end
      end
    end
  end
end
