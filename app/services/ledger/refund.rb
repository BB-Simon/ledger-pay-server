module Ledger
  class Refund
    def self.call(refund:)
      new(refund: refund).call
    end

    def initialize(refund:)
      @refund = refund
    end

    # Stripe has already refunded the card, so this always posts, even if the
    # wallet balance is too low. A shortfall is flagged, not refused.
    def call
      validate!

      Account.transaction do
        account = @refund.payment.wallet.account
        account.lock!

        transaction = post_transaction!

        Ledger::FlagNegativeBalance.call(
          account: account,
          reference: transaction.reference,
          user: @refund.payment.user
        )

        transaction
      end
    end

    private

    def post_transaction!
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

    def validate!
      raise ArgumentError, "Refund must be succeeded" unless
        @refund.succeeded?

      raise ArgumentError, "Payment must be succeeded" unless
        @refund.payment.succeeded?

      # No wallet status check: Stripe already refunded the card, so it
      # settles even if the wallet was frozen while it was in flight.
      raise ArgumentError, "Wallet account is required" unless
        @refund.payment.wallet.account
    end

    def clearing_account
      Account.find_by!(
        code: "STRIPE_CLEARING_#{@refund.payment.currency.code}"
      )
    end
  end
end
