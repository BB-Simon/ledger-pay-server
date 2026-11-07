require "test_helper"

class Ledger::IdempotentTransferTest < ActiveSupport::TestCase
  setup do
    @alice = users(:alice)

    Ledger::Deposit.call(
      wallet: wallets(:alice_usd),
      amount: 1_000,
      reference: "TEST-FUND-ALICE"
    )
  end

  # Each call loads fresh Wallet objects, the way a separate HTTP request would.
  def transfer(amount:, key:, to: :bob_usd)
    Ledger::IdempotentTransfer.call(
      user: @alice,
      from_wallet: Wallet.find(wallets(:alice_usd).id),
      to_wallet: Wallet.find(wallets(to).id),
      amount: amount,
      idempotency_key: key
    )
  end

  test "retrying with the same key and same params returns the original transaction" do
    first = transfer(amount: 300, key: "key-1")

    assert_no_difference -> { Transaction.count } do
      retried = transfer(amount: 300, key: "key-1")
      assert_equal first.id, retried.id
    end

    assert_equal 700, accounts(:alice_usd).reload.balance
    assert_equal 300, accounts(:bob_usd).reload.balance
  end

  test "reusing a key with a different amount is rejected without moving money" do
    transfer(amount: 300, key: "key-2")

    error = assert_raises(ArgumentError) { transfer(amount: 400, key: "key-2") }
    assert_match(/different request hash/, error.message)

    assert_equal 700, accounts(:alice_usd).reload.balance
  end

  test "different keys create separate transfers" do
    transfer(amount: 100, key: "key-3")
    transfer(amount: 100, key: "key-4")

    assert_equal 800, accounts(:alice_usd).reload.balance
    assert_equal 200, accounts(:bob_usd).reload.balance
  end
end
