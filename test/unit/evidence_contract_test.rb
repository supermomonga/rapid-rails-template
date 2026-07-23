# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../src/rapid_rails_template/evidence"

class EvidenceContractTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  def test_committed_ui_evidence_is_current
    assert RapidRailsTemplate::Evidence.verify(root: ROOT)
  end
end
