# frozen_string_literal: true

module Billing
  module Account
    class BaseController < Billing::ApplicationController
      layout "account"
      before_action :authenticate_user!

      private
        def merchant_profile
          @merchant_profile ||= MerchantProfile.find_by!(user_id: T.must(current_user).id)
        end
    end
  end
end
