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
      refund = Payment.transaction do
        @payment = Payment.lock.find(@payment.id)

        validate!

        Refund.create!(
          payment: @payment,
          amount: @amount,
          provider: "stripe",
          status: :pending,
          reason: @reason
        )
      end

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

      raise ArgumentError, "Amount must be a positive integer" unless
        @amount.is_a?(Integer) && @amount > 0

      raise ArgumentError, "Wallet must be active" unless
        @payment.wallet.status == "active"

      raise ArgumentError, "Refund amount exceeds refundable amount" unless
        @amount <= refundable_amount
    end

    def refundable_amount
      refunded_amount = @payment.refunds
        .where(status: [ :pending, :succeeded ])
        .sum(:amount)

      @payment.amount - refunded_amount
    end
  end
end
