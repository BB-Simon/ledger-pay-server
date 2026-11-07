require "test_helper"

# Real concurrency needs committed data visible to several DB connections,
# so this class doesn't wrap each test in a transaction. Teardown removes
# every row the tests create (these tables have no fixture rows).
class Ledger::IdempotentTransferConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @alice = users(:alice)

    Ledger::Deposit.call(
      wallet: wallets(:alice_usd),
      amount: 1_000,
      reference: "TEST-FUND-ALICE"
    )
  end

  teardown do
    AuditLog.delete_all
    IdempotencyKey.delete_all
    LedgerEntry.delete_all
    Transaction.delete_all
  end

  def transfer(amount: 300, key: "same-key")
    ActiveRecord::Base.connection_pool.with_connection do
      Ledger::IdempotentTransfer.call(
        user: @alice,
        from_wallet: Wallet.find(wallets(:alice_usd).id),
        to_wallet: Wallet.find(wallets(:bob_usd).id),
        amount: amount,
        idempotency_key: key
      )
    end
  end

  test "two simultaneous requests with the same key move money once" do
    first_in_transfer = Queue.new

    # The first request pauses inside the transfer, after its key exists but
    # before the transfer is linked to the key. The second request arrives then.
    slow_first_transfer = lambda do |original, **kwargs|
      if Thread.current[:pause_in_transfer]
        first_in_transfer << true
        sleep 0.5
      end
      original.call(**kwargs)
    end

    results = with_class_method(Ledger::Transfer, :call, slow_first_transfer) do
      first = Thread.new do
        Thread.current[:pause_in_transfer] = true
        transfer
      end

      first_in_transfer.pop
      second = Thread.new { transfer }

      [ first.value, second.value ]
    end

    assert_equal results[0].id, results[1].id
    assert_equal 1, Transaction.where(transaction_type: :transfer).count
    assert_equal 700, accounts(:alice_usd).reload.balance
    assert_equal 300, accounts(:bob_usd).reload.balance
  end

  test "a failure after the transfer keeps neither the money movement nor the key" do
    failing_audit = ->(_original, **) { raise ActiveRecord::ConnectionFailed, "audit log write failed" }

    with_class_method(AuditLogs::Record, :call, failing_audit) do
      assert_raises(ActiveRecord::ConnectionFailed) { transfer }
    end

    assert_equal 1_000, accounts(:alice_usd).reload.balance
    assert_equal 0, IdempotencyKey.count

    # The client retries with the same key once things recover.
    transfer
    assert_equal 700, accounts(:alice_usd).reload.balance
    assert_equal 1, Transaction.where(transaction_type: :transfer).count
  end
end
