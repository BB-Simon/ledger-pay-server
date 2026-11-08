require "swagger_helper"

RSpec.describe "Payments", type: :request do
  let(:Authorization) { bearer_for(users(:alice)) }
  let(:wallet) { wallets(:alice_usd) }

  def succeeded_payment
    payment = Payment.create!(
      user: users(:alice), wallet: wallet, currency: currencies(:usd), amount: 1_000,
      provider: "stripe", provider_payment_id: "pi_doc", status: :succeeded
    )
    Ledger::Deposit.call(wallet: wallet, amount: 1_000, reference: "PAYMENT-#{payment.id}")
    payment
  end

  path "/api/v1/payments" do
    post "Start a card payment into a wallet" do
      tags "Payments"
      description "Creates a pending payment and a Stripe PaymentIntent. Confirm it on the client with the returned " \
                  "`client_secret`; the wallet is credited when Stripe's webhook reports success."
      consumes "application/json"
      produces "application/json"
      parameter name: :body, in: :body, schema: {
        type: :object,
        properties: {
          wallet_id: { type: :integer },
          amount: { type: :integer, minimum: 1, description: "Cents" }
        },
        required: %w[wallet_id amount]
      }
      let(:body) { { wallet_id: wallet.id, amount: 1_000 } }

      response "201", "payment created; confirm it with the client secret" do
        schema "$ref" => "#/components/schemas/Payment"
        before do
          allow(Stripe::PaymentIntent).to receive(:create)
            .and_return(fake_stripe(Stripe::PaymentIntent, id: "pi_doc", client_secret: "pi_doc_secret_123"))
        end

        run_test!
      end

      response "401", "not logged in" do
        schema "$ref" => "#/components/schemas/Error"
        let(:Authorization) { nil }

        run_test!
      end

      response "404", "the wallet isn't yours" do
        schema "$ref" => "#/components/schemas/RailsNotFound"
        let(:body) { { wallet_id: wallets(:bob_usd).id, amount: 1_000 } }

        run_test!
      end

      response "422", "invalid amount or wallet, or Stripe rejected the payment (it is marked failed)" do
        schema "$ref" => "#/components/schemas/Error"
        let(:body) { { wallet_id: wallet.id, amount: "10.99" } }

        run_test!
      end

      response "503", "Stripe didn't answer; the payment is marked failed, try again" do
        schema "$ref" => "#/components/schemas/Error"
        before { allow(Stripe::PaymentIntent).to receive(:create).and_raise(Stripe::APIConnectionError.new("timeout")) }

        run_test!
      end
    end
  end

  path "/api/v1/payments/{id}" do
    parameter name: :id, in: :path, schema: { type: :integer }

    get "Get one of your payments" do
      tags "Payments"
      produces "application/json"

      response "200", "the payment" do
        schema "$ref" => "#/components/schemas/Payment"
        let(:id) { succeeded_payment.id }

        run_test!
      end

      response "401", "not logged in" do
        schema "$ref" => "#/components/schemas/Error"
        let(:Authorization) { nil }
        let(:id) { 0 }

        run_test!
      end

      response "404", "not found, or not yours" do
        schema "$ref" => "#/components/schemas/RailsNotFound"
        let(:id) { 0 }

        run_test!
      end
    end
  end

  path "/api/v1/payments/{payment_id}/refunds" do
    parameter name: :payment_id, in: :path, schema: { type: :integer }

    get "List a payment's refunds" do
      tags "Payments"
      description "Newest first. Not paginated yet."
      produces "application/json"

      response "200", "the refunds" do
        schema type: :array, items: { "$ref" => "#/components/schemas/Refund" }
        let(:payment_id) do
          payment = succeeded_payment
          payment.refunds.create!(amount: 200, provider: "stripe", provider_refund_id: "re_doc", status: :succeeded)
          payment.id
        end

        run_test!
      end
    end

    post "Refund part or all of a payment" do
      tags "Payments"
      description "Creates a pending refund and sends it to Stripe. The total refunded can't exceed the payment, and " \
                  "the wallet must still hold the money. The wallet is debited when Stripe's webhook reports success."
      consumes "application/json"
      produces "application/json"
      parameter "$ref" => "#/components/parameters/IdempotencyKeyOptional"
      parameter name: :body, in: :body, schema: {
        type: :object,
        properties: {
          amount: { type: :integer, minimum: 1, description: "Cents" },
          reason: { type: :string, enum: %w[duplicate fraudulent requested_by_customer] }
        },
        required: %w[amount]
      }
      let(:payment_id) { succeeded_payment.id }
      let(:"Idempotency-Key") { "refund-#{SecureRandom.hex(4)}" }
      let(:body) { { amount: 400, reason: "requested_by_customer" } }

      before do
        allow(Stripe::Refund).to receive(:create).and_return(fake_stripe(Stripe::Refund, id: "re_doc"))
      end

      response "201", "refund created (pending until Stripe confirms)" do
        schema "$ref" => "#/components/schemas/Refund"

        run_test!
      end

      response "404", "not found, or not yours" do
        schema "$ref" => "#/components/schemas/RailsNotFound"
        let(:payment_id) { 0 }

        run_test!
      end

      response "422", "invalid amount, more than refundable, insufficient wallet balance, or Stripe rejected it" do
        schema "$ref" => "#/components/schemas/Error"
        let(:body) { { amount: 5_000 } }

        run_test!
      end
    end
  end
end
