# frozen_string_literal: true

module Billing
  class Current < ActiveSupport::CurrentAttributes
    attribute :actor, :authorization_actor
  end
end
