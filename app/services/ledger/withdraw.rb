module Ledger
  class Withdraw
    def self.call(withdrawal:)
      new(withdrawal: withdrawal).call
    end

    def initialize(withdrawal:)
      @withdrawal = withdrawal
    end

    def call
      validate!

      Ledger::PostTransaction.call(
        reference: "WITHDRAWAL-#{@withdrawal.id}",
        transaction_type: :withdrawal,
        currency: @withdrawal.currency,
        entries: [
          {
            account: @withdrawal.wallet.account,
            entry_type: :debit,
            amount: @withdrawal.amount
          },
          {
            account: clearing_account,
            entry_type: :credit,
            amount: @withdrawal.amount
          }
        ]
      )
    end

    private

    def validate!
      raise ArgumentError, "Withdrawal must be succeeded" unless
        @withdrawal.succeeded?

      raise ArgumentError, "Wallet must be active" unless
        @withdrawal.wallet.status == "active"

      raise ArgumentError, "Wallet account is required" unless
        @withdrawal.wallet.account

      raise ArgumentError, "Currency mismatch" unless
        @withdrawal.wallet.currency_id == @withdrawal.currency_id

      raise ArgumentError, "Insufficient wallet balance" unless
        @withdrawal.wallet.account.balance >= @withdrawal.amount
    end

    def clearing_account
      Account.find_by!(
        code: "WITHDRAWAL_CLEARING_#{@withdrawal.currency.code}"
      )
    end
  end
end
