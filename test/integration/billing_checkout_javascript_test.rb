# frozen_string_literal: true

require_relative "../test_helper"
require "open3"

class BillingCheckoutJavascriptTest < Minitest::Test
  def test_checkout_review_signature_and_recovery
    output, status = Open3.capture2e("node", "--experimental-vm-modules", File.expand_path("../javascript/billing_checkout_test.mjs", __dir__))
    assert status.success?, output
  end
end
