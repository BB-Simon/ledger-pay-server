require "test_helper"

class AccountTest < ActiveSupport::TestCase
  setup do
    Ledger::Deposit.call(wallet: wallets(:alice_usd), amount: 1_000, reference: "TEST-FUND-ALICE")
    Ledger::Transfer.call(from_wallet: wallets(:alice_usd), to_wallet: wallets(:bob_usd), amount: 300, reference: "TEST-TRANSFER")
  end

  test "a liability account grows with credits" do
    assert_equal 700, accounts(:alice_usd).balance
    assert_equal 300, accounts(:bob_usd).balance
  end

  test "an asset account grows with debits" do
    assert_equal 1_000, accounts(:stripe_clearing_usd).balance
  end

  test "an account with no entries has a zero balance" do
    assert_equal 0, accounts(:withdrawal_clearing_usd).balance
  end

  # M16: the balance is summed by the database, not by loading every entry.
  test "the balance doesn't load ledger entries into Ruby" do
    loaded = 0
    counter = ->(*, payload) { loaded += 1 if payload[:class_name] == "LedgerEntry" }

    ActiveSupport::Notifications.subscribed(counter, "instantiation.active_record") do
      accounts(:alice_usd).balance
    end

    assert_equal 0, loaded
  end

  # L6: WITHDRAWAL_CLEARING stays an asset, so payouts make it negative.
  test "withdrawal clearing goes negative by the amount paid out and back on reversal" do
    withdrawal = Withdrawal.create!(
      user: users(:alice), wallet: wallets(:alice_usd), currency: currencies(:usd), amount: 400,
      provider: "stripe", provider_withdrawal_id: "po_l6", status: :succeeded
    )
    clearing = accounts(:withdrawal_clearing_usd)

    Ledger::Withdraw.call(withdrawal: withdrawal)
    assert_equal(-400, clearing.balance)

    Ledger::ReverseWithdrawal.call(withdrawal: withdrawal)
    assert_equal 0, clearing.balance
  end
end
