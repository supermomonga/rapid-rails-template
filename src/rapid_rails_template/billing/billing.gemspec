Gem::Specification.new do |spec|
  spec.name = "billing"
  spec.version = "0.1.0"
  spec.authors = ["Application maintainers"]
  spec.summary = "Application-local USDC subscriptions using Spend Permissions"
  spec.files = Dir["{app,config,db,lib}/**/*"]
  spec.required_ruby_version = ">= 4.0"
  spec.add_dependency "rails", ">= 8.1", "< 8.2"
  spec.add_dependency "eth", "0.5.17"
  spec.add_dependency "json", "~> 2.21"
  spec.add_dependency "sorbet-runtime"
end
