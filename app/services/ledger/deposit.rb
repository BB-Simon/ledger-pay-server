module Ledger
  class Deposit
    def self.call(
      wallet:,
      amount:,
      reference:
    )
      new(
        wallet:,
        amount:,
        reference:
      ).call
    end

    def initialize(
      wallet:,
      amount:,
      reference:
    )
      @wallet = wallet
      @amount = amount
      @reference = reference
    end

    def call
      validate!

      Ledger::PostTransaction.call(
        reference: @reference,
        transaction_type: :deposit,
        currency: @wallet.currency,
        entries: [
          {
            account: clearing_account,
            amount: @amount,
            entry_type: :debit
          },
          {
            account: @wallet.account,
            amount: @amount,
            entry_type: :credit
          }
        ]
      )
    end

    private

    def validate!
      raise ArgumentError, "Amount must be greater than zero" unless
        @amount.is_a?(Integer) && @amount > 0

      raise ArgumentError, "Wallet must be active" unless
        @wallet.status == "active"
      raise ArgumentError, "Wallet account is required" unless
        @wallet.account
    end

    def clearing_account
      Account.find_by!(
        code: "STRIPE_CLEARING_#{@wallet.currency.code.upcase}"
      )
    end
  end
end
