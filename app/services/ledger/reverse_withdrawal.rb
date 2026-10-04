module Ledger
  class ReverseWithdrawal
    def self.call(withdrawal:)
      new(withdrawal: withdrawal).call
    end

    def initialize(withdrawal:)
      @withdrawal = withdrawal
    end

    def call
      validate!

      existing = Transaction.find_by(
        reference: "WITHDRAWAL-REVERSAL-#{@withdrawal.id}"
      )

      return existing if existing

      transaction = Ledger::PostTransaction.call(
        reference: "WITHDRAWAL-REVERSAL-#{@withdrawal.id}",
        transaction_type: :reversal,
        currency: @withdrawal.currency,
        entries: [
          {
            account: clearing_account,
            entry_type: :debit,
            amount: @withdrawal.amount
          },
          {
            account: @withdrawal.wallet.account,
            entry_type: :credit,
            amount: @withdrawal.amount
          }
        ]
      )

      @withdrawal.update!(
        reversal_reference: transaction.reference
      )

      transaction
    end

    private

    def validate!
      raise ArgumentError, "Withdrawal must have succeeded" unless
        @withdrawal.succeeded?

      raise ArgumentError, "Wallet account is required" unless
        @withdrawal.wallet.account
    end

    def clearing_account
      Account.find_by!(
        code: "WITHDRAWAL_CLEARING_#{@withdrawal.currency.code}"
      )
    end
  end
end
