# frozen_string_literal: true

module Billing
  module Account
    class BaseController < Billing::ApplicationController
      layout "account"
      before_action :authenticate_user!
    end
  end
end
