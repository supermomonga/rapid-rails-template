# frozen_string_literal: true

require_relative "../test_helper"

class SampleAppTemplateTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  def setup
    @source = File.read(File.join(ROOT, "bin/sample-app-template"))
    @runner = File.read(File.join(ROOT, "bin/apply-sample-app-template"))
  end

  def test_applies_the_template_through_the_rails_application_generator
    assert_includes @runner, 'require "rails/generators/rails/app/app_generator"'
    assert_includes @runner, "Rails::Generators::AppGenerator.apply_rails_template(template, destination)"
    assert_includes @runner, "Dir.chdir(destination)"
  end

  def test_generates_article_scaffold_with_profile_ownership
    assert_includes @source, 'generate "scaffold", "Article", "title:string", "body:text", "draft:boolean"'
    assert_includes @source, '@pagy, @articles = pagy(:offset, Article.all.order(:id), limit: 25)'
    assert_includes @source, '<%= pagination(@pagy, aria_label: "Articles pagination") %>'
    assert_includes @source, "t.references :profile, null: false, foreign_key: { on_delete: :cascade }"
    assert_includes @source, "t.string :title, null: false"
    assert_includes @source, "t.text :body, null: false"
    assert_includes @source, "t.boolean :draft, null: false, default: true"
    assert_includes @source, "has_many :articles, dependent: :destroy"
    assert_includes @source, "belongs_to :profile"
    assert_includes @source, "create_file \"app/models/article.rb\", <<~'RUBY', force: true\n  # typed: true"
    assert_includes @source, "create_file \"app/helpers/articles_helper.rb\", <<~'RUBY', force: true\n  # typed: true"
    assert_includes @source, "create_file \"app/policies/article_policy.rb\", <<~'RUBY', force: true\n  # typed: true"
    assert_includes @source, "create_file \"app/controllers/articles_controller.rb\", <<~'RUBY', force: true\n  # typed: true"
    assert_includes @source, "create_file \"test/controllers/articles_controller_test.rb\", <<~'RUBY', force: true\n  # typed: true"
    assert_includes @source, "params.expect(article: %i[title body draft])"
    refute_includes @source, "params.expect(article: %i[profile_id"
  end

  def test_authorizes_owners_and_paginates_visible_articles
    assert_includes @source, "class ArticlePolicy < ApplicationPolicy"
    assert_includes @source, "T::Sig::WithoutRuntime.sig { returns(T::Boolean) }"
    assert_includes @source, "scope_for :active_record_relation do |relation|"
    assert_includes @source, "T.bind(self, ArticlePolicy)"
    assert_includes @source, "authorize :user, optional: true"
    assert_includes @source, "published.or(relation.where(profile_id: T.must(policy_user.profile).id))"
    assert_includes @source, "@article = Article.new(article_params)"
    assert_includes @source, "@article.profile = T.must(account_user.profile)"
    assert_includes @source, "pagy(:offset, visible_articles, limit: 25)"
    assert_includes @source, 'pagination(@pagy, aria_label: "Article pagination")'
    assert_includes @source, 'table table-sm table-pin-rows min-w-[780px]'
    assert_includes @source, 'td class="min-w-64"'
  end

  def test_seeds_ten_users_and_fifty_articles_each
    assert_includes @source, "sample_users = 10.times.map"
    assert_includes @source, "50.times do |article_index|"
    assert_includes @source, 'screen_name = format("sample_user_%02d", number)'
    assert_includes @source, "profile = Profile.find_by(screen_name: screen_name)"
    assert_includes @source, "user = T.must(profile.user)"
    assert_includes @source, "user = User.create!"
    assert_includes @source, 'user.passkey_credentials.find_or_create_by!(webauthn_id: "sample-passkey-#{screen_name}")'
    assert_includes @source, "article = profile.articles.find_or_initialize_by("
    assert_includes @source, 'article.draft = article_number > 40'
    assert_includes @source, "assert_equal 500, Article.where"
    assert_includes @source, "sample_profiles = Profile.where(screen_name: screen_names).includes(:user).order(:screen_name).to_a"
    assert_includes @source, "sample_users = sample_profiles.map { |profile| T.must(profile.user) }"
    assert_includes @source, 'puts "Sample users (seeded Passkeys are display-only and cannot authenticate):"'
    refute_includes @source, "password123"
    refute_includes @source, "user.login_id"
    assert_includes @source, '2.times { load Rails.root.join("db/seeds.rb").to_s }'
    assert_includes @source, "seed_notifications.map(&:message_plain_text)"
    refute_includes @source, "notification: { message: seed_notification_messages }"
    assert_includes @source, "created = T.must(Article.order(:id).last)"
  end

  def test_prepares_formats_seeds_and_tests_the_generated_app_in_order
    commands = [
      'sample_run_checked "bin/rails db:prepare"',
      'sample_run_checked "bin/annotaterb models"',
      'sample_run_checked "RAILS_ENV=test bin/rails db:prepare"',
      'sample_run_checked "RAILS_ENV=test bin/tapioca dsl --environment=test"',
      'sample_run_checked "bin/tapioca gems --verify"',
      'sample_run_checked "RAILS_ENV=test bin/tapioca dsl --verify --environment=test"',
      'sample_run_checked "bin/tapioca check-shims"',
      'sample_run_checked "bundle exec srb tc"',
      'sample_run_checked "bin/rubocop -a"',
      'sample_run_checked "bin/rails db:seed"',
      'sample_run_checked "bin/rails test"'
    ]

    indexes = commands.map do |command|
      @source.index(command).then { |index| refute_nil(index, command); index }
    end
    assert_equal indexes.sort, indexes
  end
end
