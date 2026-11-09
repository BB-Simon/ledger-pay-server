require "test_helper"

# Stripe can redeliver an event while the first delivery is still being
# processed. The two must not both move money. Uses committed data and one DB
# connection per thread, so it runs outside a test transaction and cleans up.
class Payments::WebhookConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @payment = Payment.create!(
      user: users(:alice), wallet: wallets(:alice_usd), currency: currencies(:usd), amount: 1_000,
      provider: "stripe", provider_payment_id: "pi_concurrent", status: :pending
    )
  end

  teardown do
    AuditLog.delete_all
    LedgerEntry.delete_all
    Transaction.delete_all
    WebhookEvent.delete_all
    Payment.delete_all
  end

  def deliver_in_thread(event, pause: false)
    Thread.new do
      Thread.current[:pause_in_deposit] = pause
      ActiveRecord::Base.connection_pool.with_connection { deliver(event) }
    end
  end

  test "two simultaneous deliveries of the same event credit the wallet once" do
    event = stripe_event("payment_intent.succeeded", payment_intent_object(@payment, status: "succeeded"))
    first_in_deposit = Queue.new

    # The first delivery pauses inside the deposit, holding the event's lock.
    slow_deposit = lambda do |original, **kwargs|
      if Thread.current[:pause_in_deposit]
        first_in_deposit << true
        sleep 0.5
      end
      original.call(**kwargs)
    end

    results = with_class_method(Ledger::Deposit, :call, slow_deposit) do
      first = deliver_in_thread(event, pause: true)
      first_in_deposit.pop
      second = deliver_in_thread(event)

      [ first.value, second.value ]
    end

    assert(results.all?(&:processed?))
    assert_equal 1, WebhookEvent.where(event_id: event.id).count
    assert_equal 1, Transaction.where(reference: "PAYMENT-#{@payment.id}").count
    assert_equal 1_000, balance_of(:alice_usd)
    assert_ledger_balanced
  end

  test "two different events for one payment, at the same moment, credit it once" do
    events = 2.times.map { stripe_event("payment_intent.succeeded", payment_intent_object(@payment, status: "succeeded")) }
    first_in_deposit = Queue.new

    slow_deposit = lambda do |original, **kwargs|
      if Thread.current[:pause_in_deposit]
        first_in_deposit << true
        sleep 0.5
      end
      original.call(**kwargs)
    end

    with_class_method(Ledger::Deposit, :call, slow_deposit) do
      first = deliver_in_thread(events[0], pause: true)
      first_in_deposit.pop
      second = deliver_in_thread(events[1])
      [ first, second ].each(&:join)
    end

    assert_equal 1, Transaction.where(reference: "PAYMENT-#{@payment.id}").count
    assert_equal 1_000, balance_of(:alice_usd)
  end
end
