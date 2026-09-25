module Payments
  class CreateRefund
    def self.call(payment:, amount:, reason:)
      new(payment, amount, reason).call
    end

    def initialize(payment, amount, reason)
      @payment = payment
      @amount = amount
      @reason = reason
    end

    def call
      validate!

      refund = Refund.create!(
        payment: @payment,
        amount: @amount,
        provider: "stripe",
        status: :pending,
        reason: @reason
      )

      stripe_refund = Stripe::Refund.create(
        payment_intent: @payment.provider_payment_id,
        amount: refund.amount,
        metadata: {
          refund_id: refund.id
        }
      )

      refund.update!(provider_refund_id: stripe_refund.id)

      {
        refund: refund,
        stripe_refund: stripe_refund
      }
    end

    private
    def validate!
      raise ArgumentError, "Payment must be succeeded" unless
        @payment.succeeded?

      raise ArgumentError, "Payment provider must be Stripe" unless
        @payment.provider == "stripe"

      raise ArgumentError, "Payment has already been fully refunded" if
        @payment.refunds.where(status: [ :pending, :succeeded ]).exists?

      raise ArgumentError, "Refund amount must equal payment amount" unless
        @amount == @payment.amount

      raise ArgumentError, "Wallet must be active" unless
        @payment.wallet.status == "active"
    end
  end
end
