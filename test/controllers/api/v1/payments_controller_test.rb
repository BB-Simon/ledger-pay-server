require "test_helper"

class Api::V1::PaymentsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @wallet = wallets(:alice_usd)
    raw_token = SecureRandom.hex(32)
    AuthToken.create!(user: users(:alice), token_digest: Digest::SHA256.hexdigest(raw_token), expires_at: 1.day.from_now)
    @headers = { "Authorization" => "Bearer #{raw_token}" }
    @stripe_calls = []
  end

  def stripe_create(klass, error: nil)
    lambda do |_original, params, opts = {}|
      @stripe_calls << { params: params, opts: opts }
      raise error if error
      klass.construct_from(id: "#{klass == Stripe::Refund ? "re" : "pi"}_#{SecureRandom.hex(4)}",
        amount: params[:amount], client_secret: "secret_123", status: "pending")
    end
  end

  def create_payment(amount: 1_000, error: nil)
    with_class_method(Stripe::PaymentIntent, :create, stripe_create(Stripe::PaymentIntent, error: error)) do
      post "/api/v1/payments", params: { wallet_id: @wallet.id, amount: amount }, headers: @headers
    end
  end

  def succeeded_payment
    payment = Payment.create!(
      user: users(:alice), wallet: @wallet, currency: currencies(:usd), amount: 1_000,
      provider: "stripe", provider_payment_id: "pi_paid", status: :succeeded
    )
    Ledger::Deposit.call(wallet: @wallet, amount: 1_000, reference: "PAYMENT-#{payment.id}")
    payment
  end

  def create_refund(payment, amount: 400, headers: {})
    with_class_method(Stripe::Refund, :create, stripe_create(Stripe::Refund)) do
      post "/api/v1/payments/#{payment.id}/refunds", params: { amount: amount, reason: "requested_by_customer" },
        headers: @headers.merge(headers)
    end
  end

  # --- payments#create (M12, M13) ---

  test "creates a pending payment and returns the client secret" do
    create_payment

    assert_response :created
    body = response.parsed_body
    assert_equal "pending", body["status"]
    assert_equal "secret_123", body["client_secret"]
    assert_equal "payment-#{body["id"]}", @stripe_calls.sole[:opts][:idempotency_key]
  end

  test "a decimal amount is rejected before calling Stripe" do
    assert_no_difference -> { Payment.count } do
      create_payment(amount: "10.99")
    end

    assert_response :unprocessable_entity
    assert_empty @stripe_calls
  end

  test "a Stripe rejection marks the payment failed and returns 422" do
    create_payment(error: Stripe::InvalidRequestError.new("Amount too small", "amount", code: "amount_too_small"))

    assert_response :unprocessable_entity
    assert_equal "Amount too small", response.parsed_body["error"]
    payment = Payment.sole
    assert payment.failed?
    assert_equal "amount_too_small", payment.failure_code
    assert AuditLog.exists?(action: "payment.failed", auditable_type: "Payment", auditable_id: payment.id)
  end

  test "an unknown Stripe outcome marks the payment failed and returns 503 so the client retries" do
    create_payment(error: Stripe::APIConnectionError.new("read timeout"))

    assert_response :service_unavailable
    assert_match(/try again/, response.parsed_body["error"])
    payment = Payment.sole
    assert payment.failed?
    assert_equal "provider_unavailable", payment.failure_code
  end

  # --- payments#create_refund (M12, M14) ---

  test "the same Idempotency-Key returns the original refund instead of creating another" do
    payment = succeeded_payment

    create_refund(payment, headers: { "Idempotency-Key" => "rf-1" })
    first_id = response.parsed_body["id"]

    assert_no_difference -> { Refund.count } do
      create_refund(payment, headers: { "Idempotency-Key" => "rf-1" })
    end

    assert_response :created
    assert_equal first_id, response.parsed_body["id"]
    assert_equal 1, @stripe_calls.size
  end

  test "reusing a refund Idempotency-Key with a different amount is rejected" do
    payment = succeeded_payment
    create_refund(payment, headers: { "Idempotency-Key" => "rf-2" })

    create_refund(payment, amount: 100, headers: { "Idempotency-Key" => "rf-2" })

    assert_response :unprocessable_entity
    assert_equal 1, payment.refunds.count
  end

  test "a decimal refund amount is rejected" do
    payment = succeeded_payment

    create_refund(payment, amount: "1.5")

    assert_response :unprocessable_entity
    assert_equal 0, payment.refunds.count
  end
end
