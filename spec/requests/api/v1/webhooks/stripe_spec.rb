require "swagger_helper"

RSpec.describe "Stripe webhook", type: :request do
  around { |example| with_webhook_secret { example.run } }

  let(:withdrawal) do
    Withdrawal.create!(
      user: users(:alice), wallet: wallets(:alice_usd), currency: currencies(:usd), amount: 400,
      provider: "stripe", provider_withdrawal_id: "po_doc", status: :pending
    )
  end

  def payout_paid_event(withdrawal)
    {
      id: "evt_#{SecureRandom.hex(8)}", object: "event", type: "payout.paid",
      data: { object: { id: "po_doc", object: "payout", amount: 400, currency: "usd", status: "paid",
                        metadata: { withdrawal_id: withdrawal.id.to_s } } }
    }
  end

  path "/api/v1/webhooks/stripe" do
    post "Receive a Stripe event" do
      tags "Webhooks"
      description <<~TEXT
        Called by Stripe, authenticated by the `Stripe-Signature` header. Each event is stored once (redeliveries are
        ignored) and settles the matching payment, refund or payout.

        - An event that can never be applied (wrong amount, unknown record) is marked failed and still answered with
          200, so Stripe stops resending it.
        - An event that arrives before the payout or refund has its Stripe id saved gets 409, so Stripe resends it later.
        - Temporary errors return 5xx, so Stripe retries.
      TEXT
      security []
      consumes "application/json"
      produces "application/json"
      parameter "$ref" => "#/components/parameters/StripeSignature"
      parameter name: :body, in: :body, schema: { type: :object, description: "A Stripe event object" }
      let(:body) { payout_paid_event(withdrawal) }
      let(:"Stripe-Signature") { stripe_signature_for(body) }

      response "200", "event received (applied, or recorded as failed)" do
        schema type: :object, additionalProperties: false,
          properties: { received: { type: :boolean } }, required: %w[received]

        run_test! do
          expect(withdrawal.reload).to be_succeeded
        end
      end

      response "400", "invalid signature or payload" do
        schema "$ref" => "#/components/schemas/Error"
        let(:"Stripe-Signature") { stripe_signature_for(body, secret: "whsec_wrong") }

        run_test!
      end

      response "409", "the local record isn't submitted to Stripe yet; Stripe should resend later" do
        schema "$ref" => "#/components/schemas/Error"
        let(:withdrawal) do
          Withdrawal.create!(
            user: users(:alice), wallet: wallets(:alice_usd), currency: currencies(:usd), amount: 400,
            provider: "stripe", provider_withdrawal_id: nil, status: :pending
          )
        end

        run_test!
      end
    end
  end
end
