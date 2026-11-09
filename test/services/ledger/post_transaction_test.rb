require "test_helper"

# Ledger::PostTransaction is the only writer of ledger entries, so it is the
# last line of defence for the double-entry rules. Each rejected posting must
# leave no transaction and no entries behind.
class Ledger::PostTransactionTest < ActiveSupport::TestCase
  setup do
    @wallet = accounts(:alice_usd)
    @clearing = accounts(:stripe_clearing_usd)
  end

  def post(entries, currency: currencies(:usd), reference: "TEST-#{SecureRandom.hex(4)}")
    Ledger::PostTransaction.call(reference: reference, transaction_type: :deposit, currency: currency, entries: entries)
  end

  def entry(account, type, amount)
    { account: account, entry_type: type, amount: amount }
  end

  def assert_rejected(message, entries, **options)
    assert_no_difference [ -> { Transaction.count }, -> { LedgerEntry.count } ] do
      error = assert_raises(ArgumentError) { post(entries, **options) }
      assert_match message, error.message
    end
  end

  test "posts a balanced transaction" do
    transaction = post([ entry(@clearing, :debit, 500), entry(@wallet, :credit, 500) ])

    assert transaction.posted?
    assert_equal 2, transaction.ledger_entries.count
    assert_equal 500, @wallet.reload.balance
    assert_ledger_balanced
  end

  test "posts a balanced transaction with more than two entries" do
    post([ entry(@clearing, :debit, 500), entry(@wallet, :credit, 300), entry(accounts(:bob_usd), :credit, 200) ])

    assert_equal 300, @wallet.reload.balance
    assert_equal 200, accounts(:bob_usd).reload.balance
    assert_ledger_balanced
  end

  test "rejects debits that don't equal credits" do
    assert_rejected(/not balanced/, [ entry(@clearing, :debit, 500), entry(@wallet, :credit, 499) ])
  end

  test "rejects a single entry" do
    assert_rejected(/At least two entries/, [ entry(@wallet, :credit, 500) ])
  end

  test "rejects zero, negative and non-integer amounts" do
    [ 0, -500, 5.5 ].each do |amount|
      assert_rejected(/positive integer/, [ entry(@clearing, :debit, amount), entry(@wallet, :credit, amount) ])
    end
  end

  test "rejects an unknown entry type" do
    assert_rejected(/Invalid entry type/, [ entry(@clearing, :debit, 500), entry(@wallet, :refund, 500) ])
  end

  test "rejects an account that isn't active" do
    @wallet.update!(status: "frozen")

    assert_rejected(/must be active/, [ entry(@clearing, :debit, 500), entry(@wallet, :credit, 500) ])
  end

  test "rejects accounts in another currency" do
    eur = Currency.create!(code: "EUR", name: "Euro", decimal_places: 2)

    assert_rejected(/currency must match/, [ entry(@clearing, :debit, 500), entry(@wallet, :credit, 500) ], currency: eur)
  end

  test "a reference can only be posted once, so retries can't double-post" do
    post([ entry(@clearing, :debit, 500), entry(@wallet, :credit, 500) ], reference: "PAYMENT-1")

    assert_raises(ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique) do
      post([ entry(@clearing, :debit, 500), entry(@wallet, :credit, 500) ], reference: "PAYMENT-1")
    end
    assert_equal 500, @wallet.reload.balance
  end
end
