require "test_helper"

# Webhook guarantees that protect the ledger: each payment, refund and payout
# moves money at most once, no matter how often or in which order Stripe
# delivers its events.
class Payments::WebhookIntegrityTest < ActiveSupport::TestCase
  setup do
    @alice = users(:alice)
    @wallet = wallets(:alice_usd)
  end

  def pending_payment(amount: 1_000)
    Payment.create!(user: @alice, wallet: @wallet, currency: currencies(:usd), amount: amount,
      provider: "stripe", provider_payment_id: "pi_#{SecureRandom.hex(4)}", status: :pending)
  end

  def settled_payment(amount: 1_000)
    payment = pending_payment(amount: amount)
    deliver(stripe_event("payment_intent.succeeded", payment_intent_object(payment, status: "succeeded")))
    payment.reload
  end

  def pending_withdrawal(amount: 400)
    Withdrawal.create!(user: @alice, wallet: @wallet, currency: currencies(:usd), amount: amount,
      provider: "stripe", provider_withdrawal_id: "po_#{SecureRandom.hex(4)}", status: :pending)
  end

  def pending_refund(payment, amount)
    payment.refunds.create!(amount: amount, provider: "stripe", provider_refund_id: "re_#{SecureRandom.hex(4)}", status: :pending)
  end

  def deposits_for(payment)
    Transaction.where(reference: "PAYMENT-#{payment.id}").count
  end

  # --- Payments: successful and failed processing ---

  test "a successful payment credits the wallet once, with a balanced deposit" do
    payment = settled_payment

    assert payment.succeeded?
    assert_equal 1_000, balance_of(:alice_usd)
    assert_equal 1, deposits_for(payment)
    assert AuditLog.exists?(action: "payment.succeeded", auditable_type: "Payment", auditable_id: payment.id)
    assert_ledger_balanced
  end

  test "a failed payment is recorded with Stripe's reason and never touches the ledger" do
    payment = pending_payment

    assert_no_difference -> { LedgerEntry.count } do
      deliver(stripe_event("payment_intent.payment_failed", payment_intent_object(payment, status: "requires_payment_method",
        last_payment_error: { code: "card_declined", message: "Your card was declined." })))
    end

    payment.reload
    assert payment.failed?
    assert_equal "card_declined", payment.failure_code
    assert_equal "Your card was declined.", payment.failure_message
  end

  test "a canceled payment never touches the ledger" do
    payment = pending_payment

    assert_no_difference -> { LedgerEntry.count } do
      deliver(stripe_event("payment_intent.canceled", payment_intent_object(payment, status: "canceled")))
    end

    assert payment.reload.canceled?
  end

  test "a payment that succeeds after a declined attempt is credited once" do
    payment = pending_payment
    deliver(stripe_event("payment_intent.payment_failed", payment_intent_object(payment, status: "requires_payment_method")))

    # The customer retried with another card on the same PaymentIntent.
    deliver(stripe_event("payment_intent.succeeded", payment_intent_object(payment, status: "succeeded")))

    assert payment.reload.succeeded?
    assert_equal 1_000, balance_of(:alice_usd)
  end

  test "a success event with the wrong amount credits nothing and is recorded as failed" do
    payment = pending_payment

    event = deliver(stripe_event("payment_intent.succeeded", payment_intent_object(payment, status: "succeeded", amount: 9_999)))

    assert event.reload.failed?
    assert payment.reload.pending?
    assert_equal 0, balance_of(:alice_usd)
  end

  # --- Duplicates ---

  test "the same event delivered twice credits the wallet once" do
    payment = pending_payment
    event = stripe_event("payment_intent.succeeded", payment_intent_object(payment, status: "succeeded"))

    deliver(event)
    assert_no_difference [ -> { LedgerEntry.count }, -> { WebhookEvent.count } ] do
      assert deliver(event).processed?
    end

    assert_equal 1_000, balance_of(:alice_usd)
  end

  test "two different success events for one payment credit it once" do
    payment = pending_payment

    2.times { deliver(stripe_event("payment_intent.succeeded", payment_intent_object(payment, status: "succeeded"))) }

    assert_equal 2, WebhookEvent.count
    assert_equal 1, deposits_for(payment)
    assert_equal 1_000, balance_of(:alice_usd)
  end

  test "a refund success delivered twice debits the wallet once" do
    refund = pending_refund(settled_payment, 400)

    2.times { deliver(stripe_event("refund.updated", refund_object(refund, status: "succeeded"))) }

    assert_equal 600, balance_of(:alice_usd)
    assert_equal 1, Transaction.where(reference: "REFUND-#{refund.id}").count
  end

  test "a payout paid twice debits the wallet once" do
    settled_payment
    withdrawal = pending_withdrawal

    2.times { deliver(stripe_event("payout.paid", payout_object(withdrawal, status: "paid"))) }

    assert_equal 600, balance_of(:alice_usd)
    assert_equal 1, Transaction.where(reference: "WITHDRAWAL-#{withdrawal.id}").count
  end

  test "a late payout failure delivered twice reverses the payout once" do
    settled_payment
    withdrawal = pending_withdrawal
    deliver(stripe_event("payout.paid", payout_object(withdrawal, status: "paid")))

    2.times { deliver(stripe_event("payout.failed", payout_object(withdrawal, status: "failed"))) }

    assert_equal 1_000, balance_of(:alice_usd)
    assert_equal 1, Transaction.where(reference: "WITHDRAWAL-REVERSAL-#{withdrawal.id}").count
    assert_ledger_balanced
  end

  # --- Out of order ---

  test "a cancel that arrives after the payment succeeded is ignored" do
    payment = settled_payment

    deliver(stripe_event("payment_intent.canceled", payment_intent_object(payment, status: "canceled")))

    assert payment.reload.succeeded?
    assert_equal 1_000, balance_of(:alice_usd)
  end

  test "a payout paid event that arrives after the payout failed is ignored" do
    settled_payment
    withdrawal = pending_withdrawal
    deliver(stripe_event("payout.failed", payout_object(withdrawal, status: "failed")))

    assert_no_difference -> { LedgerEntry.count } do
      deliver(stripe_event("payout.paid", payout_object(withdrawal, status: "paid")))
    end

    assert withdrawal.reload.failed?
    assert_equal 1_000, balance_of(:alice_usd)
  end

  test "a payout canceled event that arrives after it was paid is ignored" do
    settled_payment
    withdrawal = pending_withdrawal
    deliver(stripe_event("payout.paid", payout_object(withdrawal, status: "paid")))

    deliver(stripe_event("payout.canceled", payout_object(withdrawal, status: "canceled")))

    assert withdrawal.reload.succeeded?
    assert_equal 600, balance_of(:alice_usd)
  end

  test "a refund success that arrives after the refund failed is ignored" do
    refund = pending_refund(settled_payment, 400)
    deliver(stripe_event("refund.failed", refund_object(refund, status: "failed")))

    assert_no_difference -> { LedgerEntry.count } do
      deliver(stripe_event("refund.updated", refund_object(refund, status: "succeeded")))
    end

    assert refund.reload.failed?
    assert_equal 1_000, balance_of(:alice_usd)
  end

  # --- Refunds: partial and multiple ---

  test "several partial refunds can add up to exactly the payment amount, and no further" do
    payment = settled_payment
    stub_refund = ->(_original, *) { Stripe::Refund.construct_from(id: "re_#{SecureRandom.hex(4)}") }

    with_class_method(Stripe::Refund, :create, stub_refund) do
      [ 300, 300, 400 ].each { |amount| Payments::CreateRefund.call(payment: payment.reload, amount: amount, reason: nil) }

      error = assert_raises(ArgumentError) { Payments::CreateRefund.call(payment: payment.reload, amount: 1, reason: nil) }
      assert_match(/exceeds refundable amount/, error.message)
    end

    assert_equal 1_000, payment.reload.refunded_amount
    assert_equal 0, payment.refundable_amount
  end

  test "a failed refund's amount can be refunded again" do
    payment = settled_payment
    refund = pending_refund(payment, 1_000)
    assert_equal 0, payment.reload.refundable_amount

    deliver(stripe_event("refund.failed", refund_object(refund, status: "failed")))

    assert_equal 1_000, payment.reload.refundable_amount
    assert_equal 1_000, Wallet.find(@wallet.id).available_balance
  end

  # --- Withdrawals: failed payouts don't debit or lose money ---

  test "a payout that fails before being paid never debits the wallet and releases the hold" do
    settled_payment
    withdrawal = pending_withdrawal
    assert_equal 600, Wallet.find(@wallet.id).available_balance

    assert_no_difference -> { LedgerEntry.count } do
      deliver(stripe_event("payout.failed", payout_object(withdrawal, status: "failed")))
    end

    assert withdrawal.reload.failed?
    assert_equal 1_000, balance_of(:alice_usd)
    assert_equal 1_000, Wallet.find(@wallet.id).available_balance
  end

  test "a canceled payout never debits the wallet and releases the hold" do
    settled_payment
    withdrawal = pending_withdrawal

    assert_no_difference -> { LedgerEntry.count } do
      deliver(stripe_event("payout.canceled", payout_object(withdrawal, status: "canceled")))
    end

    assert_equal 1_000, Wallet.find(@wallet.id).available_balance
  end
end
