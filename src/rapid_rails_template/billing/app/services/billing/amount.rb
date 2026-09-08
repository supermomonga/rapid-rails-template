# frozen_string_literal: true

module Billing
  module Amount
    def self.parse(value, decimals: 6)
      text = value.to_s
      raise ArgumentError, "invalid amount" unless text.match?(/\A\d+(?:\.\d{1,#{decimals}})?\z/)

      whole, fraction = text.split(".", 2)
      whole.to_i * 10**decimals + fraction.to_s.ljust(decimals, "0").to_i
    end

    def self.format(units, decimals: 6)
      whole, fraction = Integer(units).divmod(Integer(10**decimals))
      "#{whole}.#{fraction.to_s.rjust(decimals, '0')}"
    end

    def self.split(units, basis_points)
      raise ArgumentError, "invalid fee" unless (0..10_000).cover?(basis_points)

      fee = Integer(units) * basis_points / 10_000
      [fee, units - fee]
    end
  end
end
