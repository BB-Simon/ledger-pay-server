module Ledger
  class Transfer
    def self.call(
      from_wallet:,
      to_wallet:,
      amount:,
      reference:
    )
      new(
        from_wallet: from_wallet,
        to_wallet: to_wallet,
        amount: amount,
        reference: reference
      ).call()
    end

    def initialize(
      from_wallet:,
      to_wallet:,
      amount:,
      reference:
    )
      @from_wallet = from_wallet
      @to_wallet = to_wallet
      @amount = amount
      @reference = reference
    end
    def call
      validate_wallets!

      Account.transaction do
        lock_accounts!

        validate_blance!

        Ledger::PostTransaction.call(
          reference: @reference,
          transaction_type: :transfer,
          currency: @from_wallet.currency,
          entries: [
            {
              account: @from_wallet.account,
              entry_type: :debit,
              amount: @amount
            },
            {
              account: @to_wallet.account,
              entry_type: :credit,
              amount: @amount
            }
          ]
        )
      end
    end

    def validate_wallets!
      raise ArgumentError,  "Source and destination wallets must be different" if
        @from_wallet.id == @to_wallet.id

      raise ArgumentError, "Wallets must use the same currency" if
        @from_wallet.currency_id != @to_wallet.currency_id

      raise ArgumentError, "Amount must be a positive integer" if
        !@amount.is_a?(Integer) || @amount <= 0
    end

    def lock_accounts!
      if @from_wallet.account.id < @to_wallet.account.id
        @from_wallet.account.lock!
        @to_wallet.account.lock!
      else
        @to_wallet.account.lock!
        @from_wallet.account.lock!
      end
    end

    def validate_blance!
      if @from_wallet.account.balance < @amount
        raise ArgumentError, "Insufficient balance in source wallet"
      end
    end
  end
end
