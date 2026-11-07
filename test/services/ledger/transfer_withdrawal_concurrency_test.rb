require "test_helper"

# A withdrawal and a transfer from the same wallet at the same moment must not
# spend the same money twice. Uses committed data and separate connections,
# so it runs outside a test transaction and cleans up after itself.
class Ledger::TransferWithdrawalConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @alice = users(:alice)
    Ledger::Deposit.call(wallet: wallets(:alice_usd), amount: 1_000, reference: "TEST-FUND-ALICE")
  end

  teardown do
    AuditLog.delete_all
    Withdrawal.delete_all
    LedgerEntry.delete_all
    Transaction.delete_all
  end

  test "a transfer during a withdrawal can't spend the withdrawn funds" do
    withdrawal_checked_balance = Queue.new

    # Pause the withdrawal after its balance check, while its lock is held.
    slow_create = lambda do |original, *args, **kwargs|
      if Thread.current[:pause_in_withdrawal]
        withdrawal_checked_balance << true
        sleep 0.5
      end
      original.call(*args, **kwargs)
    end
    no_stripe = ->(_original, **) { nil }

    transfer_error = nil

    with_class_method(Withdrawals::CreateProviderWithdrawal, :call, no_stripe) do
      with_class_method(Withdrawal, :create!, slow_create) do
        withdrawal_thread = Thread.new do
          Thread.current[:pause_in_withdrawal] = true
          ActiveRecord::Base.connection_pool.with_connection do
            Withdrawals::CreateWithdrawal.call(user: @alice, wallet: Wallet.find(wallets(:alice_usd).id), amount: 800)
          end
        end

        withdrawal_checked_balance.pop

        transfer_thread = Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            Ledger::Transfer.call(
              from_wallet: Wallet.find(wallets(:alice_usd).id),
              to_wallet: Wallet.find(wallets(:bob_usd).id),
              amount: 300,
              reference: SecureRandom.uuid
            )
          end
        rescue ArgumentError => e
          transfer_error = e
        end

        withdrawal_thread.join
        transfer_thread.join
      end
    end

    assert_kind_of ArgumentError, transfer_error, "the transfer should be rejected"
    assert_equal 1_000, accounts(:alice_usd).reload.balance
    assert_equal 200, Wallet.find(wallets(:alice_usd).id).available_balance
  end
end
