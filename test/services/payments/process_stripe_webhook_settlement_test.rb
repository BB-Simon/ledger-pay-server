require "test_helper"

# Webhooks for money that already left at Stripe must settle in the ledger,
# instead of failing with ArgumentError (422) and being retried forever.
class Payments::ProcessStripeWebhookSettlementTest < ActiveSupport::TestCase
  setup do
    @wallet = wallets(:alice_usd)
    @account = accounts(:alice_usd)
  end

  def stripe_event(type, object)
    Stripe::Event.construct_from(id: "evt_#{SecureRandom.hex(8)}", type: type, data: { object: object })
  end

  test "refund.updated(succeeded) settles even if the wallet balance is too low" do
    payment = Payment.create!(
      user: users(:alice), wallet: @wallet, currency: currencies(:usd), amount: 1_000,
      provider: "stripe", provider_payment_id: "pi_settle", status: :succeeded
    )
    refund = payment.refunds.create!(amount: 500, provider: "stripe", provider_refund_id: "re_settle", status: :pending)

    event = stripe_event("refund.updated", {
      id: "re_settle", object: "refund", amount: 500, currency: "usd",
      status: "succeeded", metadata: { refund_id: refund.id.to_s }
    })

    Payments::ProcessStripeWebhook.call(event: event)

    assert refund.reload.succeeded?
    assert_equal(-500, @account.reload.balance)
    assert WebhookEvent.find_by!(event_id: event.id).processed?
  end

  test "payout.paid settles even if the wallet balance is too low" do
    withdrawal = Withdrawal.create!(
      user: users(:alice), wallet: @wallet, currency: currencies(:usd), amount: 500,
      provider: "stripe", provider_withdrawal_id: "po_settle", status: :pending
    )

    event = stripe_event("payout.paid", {
      id: "po_settle", object: "payout", amount: 500, currency: "usd",
      status: "paid", metadata: { withdrawal_id: withdrawal.id.to_s }
    })

    Payments::ProcessStripeWebhook.call(event: event)

    assert withdrawal.reload.succeeded?
    assert_equal(-500, @account.reload.balance)
    assert WebhookEvent.find_by!(event_id: event.id).processed?
  end
end
