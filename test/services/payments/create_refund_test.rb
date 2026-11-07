require "test_helper"

class Payments::CreateRefundTest < ActiveSupport::TestCase
  setup do
    @wallet = wallets(:alice_usd)
    @stripe_refund_calls = 0
  end

  def succeeded_payment(amount)
    payment = Payment.create!(
      user: users(:alice), wallet: @wallet, currency: currencies(:usd), amount: amount,
      provider: "stripe", provider_payment_id: "pi_#{SecureRandom.hex(4)}", status: :succeeded
    )
    Ledger::Deposit.call(wallet: @wallet, amount: amount, reference: "PAYMENT-#{payment.id}")
    payment
  end

  def refund(payment, amount)
    fake_stripe = lambda do |_original, *_args, **_kwargs|
      @stripe_refund_calls += 1
      Stripe::Refund.construct_from(id: "re_#{SecureRandom.hex(4)}")
    end

    with_class_method(Stripe::Refund, :create, fake_stripe) do
      Payments::CreateRefund.call(payment: payment, amount: amount, reason: "requested_by_customer")
    end
  end

  def spend(amount)
    Ledger::Transfer.call(
      from_wallet: Wallet.find(@wallet.id), to_wallet: wallets(:bob_usd),
      amount: amount, reference: SecureRandom.uuid
    )
  end

  test "creates a pending refund within the payment and wallet limits" do
    payment = succeeded_payment(1_000)

    result = refund(payment, 400)

    assert result[:refund].pending?
    assert_equal 1, @stripe_refund_calls
  end

  test "rejects a refund when the wallet no longer holds the money, before calling Stripe" do
    payment = succeeded_payment(1_000)
    spend(1_000)

    assert_no_difference -> { Refund.count } do
      error = assert_raises(ArgumentError) { refund(payment, 500) }
      assert_match(/Insufficient wallet balance/, error.message)
    end
    assert_equal 0, @stripe_refund_calls
  end

  test "a pending refund holds its amount so it can't be transferred away" do
    payment = succeeded_payment(1_000)
    refund(payment, 600)

    assert_equal 400, Wallet.find(@wallet.id).available_balance
    assert_raises(ArgumentError) { spend(500) }
    assert_equal 1_000, accounts(:alice_usd).reload.balance
  end

  test "partial refunds still can't exceed the payment amount" do
    payment = succeeded_payment(1_000)
    refund(payment, 700)

    error = assert_raises(ArgumentError) { refund(payment.reload, 400) }
    assert_match(/exceeds refundable amount/, error.message)
  end
end
