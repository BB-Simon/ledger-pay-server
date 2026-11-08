require "test_helper"

class Ledger::TransferTest < ActiveSupport::TestCase
  setup do
    @alice_wallet = wallets(:alice_usd)
    @bob_wallet = wallets(:bob_usd)

    Ledger::Deposit.call(wallet: @alice_wallet, amount: 1_000, reference: "TEST-FUND-ALICE")
  end

  def transfer(amount)
    Ledger::Transfer.call(
      from_wallet: Wallet.find(@alice_wallet.id),
      to_wallet: Wallet.find(@bob_wallet.id),
      amount: amount,
      reference: SecureRandom.uuid
    )
  end

  def hold_for_pending_withdrawal(amount)
    Withdrawal.create!(
      user: users(:alice), wallet: @alice_wallet, currency: currencies(:usd),
      amount: amount, provider: "stripe", status: :pending
    )
  end

  test "moves the amount from sender to recipient with balanced entries" do
    transaction = transfer(300)

    assert_equal 700, accounts(:alice_usd).reload.balance
    assert_equal 300, accounts(:bob_usd).reload.balance

    entries = transaction.ledger_entries
    assert_equal entries.select(&:debit?).sum(&:amount), entries.select(&:credit?).sum(&:amount)
  end

  test "rejects a transfer that exceeds the balance without changing anything" do
    assert_no_difference -> { LedgerEntry.count } do
      assert_raises(ArgumentError) { transfer(1_001) }
    end

    assert_equal 1_000, accounts(:alice_usd).reload.balance
  end

  test "cannot spend money held by a pending withdrawal" do
    hold_for_pending_withdrawal(800)

    assert_no_difference -> { LedgerEntry.count } do
      error = assert_raises(ArgumentError) { transfer(300) }
      assert_match(/Insufficient balance/, error.message)
    end

    assert_equal 1_000, accounts(:alice_usd).reload.balance
  end

  test "can spend the part of the balance that isn't held" do
    hold_for_pending_withdrawal(800)

    transfer(200)

    assert_equal 0, Wallet.find(@alice_wallet.id).available_balance
  end

  test "funds are released for spending once the withdrawal fails" do
    hold_for_pending_withdrawal(800).update!(status: :failed)

    transfer(1_000)

    assert_equal 0, accounts(:alice_usd).reload.balance
  end

  # M11
  test "a frozen sending wallet can't transfer" do
    @alice_wallet.update!(status: "frozen")

    error = assert_raises(ArgumentError) { transfer(100) }
    assert_equal "Source wallet must be active", error.message
  end

  test "a frozen receiving wallet can't receive" do
    @bob_wallet.update!(status: "frozen")

    error = assert_raises(ArgumentError) { transfer(100) }
    assert_equal "Destination wallet must be active", error.message
    assert_equal 1_000, accounts(:alice_usd).reload.balance
  end
end
