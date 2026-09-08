# frozen_string_literal: true

module Billing
  module ConfigurationStatus
    SECRET_NAMES = ["BILLING_EXECUTION_PRIVATE_KEY", *Chains::ALL.values.map(&:rpc_env)].freeze

    def self.missing(env: ENV)
      names = SECRET_NAMES.select { |name| env[name].blank? }
      Chains::ALL.each_key do |id|
        setting = ChainSetting.for_chain(id)
        %i[treasury_address gas_ceiling_wei collector_address executor_address verified_at].each do |attribute|
          names << "#{Chains.fetch(id).name}: #{attribute}" if setting.public_send(attribute).blank?
        end
      end
      names
    end
  end
end
