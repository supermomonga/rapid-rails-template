# frozen_string_literal: true

require "billing/engine"
require "sorbet-runtime"
require "eth"

module Billing
  class Error < StandardError; end
  class ConfigurationError < Error; end
  class RpcError < Error; end
  class GasLimitExceeded < Error; end
  class VerificationError < Error; end
end
