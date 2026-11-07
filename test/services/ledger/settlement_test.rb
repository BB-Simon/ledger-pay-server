require "test_helper"

# Ledger::Refund and Ledger::Withdraw record money that has already left at
# Stripe. They must always post, even if the wallet balance is too low, and
# flag the shortfall instead of refusing.
class Ledger::SettlementTest < ActiveSupport::TestCase
  setup do
    @wallet = wallets(:alice_usd)
    @account = accounts(:alice_usd)
  end

  def fund(amount)
    Ledger::Deposit.call(wallet: @wallet, amount: amount, reference: "TEST-FUND-#{SecureRandom.hex(4)}")
  end

  def succeeded_refund(amount, payment_amount: 1_000)
    payment = Payment.create!(
      user: users(:alice), wallet: @wallet, currency: currencies(:usd), amount: payment_amount,
      provider: "stripe", provider_payment_id: "pi_#{SecureRandom.hex(4)}", status: :succeeded
    )
    payment.refunds.create!(amount: amount, provider: "stripe", provider_refund_id: "re_#{SecureRandom.hex(4)}", status: :succeeded)
  end

  def succeeded_withdrawal(amount)
    Withdrawal.create!(
      user: users(:alice), wallet: @wallet, currency: currencies(:usd), amount: amount,
      provider: "stripe", provider_withdrawal_id: "po_#{SecureRandom.hex(4)}", status: :succeeded
    )
  end

  def negative_balance_logs
    AuditLog.where(action: "account.negative_balance", auditable_type: "Account", auditable_id: @account.id)
  end

  test "a refund posts normally when the wallet covers it" do
    fund(1_000)

    Ledger::Refund.call(refund: succeeded_refund(400))

    assert_equal 600, @account.reload.balance
    assert_equal 0, negative_balance_logs.count
  end

  test "a refund Stripe already paid posts even when the wallet can't cover it, and is flagged" do
    fund(300)
    refund = succeeded_refund(500)

    assert_difference -> { LedgerEntry.count }, 2 do
      Ledger::Refund.call(refund: refund)
    end

    assert_equal(-200, @account.reload.balance)
    log = negative_balance_logs.sole
    assert_equal "REFUND-#{refund.id}", log.metadata["reference"]
    assert_equal(-200, log.metadata["balance"])
  end

  test "a payout Stripe already paid posts even when the wallet can't cover it, and is flagged" do
    fund(300)
    withdrawal = succeeded_withdrawal(500)

    Ledger::Withdraw.call(withdrawal: withdrawal)

    assert_equal(-200, @account.reload.balance)
    assert_equal "WITHDRAWAL-#{withdrawal.id}", negative_balance_logs.sole.metadata["reference"]
  end
end
