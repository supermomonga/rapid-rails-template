# frozen_string_literal: true

module Billing
  class MerchantsController < ApplicationController
    def index
      @pagy, @merchants = pagy(:offset, MerchantAccount.where(status: 'active').order(:id))
    end

    def show
      @merchant = MerchantAccount.find_by!(public_id: params.expect(:public_id))
      @pagy, @plans = pagy(:offset, @merchant.plans.where(accepting_subscriptions: true).order(:id))
    end
  end
end
