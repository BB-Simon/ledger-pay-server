module Ledger
  class Refund
    def self.call(refund:)
      new(refund: refund).call
    end

    def initialize(refund:)
      @refund = refund
    end

    def call
      validate!

      Ledger::PostTransaction.call(
        reference: "REFUND-#{@refund.id}",
        transaction_type: :refund,
        currency: @refund.payment.currency,
        entries: [
          {
            account: @refund.payment.wallet.account,
            entry_type: :debit,
            amount: @refund.amount
          },
          {
            account: clearing_account,
            entry_type: :credit,
            amount: @refund.amount
          }
        ]
      )
    end

    private

    def validate!
      raise ArgumentError, "Refund must be succeeded" unless
        @refund.succeeded?

      raise ArgumentError, "Payment must be succeeded" unless
        @refund.payment.succeeded?

      raise ArgumentError, "Wallet must be active" unless
        @refund.payment.wallet.status == "active"

      raise ArgumentError, "Wallet account is required" unless
        @refund.payment.wallet.account

      raise ArgumentError, "Insufficient wallet balance" unless
        @refund.payment.wallet.account.balance >= @refund.amount
    end

    def clearing_account
      Account.find_by!(
        code: "STRIPE_CLEARING_#{@refund.payment.currency.code}"
      )
    end
  end
end
