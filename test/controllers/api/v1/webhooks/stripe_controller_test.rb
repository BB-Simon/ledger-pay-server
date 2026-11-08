require "test_helper"

class Api::V1::Webhooks::StripeControllerTest < ActionDispatch::IntegrationTest
  SECRET = "whsec_test_secret"

  setup do
    @original_secret = ENV["STRIPE_WEBHOOK_SECRET"]
    ENV["STRIPE_WEBHOOK_SECRET"] = SECRET

    Ledger::Deposit.call(wallet: wallets(:alice_usd), amount: 1_000, reference: "TEST-FUND-ALICE")
  end

  teardown do
    ENV["STRIPE_WEBHOOK_SECRET"] = @original_secret
  end

  def pending_withdrawal(provider_withdrawal_id: "po_ctrl")
    Withdrawal.create!(
      user: users(:alice), wallet: wallets(:alice_usd), currency: currencies(:usd), amount: 400,
      provider: "stripe", provider_withdrawal_id: provider_withdrawal_id, status: :pending
    )
  end

  def payout_paid_payload(withdrawal, amount: 400)
    {
      id: "evt_#{SecureRandom.hex(8)}", object: "event", type: "payout.paid",
      data: { object: { id: "po_ctrl", object: "payout", amount: amount, currency: "usd", status: "paid",
                        metadata: { withdrawal_id: withdrawal.id.to_s } } }
    }.to_json
  end

  # Signs the payload the way Stripe does.
  def deliver(payload, secret: SECRET)
    now = Time.now
    signature = Stripe::Webhook::Signature.compute_signature(now, payload, secret)
    header = Stripe::Webhook::Signature.generate_header(now, signature)

    post "/api/v1/webhooks/stripe", params: payload,
      headers: { "Stripe-Signature" => header, "Content-Type" => "application/json" }
  end

  test "a valid event is processed and acknowledged" do
    withdrawal = pending_withdrawal

    deliver(payout_paid_payload(withdrawal))

    assert_response :ok
    assert withdrawal.reload.succeeded?
  end

  test "an event that can never succeed is acknowledged with 200 so Stripe stops retrying" do
    withdrawal = pending_withdrawal

    deliver(payout_paid_payload(withdrawal, amount: 999))

    assert_response :ok
    assert_equal({ "received" => true }, response.parsed_body)
    assert WebhookEvent.sole.failed?
    assert withdrawal.reload.pending?
  end

  test "an event that arrives before the Stripe id is saved gets 409 so Stripe retries" do
    withdrawal = pending_withdrawal(provider_withdrawal_id: nil)

    deliver(payout_paid_payload(withdrawal))

    assert_response :conflict
    assert_match(/not submitted to Stripe yet/, response.parsed_body["error"])
    assert WebhookEvent.sole.pending?
  end

  test "a bad signature is rejected and nothing is stored" do
    deliver(payout_paid_payload(pending_withdrawal), secret: "whsec_wrong")

    assert_response :bad_request
    assert_equal 0, WebhookEvent.count
  end
end
