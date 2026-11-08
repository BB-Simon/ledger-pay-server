require "test_helper"

# Per-item reconciliation jobs (bugs H8, H9, H10, and the missing
# ReconciliationRunItem#terminal?).
class Reconciliation::ItemJobsTest < ActiveSupport::TestCase
  setup do
    @user = users(:alice)
    @wallet = wallets(:alice_usd)
    @usd = currencies(:usd)
  end

  # --- builders ---

  def payment(status: :succeeded, provider_payment_id: "pi_rec", amount: 1_000)
    Payment.create!(
      user: @user, wallet: @wallet, currency: @usd, amount: amount,
      provider: "stripe", provider_payment_id: provider_payment_id, status: status
    )
  end

  def refund(status: :succeeded, provider_refund_id: "re_rec")
    payment(provider_payment_id: "pi_for_refund").refunds.create!(
      amount: 400, provider: "stripe", provider_refund_id: provider_refund_id, status: status
    )
  end

  def withdrawal(status: :succeeded, provider: "stripe", provider_withdrawal_id: "po_rec")
    Withdrawal.create!(
      user: @user, wallet: @wallet, currency: @usd, amount: 400,
      provider: provider, provider_withdrawal_id: provider_withdrawal_id, status: status
    )
  end

  def item_for(record, record_type)
    run = ReconciliationRun.create!(provider: "stripe", run_type: "#{record_type}s", status: :running, total_items: 1)
    reference = { "payment" => :provider_payment_id, "refund" => :provider_refund_id, "payout" => :provider_withdrawal_id }[record_type]
    run.reconciliation_run_items.create!(
      record_type: record_type, internal_type: record.class.name, internal_id: record.id,
      provider_reference: record.public_send(reference), status: :pending
    )
  end

  # Stubs Stripe's retrieve to return `attrs` (or raise `error`) and counts calls.
  def with_stripe(klass, error: nil, **attrs, &block)
    @stripe_calls = 0
    fake = lambda do |_original, id, *|
      @stripe_calls += 1
      raise error if error
      klass.construct_from({ id: id, currency: "usd" }.merge(attrs))
    end
    with_class_method(klass, :retrieve, fake, &block)
  end

  def record_for(item)
    ReconciliationResult.find_by!(reconciliation_run_id: item.reconciliation_run_id).reconciliation_record
  end

  # --- happy path (blocked by the missing #terminal?) ---

  test "a payment that matches Stripe completes the item and the run" do
    item = item_for(payment, "payment")

    with_stripe(Stripe::PaymentIntent, amount: 1_000, status: "succeeded") do
      Reconciliation::PaymentJob.new.perform(item.id)
    end

    assert item.reload.matched?
    assert record_for(item).matched?
    assert item.reconciliation_run.reload.completed?
  end

  test "an item that's already finished isn't reconciled again" do
    item = item_for(payment, "payment")
    item.update!(status: :matched, completed_at: Time.current)

    with_stripe(Stripe::PaymentIntent, amount: 1_000, status: "succeeded") do
      Reconciliation::PaymentJob.new.perform(item.id)
    end

    assert_equal 0, @stripe_calls
  end

  # --- H10: status comparison ---

  test "a payment that succeeded at Stripe but is pending locally is a status mismatch" do
    item = item_for(payment(status: :pending), "payment")

    with_stripe(Stripe::PaymentIntent, amount: 1_000, status: "succeeded") do
      Reconciliation::PaymentJob.new.perform(item.id)
    end

    assert item.reload.discrepancy?
    record = record_for(item)
    assert record.discrepancy_type_status_mismatch?
    assert_equal "succeeded", record.details["provider_status"]
    assert_equal "pending", record.details["internal_status"]
  end

  test "a payment that failed locally matches a Stripe intent waiting for a new payment method" do
    item = item_for(payment(status: :failed), "payment")

    with_stripe(Stripe::PaymentIntent, amount: 1_000, status: "requires_payment_method") do
      Reconciliation::PaymentJob.new.perform(item.id)
    end

    assert item.reload.matched?
  end

  test "a refund that succeeded at Stripe but is pending locally is a status mismatch" do
    item = item_for(refund(status: :pending), "refund")

    with_stripe(Stripe::Refund, amount: 400, status: "succeeded") do
      Reconciliation::RefundJob.new.perform(item.id)
    end

    assert item.reload.discrepancy?
    assert record_for(item).discrepancy_type_status_mismatch?
  end

  test "a payout paid at Stripe but failed locally is a status mismatch" do
    item = item_for(withdrawal(status: :failed), "payout")

    with_stripe(Stripe::Payout, amount: 400, status: "paid") do
      Reconciliation::PayoutJob.new.perform(item.id)
    end

    assert record_for(item).discrepancy_type_status_mismatch?
  end

  test "a payout in transit matches a pending withdrawal" do
    item = item_for(withdrawal(status: :pending), "payout")

    with_stripe(Stripe::Payout, amount: 400, status: "in_transit") do
      Reconciliation::PayoutJob.new.perform(item.id)
    end

    assert item.reload.matched?
  end

  test "an amount mismatch is still reported first" do
    item = item_for(withdrawal(status: :pending), "payout")

    with_stripe(Stripe::Payout, amount: 999, status: "paid") do
      Reconciliation::PayoutJob.new.perform(item.id)
    end

    record = record_for(item)
    assert record.discrepancy_type_amount_mismatch?
    assert_equal %w[amount_mismatch status_mismatch], record.details["discrepancies"]
  end

  # --- H10: Stripe doesn't have the object ---

  test "an object Stripe doesn't have is a missing_provider_record discrepancy, not a retry" do
    item = item_for(withdrawal, "payout")
    not_found = Stripe::InvalidRequestError.new("No such payout: 'po_rec'", "id", code: "resource_missing")

    with_stripe(Stripe::Payout, error: not_found) do
      Reconciliation::PayoutJob.new.perform(item.id)
    end

    assert item.reload.discrepancy?
    record = record_for(item)
    assert record.discrepancy_type_missing_provider_record?
    assert_equal "po_rec", record.provider_reference
    assert_equal 400, record.expected_amount
  end

  test "a temporary Stripe error raises for a retry and releases the item" do
    item = item_for(payment, "payment")

    with_stripe(Stripe::PaymentIntent, error: Stripe::APIConnectionError.new("timeout")) do
      assert_raises(Stripe::APIConnectionError) { Reconciliation::PaymentJob.new.perform(item.id) }
    end

    assert item.reload.pending?
    assert_nil item.started_at
  end

  # --- H9 / H10: records that can't be looked up at Stripe ---

  test "a refund that never got a Stripe id is a missing_provider_record discrepancy" do
    item = item_for(refund(status: :pending, provider_refund_id: nil), "refund")

    with_stripe(Stripe::Refund) do
      Reconciliation::RefundJob.new.perform(item.id)
    end

    assert_equal 0, @stripe_calls
    assert item.reload.discrepancy?
    record = record_for(item)
    assert record.discrepancy_type_missing_provider_record?
    assert_equal "refund-#{item.internal_id}", record.provider_reference
  end

  test "a withdrawal that isn't a Stripe payout fails the item instead of leaving it stuck" do
    item = item_for(withdrawal(provider: "manual"), "payout")

    with_stripe(Stripe::Payout) do
      Reconciliation::PayoutJob.new.perform(item.id)
    end

    assert_equal 0, @stripe_calls
    assert item.reload.failed?
    assert_match(/not a Stripe/, item.error_message)
    assert item.reconciliation_run.reload.failed?
  end

  # --- H8: retries exhausted ---

  {
    "payment" => Reconciliation::PaymentJob,
    "refund" => Reconciliation::RefundJob,
    "payout" => Reconciliation::PayoutJob
  }.each do |record_type, job_class|
    test "#{job_class.name.demodulize} marks the item failed when retries run out" do
      record = { "payment" => -> { payment }, "refund" => -> { refund }, "payout" => -> { withdrawal } }[record_type].call
      item = item_for(record, record_type)

      job_class.sidekiq_retries_exhausted_block.call({ "args" => [ item.id ] }, Stripe::APIConnectionError.new("timeout"))

      item.reload
      assert item.failed?
      assert_equal "Stripe::APIConnectionError", item.error_class
      run = item.reconciliation_run.reload
      assert run.failed?
      assert_equal 1, run.failed_count
    end
  end
end
