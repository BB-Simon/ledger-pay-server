require "test_helper"

# Bug H12: posted ledger entries can't be changed or removed through
# ActiveRecord. Mistakes are fixed with a new compensating transaction.
class LedgerEntryTest < ActiveSupport::TestCase
  setup do
    @transaction = Ledger::Deposit.call(wallet: wallets(:alice_usd), amount: 1_000, reference: "TEST-FUND-ALICE")
    @entry = @transaction.ledger_entries.first
  end

  test "posting creates entries normally" do
    assert_equal 2, @transaction.ledger_entries.count
    assert_equal 1_000, accounts(:alice_usd).reload.balance
  end

  test "a posted entry can't be updated" do
    assert_raises(ActiveRecord::ReadOnlyRecord) { @entry.update!(amount: 1) }
    assert_raises(ActiveRecord::ReadOnlyRecord) { @entry.update_column(:amount, 1) }

    assert_equal 1_000, @entry.reload.amount
  end

  test "a posted entry can't be destroyed" do
    assert_raises(ActiveRecord::ReadOnlyRecord) { @entry.destroy }

    assert LedgerEntry.exists?(@entry.id)
    assert_equal 1_000, accounts(:alice_usd).reload.balance
  end

  test "an entry loaded fresh from the database is also read-only" do
    entry = LedgerEntry.find(@entry.id)

    assert entry.readonly?
    assert_raises(ActiveRecord::ReadOnlyRecord) { entry.update!(entry_type: :credit) }
  end
end
