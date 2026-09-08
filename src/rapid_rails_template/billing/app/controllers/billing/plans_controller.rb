# frozen_string_literal: true

module Billing
  class PlansController < ApplicationController
    def index
      @pagy, @plans = pagy(:offset, Plan.joins(:merchant_account).where(accepting_subscriptions: true, billing_merchant_accounts: { status: 'active' }).includes(:merchant_account).order(:id))
    end

    def show
      @plan = Plan.find(params.expect(:id))
    end
  end
end
