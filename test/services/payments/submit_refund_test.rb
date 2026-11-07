require "test_helper"

# Submitting a refund to Stripe must be safe to repeat (idempotency key), must
# release the hold only when Stripe definitely didn't refund, and must retry
# in the background when the outcome is unknown.
class Payments::SubmitRefundTest < ActiveSupport::TestCase
  setup do
    @wallet = wallets(:alice_usd)
    @stripe_calls = []

    @payment = Payment.create!(
      user: users(:alice), wallet: @wallet, currency: currencies(:usd), amount: 1_000,
      provider: "stripe", provider_payment_id: "pi_c5", status: :succeeded
    )
    Ledger::Deposit.call(wallet: @wallet, amount: 1_000, reference: "PAYMENT-#{@payment.id}")
  end

  # Stripe stub: records every call; raises `error` if given, else returns a refund.
  def stripe_refund_create(error: nil)
    lambda do |_original, params, opts = {}|
      @stripe_calls << { params: params, opts: opts }
      raise error if error
      Stripe::Refund.construct_from(id: "re_c5", amount: params[:amount], status: "pending")
    end
  end

  def create_refund(error: nil, amount: 400)
    with_class_method(Stripe::Refund, :create, stripe_refund_create(error: error)) do
      Payments::CreateRefund.call(payment: @payment, amount: amount, reason: "requested_by_customer")
    end
  end

  def available
    Wallet.find(@wallet.id).available_balance
  end

  test "sends an idempotency key tied to the local refund" do
    refund = create_refund[:refund]

    assert_equal "refund-#{refund.id}", @stripe_calls.sole[:opts][:idempotency_key]
    assert_equal "re_c5", refund.reload.provider_refund_id
  end

  test "a definite Stripe rejection marks the refund failed and releases the hold" do
    rejection = Stripe::InvalidRequestError.new("Charge has already been refunded", "charge")

    assert_raises(Stripe::InvalidRequestError) { create_refund(error: rejection) }

    refund = @payment.refunds.sole
    assert refund.failed?
    assert_equal 1_000, available
    assert AuditLog.exists?(action: "refund.failed", auditable_type: "Refund", auditable_id: refund.id)
    assert_empty Payments::SubmitRefundJob.jobs
  end

  test "an unknown outcome keeps the refund pending and schedules a retry" do
    result = create_refund(error: Stripe::APIConnectionError.new("read timeout"))

    refund = result[:refund].reload
    assert refund.pending?
    assert_nil refund.provider_refund_id
    assert_equal 600, available, "the hold stays because Stripe may have refunded"
    assert_equal [ refund.id ], Payments::SubmitRefundJob.jobs.sole["args"]
  end

  test "the retry job resubmits with the same idempotency key and stores the Stripe id" do
    refund = create_refund(error: Stripe::APIConnectionError.new("read timeout"))[:refund]

    with_class_method(Stripe::Refund, :create, stripe_refund_create) do
      Payments::SubmitRefundJob.new.perform(refund.id)
    end

    assert_equal [ "refund-#{refund.id}" ] * 2, @stripe_calls.map { |c| c[:opts][:idempotency_key] }
    assert_equal "re_c5", refund.reload.provider_refund_id
    assert refund.pending?, "the webhook decides success, not the submission"
  end

  test "the retry job marks the refund failed on a definite rejection, without raising" do
    refund = create_refund(error: Stripe::APIConnectionError.new("read timeout"))[:refund]
    rejection = Stripe::InvalidRequestError.new("No such payment_intent", "payment_intent")

    with_class_method(Stripe::Refund, :create, stripe_refund_create(error: rejection)) do
      Payments::SubmitRefundJob.new.perform(refund.id)
    end

    assert refund.reload.failed?
    assert_equal 1_000, available
  end

  test "the retry job lets an unknown outcome raise so Sidekiq retries it" do
    refund = create_refund(error: Stripe::APIConnectionError.new("read timeout"))[:refund]

    with_class_method(Stripe::Refund, :create, stripe_refund_create(error: Stripe::APIError.new("500"))) do
      assert_raises(Stripe::APIError) { Payments::SubmitRefundJob.new.perform(refund.id) }
    end

    assert refund.reload.pending?
  end

  test "the retry job does nothing for a refund that's already submitted" do
    refund = create_refund[:refund]

    with_class_method(Stripe::Refund, :create, stripe_refund_create) do
      Payments::SubmitRefundJob.new.perform(refund.id)
    end

    assert_equal 1, @stripe_calls.size
  end

  test "when retries run out the refund stays pending and is flagged for a person" do
    refund = create_refund(error: Stripe::APIConnectionError.new("read timeout"))[:refund]

    Payments::SubmitRefundJob.sidekiq_retries_exhausted_block.call(
      { "args" => [ refund.id ] }, Stripe::APIConnectionError.new("read timeout")
    )

    assert refund.reload.pending?
    assert AuditLog.exists?(action: "refund.submission_stuck", auditable_type: "Refund", auditable_id: refund.id)
  end
end
