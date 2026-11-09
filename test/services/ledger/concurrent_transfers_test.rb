require "test_helper"

# Simultaneous transfers from one wallet, with different idempotency keys,
# must never spend more than the wallet holds. Uses committed data and one DB
# connection per thread, so it runs outside a test transaction and cleans up.
class Ledger::ConcurrentTransfersTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @alice = users(:alice)
    Ledger::Deposit.call(wallet: wallets(:alice_usd), amount: 1_000, reference: "TEST-FUND-ALICE")
  end

  teardown do
    AuditLog.delete_all
    IdempotencyKey.delete_all
    LedgerEntry.delete_all
    Transaction.delete_all
  end

  # Returns a thread whose value is :ok, or the ArgumentError the transfer
  # raised. `pause:` marks this thread for the slow-posting stub below.
  def transfer_in_thread(amount, key, pause: false)
    Thread.new do
      Thread.current[:pause_after_balance_check] = pause
      ActiveRecord::Base.connection_pool.with_connection do
        Ledger::IdempotentTransfer.call(
          user: @alice,
          from_wallet: Wallet.find(wallets(:alice_usd).id),
          to_wallet: Wallet.find(wallets(:bob_usd).id),
          amount: amount,
          idempotency_key: key
        )
        :ok
      end
    rescue ArgumentError => e
      e
    end
  end

  test "two simultaneous transfers can't both spend the same money" do
    first_checked_balance = Queue.new

    # The first transfer pauses after its balance check, while it holds the
    # account lock, so the second one arrives in exactly the dangerous window.
    slow_post = lambda do |original, **kwargs|
      if Thread.current[:pause_after_balance_check]
        first_checked_balance << true
        sleep 0.5
      end
      original.call(**kwargs)
    end

    results = with_class_method(Ledger::PostTransaction, :call, slow_post) do
      first = transfer_in_thread(700, "first", pause: true)
      first_checked_balance.pop
      second = transfer_in_thread(700, "second")

      [ first.value, second.value ]
    end

    assert_equal :ok, results[0]
    assert_kind_of ArgumentError, results[1]
    assert_match(/Insufficient balance/, results[1].message)

    assert_equal 300, balance_of(:alice_usd)
    assert_equal 700, balance_of(:bob_usd)
    assert_ledger_balanced
  end

  test "many simultaneous transfers move exactly what the wallet can cover" do
    ActiveRecord::Base.connection_pool.release_connection # leave the pool to the threads

    results = 4.times.map { |i| transfer_in_thread(300, "burst-#{i}") }.map(&:value)

    assert_equal 3, results.count(:ok), "1,000 covers three transfers of 300"
    assert_equal 1, results.count { |result| result.is_a?(ArgumentError) }
    assert_equal 100, balance_of(:alice_usd)
    assert_equal 900, balance_of(:bob_usd)
    assert_operator balance_of(:alice_usd), :>=, 0
    assert_ledger_balanced
  end
end
