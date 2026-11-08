# RSpec is used only for the rswag API-doc specs in spec/requests/. All other
# tests are Minitest (test/). See AGENTS.md and docs/TESTING.md.
require "spec_helper"
ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
abort("The Rails environment is running in production mode!") if Rails.env.production?
require "rspec/rails"
require "sidekiq/testing"

# Jobs are pushed to an in-memory array (Job.jobs), never to Redis.
Sidekiq::Testing.fake!

Rails.root.glob("spec/support/**/*.rb").sort.each { |file| require file }

begin
  ActiveRecord::Migration.maintain_test_schema!
rescue ActiveRecord::PendingMigrationError => e
  abort e.to_s.strip
end

RSpec.configure do |config|
  # Reuse the Minitest fixtures (alice, bob, admin, alice_usd, clearing accounts).
  config.fixture_paths = [ Rails.root.join("test/fixtures") ]
  config.global_fixtures = :all
  config.use_transactional_fixtures = true

  config.infer_spec_type_from_file_location!
  config.filter_rails_from_backtrace!

  config.include AuthHelpers
  config.include StripeHelpers

  config.before do
    Sidekiq::Job.clear_all
    Rails.cache.clear # rate-limit counters
  end

  # Document error bodies as production sends them. The test env sets
  # consider_all_requests_local, which adds debug fields ("exception",
  # "traces") to Rails' 404 body that production never returns.
  config.around(type: :request) do |example|
    env_config = Rails.application.env_config
    original = env_config["action_dispatch.show_detailed_exceptions"]
    env_config["action_dispatch.show_detailed_exceptions"] = false
    example.run
  ensure
    env_config["action_dispatch.show_detailed_exceptions"] = original
  end
end
