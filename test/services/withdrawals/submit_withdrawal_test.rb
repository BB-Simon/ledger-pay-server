require "test_helper"

# Sending a payout to Stripe must release the hold only when Stripe definitely
# didn't create it, and retry in the background when the outcome is unknown.
class Withdrawals::SubmitWithdrawalTest < ActiveSupport::TestCase
  setup do
    @user = users(:alice)
    @wallet = wallets(:alice_usd)
    @stripe_calls = []

    Ledger::Deposit.call(wallet: @wallet, amount: 1_000, reference: "TEST-FUND-ALICE")
  end

  # Stripe stub: records every call; raises `error` if given, else returns a payout.
  def stripe_payout_create(error: nil)
    lambda do |_original, params, opts = {}|
      @stripe_calls << { params: params, opts: opts }
      raise error if error
      Stripe::Payout.construct_from(id: "po_c6", amount: params[:amount], status: "pending")
    end
  end

  def create_withdrawal(error: nil, amount: 400)
    with_class_method(Stripe::Payout, :create, stripe_payout_create(error: error)) do
      Withdrawals::CreateWithdrawal.call(user: @user, wallet: Wallet.find(@wallet.id), amount: amount)
    end
  end

  def available
    Wallet.find(@wallet.id).available_balance
  end

  def timeout
    Stripe::APIConnectionError.new("read timeout")
  end

  test "sends an idempotency key tied to the local withdrawal" do
    withdrawal = create_withdrawal

    assert_equal "withdrawal-#{withdrawal.id}", @stripe_calls.sole[:opts][:idempotency_key]
    assert_equal "po_c6", withdrawal.provider_withdrawal_id
    assert withdrawal.pending?
  end

  test "a definite Stripe rejection marks the withdrawal failed and releases the hold" do
    rejection = Stripe::InvalidRequestError.new("Insufficient funds in Stripe balance", "amount", code: "balance_insufficient")

    assert_raises(Stripe::InvalidRequestError) { create_withdrawal(error: rejection) }

    withdrawal = @wallet.withdrawals.sole
    assert withdrawal.failed?
    assert_equal "balance_insufficient", withdrawal.failure_code
    assert_equal 1_000, available
    assert AuditLog.exists?(action: "withdrawal.failed", auditable_type: "Withdrawal", auditable_id: withdrawal.id)
    assert_empty Withdrawals::SubmitWithdrawalJob.jobs
  end

  test "an unknown outcome keeps the withdrawal pending and schedules a retry" do
    withdrawal = create_withdrawal(error: timeout)

    assert withdrawal.pending?
    assert_nil withdrawal.provider_withdrawal_id
    assert_equal 600, available, "the hold stays because Stripe may have created the payout"
    assert_equal [ withdrawal.id ], Withdrawals::SubmitWithdrawalJob.jobs.sole["args"]
  end

  test "the retry job resubmits with the same idempotency key and stores the Stripe id" do
    withdrawal = create_withdrawal(error: timeout)

    with_class_method(Stripe::Payout, :create, stripe_payout_create) do
      Withdrawals::SubmitWithdrawalJob.new.perform(withdrawal.id)
    end

    assert_equal [ "withdrawal-#{withdrawal.id}" ] * 2, @stripe_calls.map { |c| c[:opts][:idempotency_key] }
    assert_equal "po_c6", withdrawal.reload.provider_withdrawal_id
    assert withdrawal.pending?, "the payout webhook decides success, not the submission"
  end

  test "the retry job marks the withdrawal failed on a definite rejection, without raising" do
    withdrawal = create_withdrawal(error: timeout)
    rejection = Stripe::InvalidRequestError.new("No external account", "destination")

    with_class_method(Stripe::Payout, :create, stripe_payout_create(error: rejection)) do
      Withdrawals::SubmitWithdrawalJob.new.perform(withdrawal.id)
    end

    assert withdrawal.reload.failed?
    assert_equal 1_000, available
  end

  test "the retry job lets an unknown outcome raise so Sidekiq retries it" do
    withdrawal = create_withdrawal(error: timeout)

    with_class_method(Stripe::Payout, :create, stripe_payout_create(error: Stripe::APIError.new("500"))) do
      assert_raises(Stripe::APIError) { Withdrawals::SubmitWithdrawalJob.new.perform(withdrawal.id) }
    end

    assert withdrawal.reload.pending?
  end

  test "the retry job does nothing for a withdrawal that's already submitted or settled" do
    submitted = create_withdrawal
    settled = create_withdrawal(error: timeout, amount: 100)
    settled.update!(status: :canceled)

    with_class_method(Stripe::Payout, :create, stripe_payout_create) do
      Withdrawals::SubmitWithdrawalJob.new.perform(submitted.id)
      Withdrawals::SubmitWithdrawalJob.new.perform(settled.id)
    end

    assert_equal 2, @stripe_calls.size, "only the two original submissions"
  end

  test "when retries run out the withdrawal stays pending and is flagged for a person" do
    withdrawal = create_withdrawal(error: timeout)

    Withdrawals::SubmitWithdrawalJob.sidekiq_retries_exhausted_block.call({ "args" => [ withdrawal.id ] }, timeout)

    assert withdrawal.reload.pending?
    assert AuditLog.exists?(action: "withdrawal.submission_stuck", auditable_type: "Withdrawal", auditable_id: withdrawal.id)
  end
end
