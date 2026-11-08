require "test_helper"

# Which records a reconciliation run checks (bug H10).
class Reconciliation::RunTest < ActiveSupport::TestCase
  setup do
    @user = users(:alice)
    @wallet = wallets(:alice_usd)
  end

  def withdrawal(status:, provider_withdrawal_id: "po_#{SecureRandom.hex(4)}", created_at: Time.current)
    Withdrawal.create!(
      user: @user, wallet: @wallet, currency: currencies(:usd), amount: 100, provider: "stripe",
      provider_withdrawal_id: provider_withdrawal_id, status: status, created_at: created_at
    )
  end

  def checked_ids(run)
    run.reconciliation_run_items.pluck(:internal_id)
  end

  test "checks recent records and older ones that are still pending" do
    recent = withdrawal(status: :succeeded)
    old_pending = withdrawal(status: :pending, created_at: 3.days.ago)
    old_settled = withdrawal(status: :succeeded, created_at: 3.days.ago)

    run = Reconciliation::Run.call(run_type: "payouts")

    assert_includes checked_ids(run), recent.id
    assert_includes checked_ids(run), old_pending.id
    assert_not_includes checked_ids(run), old_settled.id
  end

  test "includes pending records that never got a Stripe id once they're old enough" do
    stuck = withdrawal(status: :pending, provider_withdrawal_id: nil, created_at: 7.hours.ago)
    in_flight = withdrawal(status: :pending, provider_withdrawal_id: nil, created_at: 10.minutes.ago)
    failed_early = withdrawal(status: :failed, provider_withdrawal_id: nil, created_at: 7.hours.ago)

    run = Reconciliation::Run.call(run_type: "payouts")

    assert_includes checked_ids(run), stuck.id
    assert_not_includes checked_ids(run), in_flight.id, "a retry job may still be submitting it"
    assert_not_includes checked_ids(run), failed_early.id, "Stripe rejected it, so there's nothing to find"

    stuck_item = run.reconciliation_run_items.find_by!(internal_id: stuck.id)
    assert_nil stuck_item.provider_reference
    assert_includes Reconciliation::PayoutJob.jobs.map { |job| job["args"].first }, stuck_item.id
  end

  test "refund runs include old pending refunds and unsubmitted ones" do
    payment = Payment.create!(
      user: @user, wallet: @wallet, currency: currencies(:usd), amount: 1_000,
      provider: "stripe", provider_payment_id: "pi_run", status: :succeeded
    )
    old_pending = payment.refunds.create!(amount: 100, provider: "stripe", provider_refund_id: "re_old", status: :pending, created_at: 3.days.ago)
    unsubmitted = payment.refunds.create!(amount: 100, provider: "stripe", provider_refund_id: nil, status: :pending, created_at: 7.hours.ago)

    run = Reconciliation::Run.call(run_type: "refunds")

    assert_equal [ old_pending.id, unsubmitted.id ].sort, checked_ids(run).sort
  end
end
