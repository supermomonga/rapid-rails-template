# frozen_string_literal: true

desc "全部入り日本語sampleのUIエビデンスを再生成する"
task "evidence:update" do
  ruby File.expand_path("bin/update-evidence", __dir__)
end

desc "保存済みUIエビデンスの鮮度と整合性を検証する"
task "evidence:verify" do
  ruby File.expand_path("bin/verify-evidence", __dir__)
end
