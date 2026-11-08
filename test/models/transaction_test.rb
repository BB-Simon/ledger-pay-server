require "test_helper"

# Bug H12: posted ledger transactions can't be changed or removed through
# ActiveRecord. Mistakes are fixed with a new compensating transaction.
class TransactionTest < ActiveSupport::TestCase
  setup do
    @transaction = Ledger::Deposit.call(wallet: wallets(:alice_usd), amount: 1_000, reference: "TEST-FUND-ALICE")
  end

  test "a posted transaction can't be updated" do
    assert_raises(ActiveRecord::ReadOnlyRecord) { @transaction.update!(reference: "EDITED") }
    assert_raises(ActiveRecord::ReadOnlyRecord) { @transaction.update!(status: :reversed) }

    assert_equal "TEST-FUND-ALICE", Transaction.find(@transaction.id).reference
  end

  test "a posted transaction can't be destroyed" do
    assert_raises(ActiveRecord::ReadOnlyRecord) { Transaction.find(@transaction.id).destroy }

    assert Transaction.exists?(@transaction.id)
  end

  test "a transfer's idempotency key is found from its transaction" do
    transfer = Ledger::IdempotentTransfer.call(
      user: users(:alice), from_wallet: wallets(:alice_usd), to_wallet: wallets(:bob_usd),
      amount: 100, idempotency_key: "key-h12"
    )

    assert_equal "key-h12", Transaction.find(transfer.id).idempotency_key.key
  end

  test "a mistake is corrected with a compensating transaction instead" do
    withdrawal = Withdrawal.create!(
      user: users(:alice), wallet: wallets(:alice_usd), currency: currencies(:usd), amount: 400,
      provider: "stripe", provider_withdrawal_id: "po_h12", status: :succeeded
    )
    Ledger::Withdraw.call(withdrawal: withdrawal)

    reversal = Ledger::ReverseWithdrawal.call(withdrawal: withdrawal)

    assert reversal.reversal?
    assert_equal 1_000, accounts(:alice_usd).reload.balance
    assert_equal 3, Transaction.count
  end
end
