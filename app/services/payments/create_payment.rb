module Payments
  class CreatePayment
    def self.call(
      user:,
      wallet:,
      amount:
    )
      new(
        user: user,
        wallet: wallet,
        amount: amount
      ).call
    end

    def initialize(
      user:,
      wallet:,
      amount:
    )
      @user = user
      @wallet = wallet
      @amount = amount
    end

    def call
      validate!

      payment = Payment.create!(
        user: @user,
        wallet: @wallet,
        amount: @amount,
        currency: @wallet.currency,
        provider: "stripe",
        status: :pending
      )

      AuditLogs::Record.call(
        action: "payment.created",
        auditable: payment,
        user: @user,
        metadata: {
          amount: payment.amount,
          currency: payment.currency.code,
          provider: payment.provider
        }
      )

      intent = create_intent!(payment)

      payment.update!(
        provider_payment_id: intent.id
      )

      {
        payment: payment,
        client_secret: intent.client_secret
      }
    end

    private

    # The client needs the intent's client_secret to pay, so there's nothing
    # to retry in the background: any Stripe error marks the payment failed
    # and is re-raised. If Stripe did create an intent despite a timeout, it
    # is never confirmed, so no money moves. The idempotency key stops the
    # Stripe client's own network retries from creating a second intent.
    def create_intent!(payment)
      Stripe::PaymentIntent.create(
        {
          amount: @amount,
          currency: @wallet.currency.code.downcase,
          metadata: {
            payment_id: payment.id
          }
        },
        {
          idempotency_key: "payment-#{payment.id}"
        }
      )
    rescue Stripe::StripeError => e
      mark_failed!(payment, e)
      raise
    end

    def mark_failed!(payment, error)
      definite = StripeErrors::DEFINITE_FAILURES.any? { |klass| error.is_a?(klass) }

      payment.update!(
        status: :failed,
        failure_code: definite ? error.code : "provider_unavailable",
        failure_message: error.message.to_s.truncate(500)
      )

      AuditLogs::Record.call(
        action: "payment.failed",
        auditable: payment,
        user: @user,
        metadata: {
          stage: "submission",
          error_class: error.class.name,
          failure_code: payment.failure_code
        }
      )
    end

    def validate!
      raise ArgumentError, "Amount must be greater than 0" unless
        @amount.is_a?(Integer) && @amount > 0

      raise ArgumentError, "Wallet must be active" unless
        @wallet.status == "active"

      raise ArgumentError, "Wallet must be owned by the user" unless
        @wallet.user_id == @user.id
    end
  end
end
