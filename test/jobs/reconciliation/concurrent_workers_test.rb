require "test_helper"

# Two Sidekiq workers can pick up the same item (a duplicate job, or a
# recovery re-enqueue). Only one may reconcile it. Uses committed data and
# one DB connection per thread, so it runs outside a test transaction.
class Reconciliation::ConcurrentWorkersTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @payment = Payment.create!(
      user: users(:alice), wallet: wallets(:alice_usd), currency: currencies(:usd), amount: 1_000,
      provider: "stripe", provider_payment_id: "pi_workers", status: :succeeded
    )
    @run = Reconciliation::Run.call(run_type: "payments")
    @item = @run.reconciliation_run_items.sole
  end

  teardown do
    ReconciliationResult.delete_all
    ReconciliationRecord.delete_all
    ReconciliationRunItem.delete_all
    ReconciliationRun.delete_all
    Payment.delete_all
  end

  test "two workers on the same item: one reconciles it, the other backs off" do
    first_fetching = Queue.new
    calls = Queue.new

    # The first worker pauses while fetching from Stripe, after claiming.
    slow_retrieve = lambda do |_original, id, *|
      calls << id
      if Thread.current[:first_worker]
        first_fetching << true
        sleep 0.5
      end
      Stripe::PaymentIntent.construct_from(id: id, amount: 1_000, currency: "usd", status: "succeeded")
    end

    with_class_method(Stripe::PaymentIntent, :retrieve, slow_retrieve) do
      first = Thread.new do
        Thread.current[:first_worker] = true
        ActiveRecord::Base.connection_pool.with_connection { Reconciliation::PaymentJob.new.perform(@item.id) }
      end
      first_fetching.pop
      second = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection { Reconciliation::PaymentJob.new.perform(@item.id) }
      end
      [ first, second ].each(&:join)
    end

    assert_equal 1, calls.size, "only the worker that claimed the item calls Stripe"
    assert @item.reload.matched?
    assert_equal 1, @item.attempts
    assert_equal 1, @run.reconciliation_results.count
    assert @run.reload.completed?
    assert_equal 1, @run.matched_count
  end
end
