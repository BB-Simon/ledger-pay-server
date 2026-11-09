ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require "sidekiq/testing"

Rails.root.glob("test/support/**/*.rb").sort.each { |file| require file }

# Jobs are pushed to an in-memory array (Job.jobs), never to Redis.
Sidekiq::Testing.fake!

module ActiveSupport
  class TestCase
    setup do
      Sidekiq::Job.clear_all
      Rails.cache.clear # rate-limit counters
    end

    # Serial by default: concurrency tests use committed data and several DB
    # connections, and tests swap class methods (e.g. Stripe) temporarily, so
    # parallel threads would interfere. Opt in with PARALLEL_WORKERS=n.
    parallelize(workers: ENV.fetch("PARALLEL_WORKERS", 1).to_i, with: :threads)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    include LedgerAssertions
    include StripeEventHelpers

    # Temporarily replaces a class method and always restores the original.
    # The replacement receives the original method first:
    #   with_class_method(Foo, :call, ->(original, **kw) { original.call(**kw) }) { ... }
    def with_class_method(klass, name, replacement)
      original = klass.method(name)
      klass.define_singleton_method(name) { |*args, **kwargs| replacement.call(original, *args, **kwargs) }
      yield
    ensure
      klass.define_singleton_method(name, original)
    end
  end
end
