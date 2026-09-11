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

      intent = Stripe::PaymentIntent.create(
        amount: @amount,
        currency: @wallet.currency.code.downcase,
        metadata: {
          payment_id: payment.id
        }
      )

      payment.update!(
        provider_payment_id: intent.id
      )

      {
        payment: payment,
        client_secret: intent.client_secret
      }
    end

    private

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
