# frozen_string_literal: true

module Billing
  class MerchantsController < ApplicationController
    def index
      @pagy, @merchants = pagy(:offset, MerchantProfile.where.not(user_id: nil).order(:id))
    end

    def show
      @merchant = MerchantProfile.where.not(user_id: nil).find_by!(public_id: params.expect(:public_id))
      @pagy, @plans = pagy(:offset, @merchant.plans.where(accepting_subscriptions: true).order(:id))
    end
  end
end
