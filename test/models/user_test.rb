require "test_helper"

class UserTest < ActiveSupport::TestCase
  test "emails are stored stripped and downcased" do
    user = User.create!(email: "  Dave@Example.COM ", password: "password123")

    assert_equal "dave@example.com", user.email
  end

  # L4: the association was singular (has_many :idempotency_key).
  test "a user's idempotency keys are listed" do
    Ledger::Deposit.call(wallet: wallets(:alice_usd), amount: 1_000, reference: "TEST-FUND-ALICE")
    Ledger::IdempotentTransfer.call(
      user: users(:alice), from_wallet: wallets(:alice_usd), to_wallet: wallets(:bob_usd),
      amount: 100, idempotency_key: "key-l4"
    )

    assert_equal [ "key-l4" ], users(:alice).idempotency_keys.pluck(:key)
  end
end
