# frozen_string_literal: true

module Billing
  class PlansController < ApplicationController
    def index
      @pagy, @plans = pagy(:offset, Plan.where(accepting_subscriptions: true).includes(:merchant_profile).order(:id))
    end

    def show
      @plan = Plan.find(params.expect(:id))
    end
  end
end
