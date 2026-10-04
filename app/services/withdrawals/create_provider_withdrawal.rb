module Withdrawals
  class CreateProviderWithdrawal
    def self.call(withdrawal:)
      new(withdrawal: withdrawal).call
    end

    def initialize(withdrawal:)
      @withdrawal = withdrawal
    end

    def call
      validate!

      payout = Stripe::Payout.create({
        amount: @withdrawal.amount,
        currency: @withdrawal.currency.code.downcase,
        metadata: {
          withdrawal_id: @withdrawal.id
        }
      }, {
        idempotency_key: "withdrawal-#{@withdrawal.id}"
      })

      @withdrawal.update!(
        provider_withdrawal_id: payout.id
      )

      payout
    end

    private

    def validate!
      raise ArgumentError, "Withdrawal must be pending" unless
        @withdrawal.pending?

      raise ArgumentError, "Withdrawal provider must be Stripe" unless
        @withdrawal.provider == "stripe"
    end
  end
end
