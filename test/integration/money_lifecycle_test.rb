require "test_helper"

# One customer's money through every flow the app supports, using the real
# services and webhook processor (Stripe faked). After every step the whole
# ledger must still balance and the trial balance must hold.
class MoneyLifecycleTest < ActiveSupport::TestCase
  setup do
    @alice = users(:alice)
    @wallet = wallets(:alice_usd)
  end

  def fake_stripe_create(klass, id)
    ->(_original, *) { klass.construct_from(id: id, client_secret: "#{id}_secret") }
  end

  test "payment, transfer, refund, withdrawal and late payout failure keep the ledger balanced" do
    # 1. Card payment of 10.00, settled by Stripe's webhook.
    payment = with_class_method(Stripe::PaymentIntent, :create, fake_stripe_create(Stripe::PaymentIntent, "pi_life")) do
      Payments::CreatePayment.call(user: @alice, wallet: @wallet, amount: 1_000)[:payment]
    end
    assert_equal 0, balance_of(:alice_usd), "a pending payment doesn't credit the wallet"

    deliver(stripe_event("payment_intent.succeeded", payment_intent_object(payment.reload, status: "succeeded")))
    assert_equal 1_000, balance_of(:alice_usd)
    assert_ledger_balanced

    # 2. Transfer 3.00 to Bob.
    Ledger::IdempotentTransfer.call(user: @alice, from_wallet: @wallet, to_wallet: wallets(:bob_usd),
      amount: 300, idempotency_key: "life-transfer")
    assert_equal 700, balance_of(:alice_usd)
    assert_equal 300, balance_of(:bob_usd)
    assert_ledger_balanced

    # 3. Partial refund of 2.00, settled by Stripe's webhook.
    refund = with_class_method(Stripe::Refund, :create, fake_stripe_create(Stripe::Refund, "re_life")) do
      Payments::CreateRefund.call(payment: payment.reload, amount: 200, reason: "requested_by_customer")[:refund]
    end
    assert_equal 700, balance_of(:alice_usd), "a pending refund only holds the money"
    assert_equal 500, Wallet.find(@wallet.id).available_balance

    deliver(stripe_event("refund.updated", refund_object(refund.reload, status: "succeeded")))
    assert_equal 500, balance_of(:alice_usd)
    assert_ledger_balanced

    # 4. Withdrawal of 4.00, paid out by Stripe.
    withdrawal = with_class_method(Stripe::Payout, :create, fake_stripe_create(Stripe::Payout, "po_life")) do
      Withdrawals::CreateWithdrawal.call(user: @alice, wallet: Wallet.find(@wallet.id), amount: 400)
    end
    assert_equal 100, Wallet.find(@wallet.id).available_balance

    deliver(stripe_event("payout.paid", payout_object(withdrawal.reload, status: "paid")))
    assert_equal 100, balance_of(:alice_usd)
    assert_ledger_balanced

    # 5. The bank rejects the payout days later: the money comes back.
    deliver(stripe_event("payout.failed", payout_object(withdrawal, status: "failed",
      failure_code: "account_closed", failure_message: "The bank account has been closed")))
    assert_equal 500, balance_of(:alice_usd)
    assert withdrawal.reload.failed?
    assert_ledger_balanced

    # Where the money is: 10.00 came in through Stripe; 2.00 was refunded to
    # the card; Bob holds 3.00 and Alice 5.00. The payout and its reversal net
    # to zero in the withdrawal clearing account.
    assert_equal 800, balance_of(:stripe_clearing_usd)
    assert_equal 0, balance_of(:withdrawal_clearing_usd)
    assert_equal 800, balance_of(:alice_usd) + balance_of(:bob_usd)
    assert_equal %w[deposit refund reversal transfer withdrawal], Transaction.distinct.pluck(:transaction_type).sort
  end
end
