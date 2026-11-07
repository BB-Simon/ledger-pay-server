module Ledger
  class Withdraw
    def self.call(withdrawal:)
      new(withdrawal: withdrawal).call
    end

    def initialize(withdrawal:)
      @withdrawal = withdrawal
    end

    # The payout has already been paid by Stripe, so this always posts, even
    # if the wallet balance is too low. A shortfall is flagged, not refused.
    def call
      validate!

      Account.transaction do
        account = @withdrawal.wallet.account
        account.lock!

        transaction = post_transaction!

        Ledger::FlagNegativeBalance.call(
          account: account,
          reference: transaction.reference,
          user: @withdrawal.user
        )

        transaction
      end
    end

    private

    def post_transaction!
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

    def validate!
      raise ArgumentError, "Withdrawal must be succeeded" unless
        @withdrawal.succeeded?

      raise ArgumentError, "Wallet must be active" unless
        @withdrawal.wallet.status == "active"

      raise ArgumentError, "Wallet account is required" unless
        @withdrawal.wallet.account

      raise ArgumentError, "Currency mismatch" unless
        @withdrawal.wallet.currency_id == @withdrawal.currency_id
    end

    def clearing_account
      Account.find_by!(
        code: "WITHDRAWAL_CLEARING_#{@withdrawal.currency.code}"
      )
    end
  end
end
