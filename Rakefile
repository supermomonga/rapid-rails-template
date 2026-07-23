# frozen_string_literal: true

desc "Devise版とSIWE版のUIエビデンスを再生成する"
task "evidence:update" do
  ruby File.expand_path("bin/update-evidence", __dir__)
end

desc "保存済みUIエビデンスの鮮度と整合性を検証する"
task "evidence:verify" do
  ruby File.expand_path("bin/verify-evidence", __dir__)
end
