require "test_helper"

class WalletTest < ActiveSupport::TestCase
  test "available balance subtracts pending withdrawals" do
    Ledger::Deposit.call(wallet: wallets(:alice_usd), amount: 1_000, reference: "TEST-FUND-ALICE")
    Withdrawal.create!(user: users(:alice), wallet: wallets(:alice_usd), currency: currencies(:usd),
      amount: 300, provider: "stripe", status: :pending)

    assert_equal 700, wallets(:alice_usd).available_balance
  end

  # M17
  test "a wallet without a ledger account raises a clear error" do
    wallet = Wallet.create!(user: users(:admin), currency: currencies(:usd), status: "active")

    error = assert_raises(ArgumentError) { wallet.available_balance }
    assert_equal "Wallet account is required", error.message
  end
end
