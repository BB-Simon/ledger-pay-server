require "test_helper"

# Refund and payout status events (bugs H1–H3).
class Payments::ProcessStripeWebhookTest < ActiveSupport::TestCase
  setup do
    @user = users(:alice)
    @wallet = wallets(:alice_usd)
    Ledger::Deposit.call(wallet: @wallet, amount: 1_000, reference: "TEST-FUND-ALICE")
  end

  def process(type, object)
    event = Stripe::Event.construct_from(id: "evt_#{SecureRandom.hex(8)}", type: type, data: { object: object })
    Payments::ProcessStripeWebhook.call(event: event)
  end

  def audit_log(action, record)
    AuditLog.find_by!(action: action, auditable_type: record.class.name, auditable_id: record.id)
  end

  # --- Refunds (H1) ---

  def pending_refund
    payment = Payment.create!(
      user: @user, wallet: @wallet, currency: currencies(:usd), amount: 1_000,
      provider: "stripe", provider_payment_id: "pi_h1", status: :succeeded
    )
    payment.refunds.create!(amount: 400, provider: "stripe", provider_refund_id: "re_h1", status: :pending)
  end

  def stripe_refund(refund, status)
    { id: "re_h1", object: "refund", amount: 400, currency: "usd", status: status, metadata: { refund_id: refund.id.to_s } }
  end

  test "refund.updated with status failed marks the refund failed" do
    refund = pending_refund

    process("refund.updated", stripe_refund(refund, "failed"))

    assert refund.reload.failed?
    assert_equal @user, audit_log("refund.failed", refund).user
  end

  test "refund.failed marks the refund failed" do
    refund = pending_refund

    process("refund.failed", stripe_refund(refund, "failed"))

    assert refund.reload.failed?
    assert_equal @user, audit_log("refund.failed", refund).user
  end

  test "a failed refund doesn't post to the ledger" do
    refund = pending_refund

    assert_no_difference -> { LedgerEntry.count } do
      process("refund.updated", stripe_refund(refund, "failed"))
    end
  end

  # --- Payouts (H2, H3) ---

  def pending_withdrawal
    Withdrawal.create!(
      user: @user, wallet: @wallet, currency: currencies(:usd), amount: 400,
      provider: "stripe", provider_withdrawal_id: "po_h2", status: :pending
    )
  end

  def payout(withdrawal, status, **extra)
    { id: "po_h2", object: "payout", amount: 400, currency: "usd", status: status,
      metadata: { withdrawal_id: withdrawal.id.to_s } }.merge(extra)
  end

  test "payout.canceled marks the withdrawal canceled and releases the hold" do
    withdrawal = pending_withdrawal

    process("payout.canceled", payout(withdrawal, "canceled"))

    assert withdrawal.reload.canceled?
    assert_equal 1_000, Wallet.find(@wallet.id).available_balance
    assert_equal @user, audit_log("withdrawal.canceled", withdrawal).user
  end

  test "payout.paid records the user on the audit log" do
    withdrawal = pending_withdrawal

    process("payout.paid", payout(withdrawal, "paid"))

    assert withdrawal.reload.succeeded?
    assert_equal 600, accounts(:alice_usd).reload.balance
    assert_equal @user, audit_log("withdrawal.succeeded", withdrawal).user
  end

  test "payout.failed before payment records the user and Stripe's reason" do
    withdrawal = pending_withdrawal

    process("payout.failed", payout(withdrawal, "failed", failure_code: "account_closed", failure_message: "The bank account has been closed"))

    assert withdrawal.reload.failed?
    assert_equal "account_closed", withdrawal.failure_code
    assert_equal @user, audit_log("withdrawal.failed", withdrawal).user
  end

  test "a late payout.failed reverses the payout and records Stripe's reason" do
    withdrawal = pending_withdrawal
    process("payout.paid", payout(withdrawal, "paid"))

    process("payout.failed", payout(withdrawal, "failed", failure_code: "account_closed", failure_message: "The bank account has been closed"))

    assert withdrawal.reload.failed?
    assert_equal 1_000, accounts(:alice_usd).reload.balance
    reversed = audit_log("withdrawal.reversed", withdrawal)
    assert_equal @user, reversed.user
    assert_equal "The bank account has been closed", reversed.metadata["reason"]
  end
end
